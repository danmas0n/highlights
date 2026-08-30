import AVKit
import SwiftUI

/// Where the tight framing actually happens — at the kitchen table, with all the time in the
/// world, rather than on the sideline with one hand on a tripod.
struct HighlightEditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var highlight: Highlight

    @State private var player: AVPlayer?
    @State private var timeObserver: Any?
    @State private var endObserver: NSObjectProtocol?
    /// Per-segment files backing the preview. Owned by this view; deleted on close.
    @State private var clip: SegmentStore.ReassembledClip?
    /// Where the capture window begins inside those files — the tracker reads them directly and
    /// needs to add this back, since the player runs on a trimmed composition starting at zero.
    @State private var clipOffset: Double = 0
    @State private var windowDuration: Double = 0
    /// Held so the full-screen preview can re-composite the crop against the same asset.
    @State private var composition: AVMutableComposition?
    @State private var showFullScreen = false

    @State private var playhead: Double = 0
    @State private var trimStart: Double = 0
    @State private var trimEnd: Double = 0

    @State private var cropCenter = CGPoint(x: 0.5, y: 0.5)
    /// Where the crop sat when the current drag began. Without an anchor, adding the gesture's
    /// cumulative translation to an already-updated centre compounds every frame and the box
    /// accelerates away from your finger.
    @State private var cropDragAnchor: CGPoint?
    @State private var cropWidth: Double = 0.5
    @State private var isTracking = false
    @State private var isExporting = false
    @State private var exportProgress: Float = 0
    @State private var status: String?
    @State private var errorMessage: String?

    init(highlight: Highlight) {
        _highlight = State(initialValue: highlight)
        if let path = highlight.cropPath, let first = path.keyframes.first {
            _cropCenter = State(initialValue: first.center)
            _cropWidth = State(initialValue: first.widthFraction)
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                playerArea
                transport
                controls
            }
            .navigationTitle("Edit Clip")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", action: close)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Save to Photos") { Task { await export() } }
                        .disabled(isExporting || player == nil)
                }
            }
            .task { await loadPreview() }
            // Teardown must hang off `onDisappear`, not the Close button. A sheet is normally
            // dismissed by swiping it down, which never ran `close()` — leaving an AVPlayer
            // looping a 4K composition forever, a periodic time observer firing against it, and
            // the temp files on disk. That alone was enough to keep the phone hot indefinitely.
            .onDisappear { teardown() }
            .fullScreenCover(isPresented: $showFullScreen) {
                if let player, let composition {
                    FullScreenPreview(
                        player: player,
                        composition: composition,
                        quality: model.settings.exportQuality,
                        trimStart: trimStart,
                        trimEnd: trimEnd,
                        cropCenter: $cropCenter,
                        cropWidth: $cropWidth,
                        cropPath: highlight.cropPath
                    )
                    .onDisappear {
                        // Framing done full-screen is the real framing; carry it back, and drop
                        // the crop composition so the inline view returns to the full frame with
                        // its rectangle overlay.
                        if highlight.cropPath?.isStatic != false {
                            highlight.cropPath = .fixed(center: cropCenter, widthFraction: cropWidth)
                        }
                        player.currentItem?.videoComposition = nil
                        seek(trimStart)
                    }
                }
            }
            .alert("Something went wrong", isPresented: .constant(errorMessage != nil)) {
                Button("OK") { errorMessage = nil }
            } message: { Text(errorMessage ?? "") }
        }
    }

    // MARK: - Player

    private var playerArea: some View {
        ZStack {
            Color.black
            if let player {
                VideoPlayer(player: player)
                    // Our own transport sits below; the system controls would fight the crop
                    // rectangle for the same taps.
                    .disabled(true)
                    .onTapGesture { showFullScreen = true }
            } else {
                ProgressView()
            }

            // The draggable crop window, overlaid on the full frame so you can see what you're
            // giving up as well as what you're keeping.
            GeometryReader { geometry in
                let frame = videoFrame(in: geometry.size)
                let box = CGSize(width: frame.width * cropWidth, height: frame.height * cropWidth)
                let live = liveCropCenter

                Rectangle()
                    .strokeBorder(isFollowing ? .green : .yellow, lineWidth: 2)
                    .background(Rectangle().fill((isFollowing ? Color.green : Color.yellow).opacity(0.06)))
                    .frame(width: box.width, height: box.height)
                    .position(
                        x: (geometry.size.width - frame.width) / 2 + live.x * frame.width,
                        y: (geometry.size.height - frame.height) / 2 + live.y * frame.height
                    )
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                // Dragging by hand replaces any tracked camera move — you can't
                                // meaningfully nudge a path that's moving underneath you.
                                let anchor = cropDragAnchor ?? live
                                if cropDragAnchor == nil { cropDragAnchor = anchor }
                                cropCenter = CGPoint(
                                    x: clamp(anchor.x + value.translation.width / frame.width),
                                    y: clamp(anchor.y + value.translation.height / frame.height)
                                )
                                highlight.cropPath = .fixed(center: cropCenter, widthFraction: cropWidth)
                            }
                            .onEnded { _ in cropDragAnchor = nil }
                    )
            }
            .allowsHitTesting(!isTracking)

            if isTracking {
                VStack(spacing: 8) {
                    ProgressView()
                    Text("Following your player…").font(.caption)
                }
                .padding(20)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
    }

    /// True once a tracked camera move exists, as opposed to a fixed crop.
    private var isFollowing: Bool { highlight.cropPath?.isStatic == false }

    /// Where the crop window sits *right now*.
    ///
    /// With a tracked path this is sampled at the playhead, so the box visibly follows your
    /// player during playback. Without it the preview showed a static rectangle no matter what
    /// auto-follow produced, which made the feature impossible to judge.
    private var liveCropCenter: CGPoint {
        guard let path = highlight.cropPath, !path.isStatic else { return cropCenter }
        let rect = path.rect(at: playhead - trimStart, sourceAspect: 16.0 / 9.0)
        return CGPoint(x: rect.midX, y: rect.midY)
    }

    // MARK: - Transport

    private var transport: some View {
        VStack(spacing: 8) {
            HStack {
                Button {
                    guard let player else { return }
                    player.timeControlStatus == .playing ? player.pause() : player.play()
                } label: {
                    Image(systemName: player?.timeControlStatus == .playing ? "pause.fill" : "play.fill")
                        .font(.title3)
                        .frame(width: 34)
                }
                .buttonStyle(.plain)

                Text(timecode(playhead))
                    .font(.footnote.monospacedDigit())
                Spacer()
                Text("\(timecode(trimEnd - trimStart)) clip")
                    .font(.footnote.monospacedDigit().weight(.medium))
                Spacer()
                Text(timecode(windowDuration))
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)

                Button {
                    showFullScreen = true
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.footnote.weight(.semibold))
                }
                .buttonStyle(.plain)
                .disabled(composition == nil)
            }

            TrimBar(
                duration: windowDuration,
                trimStart: $trimStart,
                trimEnd: $trimEnd,
                playhead: playhead,
                onScrub: seek
            )
            .onChange(of: trimStart) { _, new in
                highlight.trimStart = new
                if playhead < new { seek(new) }
            }
            .onChange(of: trimEnd) { _, new in
                highlight.trimEnd = new
                player?.currentItem?.forwardPlaybackEndTime = CMTime(seconds: new, preferredTimescale: 600)
                if playhead > new { seek(trimStart) }
            }

            HStack {
                Text("Drag the handles to trim. Tap the video for a full-screen look.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Reset trim") { resetTrim() }
                    .font(.caption2.weight(.semibold))
                    .disabled(trimStart <= 0.01 && trimEnd >= windowDuration - 0.01)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Controls

    private var controls: some View {
        Form {
            Section("Zoom") {
                VStack(alignment: .leading, spacing: 6) {
                    Slider(value: $cropWidth, in: 0.35...1.0) { _ in
                        highlight.cropPath = .fixed(center: cropCenter, widthFraction: cropWidth)
                    }
                    HStack {
                        Text(String(format: "%.1f× zoom", 1.0 / cropWidth))
                            .font(.caption.monospacedDigit())
                        Spacer()
                        Text(exportSizeLabel)
                            .font(.caption)
                            .foregroundStyle(cropWidth < 0.5 && model.settings.exportQuality == .fullHD
                                             ? .orange : .green)
                    }
                }

                Button {
                    Task { await autoFollow() }
                } label: {
                    Label("Auto-follow my player", systemImage: "scope")
                }
                .disabled(isTracking || clip == nil)

                Button {
                    resetCrop()
                } label: {
                    Label("Reset zoom to full frame", systemImage: "arrow.uturn.backward")
                }
                .disabled(cropWidth >= 0.999 && highlight.cropPath?.isStatic != false)
            }

            Section {
                TextField("Title (optional)", text: $highlight.title)
                if highlight.isExported {
                    Label("Saved to Photos", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.footnote)
                }
            }

            if let status {
                Section { Text(status).font(.footnote).foregroundStyle(.secondary) }
            }

            if isExporting {
                Section {
                    ProgressView(value: exportProgress) { Text("Exporting…") }
                }
            }
        }
    }

    /// Spells out the actual output size, because "zoom" and "resolution" are the same dial here
    /// and that isn't obvious.
    private var exportSizeLabel: String {
        let source = CGSize(
            width: Double(model.settings.resolution.width),
            height: Double(model.settings.resolution.height)
        )
        let size = model.settings.exportQuality.renderSize(forCropFraction: cropWidth, sourceSize: source)
        let upscaling = cropWidth * source.width < size.width - 1
        return "\(Int(size.width))×\(Int(size.height))\(upscaling ? " · upscaled" : "")"
    }

    // MARK: - Loading

    private func loadPreview() async {
        do {
            let clip = try await model.extractor.materialise(highlight)
            self.clip = clip
            self.clipOffset = highlight.timeRange.start.seconds - clip.startSeconds

            // Preview the *whole* captured window; the trim handles bound playback rather than
            // rebuilding the composition, so dragging them stays smooth.
            let composition = try await ClipComposer.makeComposition(
                clip: clip, window: highlight.timeRange
            )
            let available = composition.duration.seconds
            self.windowDuration = available
            self.trimStart = min(highlight.trimStart, max(available - 1, 0))
            self.trimEnd = min(highlight.trimEnd ?? available, available)

            self.composition = composition
            let item = AVPlayerItem(asset: composition)
            item.forwardPlaybackEndTime = CMTime(seconds: trimEnd, preferredTimescale: 600)
            let player = AVPlayer(playerItem: item)
            self.player = player

            // 10 Hz: enough for the tracked crop box to move smoothly, well short of the 30 Hz
            // that was waking the main thread for every frame. Safe now that the observer is
            // actually torn down when the editor closes.
            timeObserver = player.addPeriodicTimeObserver(
                forInterval: CMTime(value: 1, timescale: 10), queue: .main
            ) { time in
                MainActor.assumeIsolated { playhead = time.seconds }
            }
            // Loop within the trim — short clips get watched repeatedly while framing. `weak` on
            // the player matters: a strong capture here makes the notification centre keep the
            // player (and its decoder) alive after the view is gone.
            endObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
            ) { [weak player] _ in
                MainActor.assumeIsolated {
                    seek(trimStart)
                    player?.play()
                }
            }

            seek(trimStart)
            player.play()
        } catch {
            captureLog.error("preview failed: \(error.localizedDescription, privacy: .public)")
            errorMessage = error.localizedDescription
        }
    }

    /// Restores the full captured window. The escape hatch for a trim that got away from you.
    private func resetTrim() {
        trimStart = 0
        trimEnd = windowDuration
        highlight.trimStart = 0
        highlight.trimEnd = windowDuration
        player?.currentItem?.forwardPlaybackEndTime =
            CMTime(seconds: windowDuration, preferredTimescale: 600)
        seek(0)
    }

    /// Back to the whole frame, and back to a fixed crop if auto-follow had taken over.
    ///
    /// Clearing to nil rather than a full-frame path matters: an absent crop lets the exporter
    /// skip compositing altogether.
    private func resetCrop() {
        cropCenter = CGPoint(x: 0.5, y: 0.5)
        cropWidth = 1.0
        cropDragAnchor = nil
        highlight.cropPath = nil
        status = nil
    }

    private func seek(_ seconds: Double) {
        playhead = seconds
        player?.seek(
            to: CMTime(seconds: seconds, preferredTimescale: 600),
            toleranceBefore: .zero, toleranceAfter: .zero
        )
    }

    private func close() {
        model.library.update(highlight)
        dismiss()
    }

    /// Idempotent: `onDisappear` runs on every dismissal path, including after `close()`.
    private func teardown() {
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        timeObserver = nil
        endObserver = nil
        player = nil
        // Nothing to delete: the parts are the stored segments themselves, owned by the store.
        clip = nil
    }

    // MARK: - Actions

    /// Seeds the tracker from the current crop box and turns the result into a smoothed camera
    /// move. Deliberately seeded from where the user has already framed rather than asking for a
    /// separate tap — they've just told us where their son is.
    private func autoFollow() async {
        guard let clip, let first = clip.parts.first else { return }
        isTracking = true
        defer { isTracking = false }

        // Vision's coordinate origin is bottom-left; the crop box is top-left.
        let boxSize = 0.12
        let seedBox = CGRect(
            x: clamp(cropCenter.x - boxSize / 2),
            y: clamp((1 - cropCenter.y) - boxSize / 2),
            width: boxSize,
            height: boxSize
        )

        do {
            // The tracker reads the reassembled parts, whose timeline starts at the first part —
            // the player's starts at the capture window. Shift in, then shift the results back.
            _ = first
            let tracker = SubjectTracker()
            let observations = try await tracker.track(
                parts: clip.parts,
                initialBox: seedBox,
                seedTime: clipOffset + playhead,
                window: (clipOffset + trimStart)...(clipOffset + trimEnd)
            )
            let path = CropPath.smoothed(
                observations: observations.map { ($0.time - clipOffset - trimStart, $0.center) },
                widthFraction: cropWidth
            )
            highlight.cropPath = path
            status = "Following your player across \(observations.count) frames — the green box shows the move. Drag the box to go back to a fixed crop."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func export() async {
        isExporting = true
        exportProgress = 0
        defer { isExporting = false }

        highlight.trimStart = trimStart
        highlight.trimEnd = trimEnd
        model.library.update(highlight)

        do {
            let output = try await model.extractor.export(
                highlight: highlight,
                quality: model.settings.exportQuality
            ) { progress in
                Task { @MainActor in exportProgress = progress }
            }
            highlight.exportedAssetIdentifier = output.assetIdentifier
            model.library.update(highlight)
            // Note: the footage is deliberately *not* released here. The exported clip is cropped
            // and flattened; the local copy is the only way back to the full 4K frame.
            await model.releaseFootageIfConfigured(for: highlight)
            status = output.croppedAsRequested
                ? "Saved \(Int(output.renderSize.width))×\(Int(output.renderSize.height)) to your camera roll."
                : "Saved to your camera roll, but the crop couldn't be applied — this clip is the full frame."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Helpers

    private func clamp(_ value: Double) -> Double { min(max(value, 0), 1) }

    private func timecode(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00" }
        let total = Int(max(0, seconds))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private func videoFrame(in size: CGSize) -> CGSize {
        let videoAspect = 16.0 / 9.0
        let viewAspect = size.width / size.height
        return viewAspect > videoAspect
            ? CGSize(width: size.height * videoAspect, height: size.height)
            : CGSize(width: size.width, height: size.width / videoAspect)
    }
}
