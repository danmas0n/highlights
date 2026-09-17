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
    /// Where the capture window begins inside those files, since the player runs on a trimmed
    /// composition starting at zero.
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
    @State private var isExporting = false
    @State private var exportProgress: Float = 0
    @State private var status: String?
    @State private var errorMessage: String?
    @State private var confirmingDelete = false

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
                        cropWidth: $cropWidth
                    )
                    .onDisappear {
                        // Framing done full-screen is the real framing; carry it back, and drop
                        // the crop composition so the inline view returns to the full frame with
                        // its rectangle overlay.
                        highlight.cropPath = cropWidth >= 0.999
                            ? nil
                            : .fixed(center: cropCenter, widthFraction: cropWidth)
                        player.currentItem?.videoComposition = nil
                        seek(trimStart)
                    }
                }
            }
            .alert("Something went wrong", isPresented: .constant(errorMessage != nil)) {
                Button("OK") { errorMessage = nil }
            } message: { Text(errorMessage ?? "") }
            .confirmationDialog("Delete this clip?", isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button("Delete clip", role: .destructive) {
                    let doomed = highlight
                    // Tear down the player first: deleting frees the segments it's reading from.
                    teardown()
                    dismiss()
                    Task { await model.delete(doomed) }
                }
                Button("Keep", role: .cancel) {}
            } message: {
                Text(highlight.isExported
                     ? "The copy in Photos will be kept."
                     : "This clip hasn't been saved to Photos yet.")
            }
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
                    // The tap has to go on an overlay, not the player: a disabled view drops
                    // gestures attached to it, which is why tapping the video used to do nothing.
                    .overlay {
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture { showFullScreen = true }
                    }
            } else {
                ProgressView()
            }

            // The draggable crop window, overlaid on the full frame so you can see what you're
            // giving up as well as what you're keeping.
            GeometryReader { geometry in
                let frame = videoFrame(in: geometry.size)
                let box = CGSize(width: frame.width * cropWidth, height: frame.height * cropWidth)
                let live = cropCenter

                Rectangle()
                    .strokeBorder(.yellow, lineWidth: 2)
                    .background(Rectangle().fill(Color.yellow.opacity(0.06)))
                    .frame(width: box.width, height: box.height)
                    .position(
                        x: (geometry.size.width - frame.width) / 2 + live.x * frame.width,
                        y: (geometry.size.height - frame.height) / 2 + live.y * frame.height
                    )
                    .gesture(
                        DragGesture()
                            .onChanged { value in
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

            // A full-screen button where every video player keeps one, sized for a thumb.
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    Button {
                        showFullScreen = true
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.body.weight(.bold))
                            .frame(width: 44, height: 44)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                    .disabled(composition == nil)
                    .padding(10)
                }
            }
        }
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
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
                    resetCrop()
                } label: {
                    Label("Reset zoom to full frame", systemImage: "arrow.uturn.backward")
                }
                .disabled(cropWidth >= 0.999)
            }

            Section {
                TextField("Title (optional)", text: $highlight.title)
                if highlight.isExported {
                    Label("Saved to Photos", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.footnote)
                }
            }

            Section {
                Button(role: .destructive) {
                    confirmingDelete = true
                } label: {
                    Label("Delete clip", systemImage: "trash")
                }
            } footer: {
                Text(highlight.isExported
                     ? "Frees this clip's footage. The version already saved to Photos is untouched."
                     : "Frees this clip's footage. It hasn't been saved to Photos, so this is permanent.")
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

    /// Back to the whole frame. Clearing to nil rather than a full-frame path matters: an absent
    /// crop lets the exporter skip compositing altogether.
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
