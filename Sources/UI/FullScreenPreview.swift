import AVKit
import SwiftUI

/// Full-screen review of a clip before it's saved.
///
/// The inline editor's player is a small 16:9 rectangle above a form, which is fine for framing
/// but hopeless for the question that actually matters on a Sunday afternoon: *was that any good?*
/// Sideline footage is mostly far away, so judging it needs the whole screen and the ability to
/// look closely.
///
/// Two modes, because they answer different questions:
///  - **Full frame** shows everything recorded, with the crop window drawn on top. This is where
///    you frame — drag to move the window, pinch to size it.
///  - **Export crop** renders the crop window to the full screen through the very same code the
///    exporter uses. That's both the zoom (a 2× crop fills the display at native pixels) and the
///    honest answer to what you're about to save.
struct FullScreenPreview: View {
    let player: AVPlayer
    let composition: AVMutableComposition
    let quality: CaptureSettings.ExportQuality
    let trimStart: Double
    let trimEnd: Double

    @Binding var cropCenter: CGPoint
    @Binding var cropWidth: Double
    /// The tracked camera move, if there is one — read-only here; framing by hand happens in
    /// full-frame mode and replaces it.
    let cropPath: CropPath?

    @Environment(\.dismiss) private var dismiss

    @State private var showingCrop = true
    /// Size the video actually occupies on screen, so drags map 1:1 to what you can see.
    @State private var displayedFrame: CGSize = .zero
    @State private var playhead: Double = 0
    @State private var isScrubbing = false
    @State private var timeObserver: Any?
    /// Live feedback during a pinch, before the crop is committed and the composition rebuilt.
    @State private var pinchScale: Double = 1
    /// Where the crop sat when the current drag began. Adding a gesture's cumulative translation
    /// to an already-updated centre compounds every frame and runs away from your finger.
    @State private var dragAnchor: CGPoint?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VideoPlayer(player: player)
                .disabled(true)
                .ignoresSafeArea()
                .overlay { if !showingCrop { cropOverlay } }
                // Measure the displayed video separately from drawing it, so drags can map 1:1
                // to what's on screen without writing state during a body evaluation.
                .background {
                    GeometryReader { geometry in
                        Color.clear
                            .onAppear { displayedFrame = videoFrame(in: geometry.size) }
                            .onChange(of: geometry.size) { _, size in
                                displayedFrame = videoFrame(in: size)
                            }
                    }
                }
                .gesture(showingCrop ? nil : framingGesture)

            VStack {
                topBar
                Spacer()
                transport
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .task { await applyCropComposition() }
        .onAppear(perform: observeTime)
        .onDisappear(perform: stopObserving)
        .onChange(of: showingCrop) { _, _ in Task { await applyCropComposition() } }
    }

    // MARK: - Chrome

    private var topBar: some View {
        HStack {
            Button {
                dismiss()
            } label: {
                Label("Done", systemImage: "chevron.down")
                    .font(.callout.weight(.semibold))
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            .buttonStyle(.plain)

            Spacer()

            Picker("", selection: $showingCrop) {
                Text("Full frame").tag(false)
                Text("Export crop").tag(true)
            }
            .pickerStyle(.segmented)
            .frame(width: 240)

            Spacer()

            Button {
                cropCenter = CGPoint(x: 0.5, y: 0.5)
                cropWidth = 1.0
                pinchScale = 1
                dragAnchor = nil
                Task { await applyCropComposition() }
            } label: {
                Text(String(format: "%.1f×", 1.0 / cropWidth))
                    .font(.callout.monospacedDigit().weight(.semibold))
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Reset zoom to full frame")
        }
    }

    private var transport: some View {
        HStack(spacing: 14) {
            Button {
                player.timeControlStatus == .playing ? player.pause() : player.play()
            } label: {
                Image(systemName: player.timeControlStatus == .playing ? "pause.fill" : "play.fill")
                    .font(.title2)
                    .frame(width: 30)
            }
            .buttonStyle(.plain)

            Text(timecode(playhead - trimStart))
                .font(.footnote.monospacedDigit())
                .frame(width: 44, alignment: .leading)

            Slider(
                value: Binding(
                    get: { min(max(playhead, trimStart), trimEnd) },
                    set: { seek($0) }
                ),
                in: trimStart...max(trimEnd, trimStart + 0.1),
                onEditingChanged: { isScrubbing = $0 }
            )

            Text(timecode(trimEnd - trimStart))
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Framing

    private var cropOverlay: some View {
        GeometryReader { geometry in
            let frame = videoFrame(in: geometry.size)
            let effective = liveCenter
            let box = CGSize(
                width: frame.width * cropWidth * pinchScale,
                height: frame.height * cropWidth * pinchScale
            )
            ZStack {
                Rectangle()
                    .strokeBorder(cropPath?.isStatic == false ? .green : .yellow, lineWidth: 2)
                    .frame(width: box.width, height: box.height)
                    .position(
                        x: (geometry.size.width - frame.width) / 2 + effective.x * frame.width,
                        y: (geometry.size.height - frame.height) / 2 + effective.y * frame.height
                    )
                Text("drag to move · pinch to zoom · tap the zoom badge to reset")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.5))
                    .position(x: geometry.size.width / 2, y: geometry.size.height - 96)
            }
        }
        .allowsHitTesting(false)
    }

    private var liveCenter: CGPoint {
        guard let path = cropPath, !path.isStatic else { return cropCenter }
        let rect = path.rect(at: playhead - trimStart, sourceAspect: 16.0 / 9.0)
        return CGPoint(x: rect.midX, y: rect.midY)
    }

    private var framingGesture: some Gesture {
        SimultaneousGesture(
            DragGesture()
                .onChanged { value in
                    let anchor = dragAnchor ?? cropCenter
                    if dragAnchor == nil { dragAnchor = anchor }
                    // 1:1 with the finger against the displayed frame, so the box tracks your
                    // touch instead of drifting at some arbitrary rate.
                    cropCenter = CGPoint(
                        x: clamp(anchor.x + value.translation.width / max(displayedFrame.width, 1)),
                        y: clamp(anchor.y + value.translation.height / max(displayedFrame.height, 1))
                    )
                }
                .onEnded { _ in dragAnchor = nil },
            MagnifyGesture()
                .onChanged { value in pinchScale = value.magnification }
                .onEnded { value in
                    // Commit on release rather than continuously: the crop rectangle is cheap to
                    // redraw, but the composition behind "Export crop" is not.
                    cropWidth = min(max(cropWidth / value.magnification, 0.25), 1.0)
                    pinchScale = 1
                }
        )
    }

    // MARK: - Playback

    private func observeTime() {
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 10), queue: .main
        ) { time in
            MainActor.assumeIsolated {
                guard !isScrubbing else { return }
                playhead = time.seconds
            }
        }
        player.play()
    }

    private func stopObserving() {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
    }

    private func seek(_ seconds: Double) {
        playhead = seconds
        player.seek(
            to: CMTime(seconds: seconds, preferredTimescale: 600),
            toleranceBefore: .zero, toleranceAfter: .zero
        )
    }

    /// Applies — or removes — the crop composition on the live player item.
    ///
    /// Reuses the exporter's builder, so "Export crop" is not an approximation of the output; it
    /// is the output, rendered by the same transforms.
    private func applyCropComposition() async {
        guard let track = composition.tracks(withMediaType: .video).first else { return }
        guard showingCrop else {
            player.currentItem?.videoComposition = nil
            return
        }
        let path = cropPath ?? .fixed(center: cropCenter, widthFraction: cropWidth)
        guard !path.isFullFrame else {
            player.currentItem?.videoComposition = nil
            return
        }
        guard let naturalSize = try? await track.load(.naturalSize),
              let preferredTransform = try? await track.load(.preferredTransform)
        else { return }

        player.currentItem?.videoComposition = ClipComposer.makeVideoComposition(
            track: track,
            naturalSize: naturalSize,
            preferredTransform: preferredTransform,
            cropPath: path,
            quality: quality,
            duration: composition.duration
        )
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
