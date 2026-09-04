import AVFoundation
import SwiftUI

/// The sideline screen. Every decision here assumes: bright sun, one hand on the tripod, eyes on
/// the game rather than the phone, and no willingness to hunt for a small button.
struct CaptureView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    @State private var showLibrary = false
    @State private var showSettings = false
    @State private var flashOpacity: Double = 0
    @State private var markBanner: String?
    @State private var isDimmed = false
    @State private var restoreBrightness: CGFloat = UIScreen.main.brightness

    private var isRecording: Bool { model.engine.state == .recording }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if model.engine.isCameraLive {
                CameraPreview(session: model.engine.session)
                    .ignoresSafeArea()
                    .overlay {
                        if model.settings.showSafeFrame {
                            SafeFrameOverlay(cropFraction: 1.0 / model.settings.resolution.cropZoomFactor)
                        }
                    }
            }

            // The trigger. Deliberately the entire screen: a target you cannot miss while
            // watching the game instead of the phone.
            Color.clear
                .contentShape(Rectangle())
                .ignoresSafeArea()
                .onTapGesture { model.triggers.fire(.tap) }
                .onLongPressGesture(minimumDuration: 0.5) {
                    // Focus is on long press so the tap gesture stays unambiguous.
                    model.engine.focus(at: CGPoint(x: 0.5, y: 0.5))
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }

            KeyCommandCatcher { model.triggers.fire(.hardwareKey) }
                .allowsHitTesting(false)
                .frame(width: 0, height: 0)

            if isDimmed { dimOverlay }

            Color.white.opacity(flashOpacity).ignoresSafeArea().allowsHitTesting(false)

            VStack(spacing: 10) {
                topBar
                Spacer()
                hintText
                zoomControl
                bottomBar
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .opacity(isDimmed ? 0 : 1)
            // Invisible chrome must not keep swallowing taps that are meant to mark a moment.
            .allowsHitTesting(!isDimmed)

            if let markBanner {
                Text(markBanner)
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .padding(.horizontal, 28).padding(.vertical, 16)
                    .background(.ultraThinMaterial, in: Capsule())
                    .transition(.scale.combined(with: .opacity))
                    .allowsHitTesting(false)
            }

            if case .failed(let message) = model.engine.state {
                failureView(message)
            }
        }
        .task {
            model.triggers.onTrigger = handleTrigger
            await model.engine.startCamera()
        }
        .onChange(of: scenePhase) { _, phase in
            // iOS suspends capture in the background regardless, so make the stop explicit rather
            // than letting frames stop arriving silently. Brightness is global to the phone, so
            // it has to be handed back on the way out no matter how we leave.
            if phase != .active, isDimmed { wake() }
            if phase == .background { model.engine.stopCamera() }
            // Coming back from the background — or from Settings after granting access — has to
            // bring the camera back up, otherwise the app returns to a permanently black screen.
            if phase == .active { Task { await model.engine.startCamera() } }
        }
        // Note: the camera deliberately keeps running behind these sheets. Standby is now
        // preview-only — no data outputs, no stabilisation, no microphone — so tearing the
        // session down and rebuilding it costs a visible pause on both open and close for very
        // little power saved.
        .sheet(isPresented: $showLibrary) { LibraryView() }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .persistentSystemOverlays(.hidden)
    }

    // MARK: - Chrome

    private var topBar: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(isRecording ? .red : .gray)
                        .frame(width: 10, height: 10)
                    Text(timecode(model.engine.elapsed.seconds))
                        .font(.system(.title3, design: .monospaced).weight(.semibold))
                }
                Text(isRecording
                     ? "\(Int(model.engine.availableHistory.seconds))s of history · \(model.engine.activeLens)"
                     : "Standby · \(model.engine.activeLens)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(spacing: 4) {
                if model.engine.thermalState == .serious || model.engine.thermalState == .critical {
                    Label("Phone is hot", systemImage: "thermometer.high")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(.orange.opacity(0.85), in: Capsule())
                }
                if model.engine.isInterrupted {
                    Label("Interrupted", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(.red.opacity(0.85), in: Capsule())
                } else if model.engine.isStalled {
                    Label("No video", systemImage: "eye.slash.fill")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(.red.opacity(0.85), in: Capsule())
                }
                if let note = model.engine.thermalDowngradeNote {
                    Text(note)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Text("\(model.library.highlights.count) marked")
                    .font(.system(.title3, design: .rounded).weight(.semibold))
                // ByteCountFormatter renders 0 as "Zero KB", which reads like a bug.
                Text(model.engine.bytesOnDisk > 0
                     ? ByteCountFormatter.string(fromByteCount: model.engine.bytesOnDisk, countStyle: .file)
                     : "—")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private var hintText: some View {
        Text(isRecording
             ? "Tap anywhere to mark the last \(Int(model.settings.preRollSeconds))s"
             : "Press record to start")
            .font(.footnote.weight(.medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(.ultraThinMaterial, in: Capsule())
    }

    /// Four controls, evenly spaced. Everything else got its own row — this used to hold the zoom
    /// pills and a hint line too, which in portrait squeezed them to nothing.
    private var bottomBar: some View {
        HStack(spacing: 12) {
            chromeButton("photo.stack", "Clips") { showLibrary = true }
            chromeButton("gearshape.fill", "Settings") { showSettings = true }

            Spacer()

            recordButton

            Spacer()

            // Screen brightness is a meaningful share of the power draw over two 40-minute
            // halves, and there is nothing to look at between highlights anyway.
            chromeButton(isDimmed ? "sun.max.fill" : "moon.fill", isDimmed ? "Wake" : "Dim") {
                isDimmed ? wake() : dim()
            }
            .disabled(!isRecording && !isDimmed)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    /// Optical zoom, on the capture screen rather than buried in Settings.
    ///
    /// How far away you are is something you discover on arriving at the pitch, not something you
    /// configure at home — and it changes between a full-size field and a small-sided one. Safe to
    /// change mid-recording: zoom doesn't alter the recorded dimensions.
    @ViewBuilder
    private var zoomControl: some View {
        if model.engine.zoomStops.count > 1 {
            HStack(spacing: 8) {
                ForEach(model.engine.zoomStops, id: \.self) { stop in
                    let selected = abs(model.settings.zoomFactor - stop) < 0.01
                    Button {
                        model.engine.setZoom(stop)
                        model.settings.zoomFactor = stop
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    } label: {
                        Text(stop < 1 ? String(format: "%.1f×", stop) : String(format: "%g×", stop))
                            .font(.subheadline.weight(.bold).monospacedDigit())
                            .foregroundStyle(selected ? .black : .white)
                            .frame(minWidth: 46, minHeight: 38)
                            .background(selected ? Color.yellow : Color.white.opacity(0.16), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(6)
            .background(.ultraThinMaterial, in: Capsule())
        }
    }

    /// Halftime, warm-ups, and the drive home all want the camera off. Recording only when you
    /// say so is also the single biggest lever on heat and battery.
    private var recordButton: some View {
        Button {
            Task {
                if isRecording {
                    model.engine.stopRecording()
                } else {
                    await model.engine.startRecording()
                }
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            }
        } label: {
            ZStack {
                Circle()
                    .strokeBorder(.white.opacity(0.9), lineWidth: 3)
                    .frame(width: 54, height: 54)
                RoundedRectangle(cornerRadius: isRecording ? 4 : 20)
                    .fill(.red)
                    .frame(width: isRecording ? 22 : 40, height: isRecording ? 22 : 40)
                    .animation(.spring(duration: 0.25), value: isRecording)
            }
        }
        .buttonStyle(.plain)
        .disabled(model.engine.state == .starting)
        .accessibilityLabel(isRecording ? "Stop recording" : "Start recording")
    }

    private func chromeButton(_ icon: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: icon).font(.title3)
                Text(label).font(.caption2)
            }
            .frame(minWidth: 56)
        }
        .buttonStyle(.plain)
    }

    /// Near-black rather than fully black, and still tap-to-mark.
    ///
    /// The wake control has to stay visible: the first version hid the whole chrome behind
    /// `opacity(0)`, which left no way back and stranded the phone's brightness at zero.
    private var dimOverlay: some View {
        ZStack {
            Color.black.opacity(0.97)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            VStack {
                Spacer()
                if model.engine.isStalled || model.engine.isInterrupted {
                    // A stall must break through the dim. Being quietly reassuring while
                    // recording nothing is the worst thing this app could do.
                    Label("Not recording — tap Wake", systemImage: "exclamationmark.triangle.fill")
                        .font(.callout.weight(.bold))
                        .foregroundStyle(.red)
                } else {
                    Text("Dimmed · still recording · tap anywhere to mark")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.28))
                }

                Button(action: wake) {
                    Label("Wake", systemImage: "sun.max.fill")
                        .font(.callout.weight(.semibold))
                        .padding(.horizontal, 22).padding(.vertical, 12)
                        .background(.white.opacity(0.14), in: Capsule())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.55))
                .padding(.top, 14)
                .padding(.bottom, 44)
            }
        }
    }

    private func failureView(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.orange)
            Text(message)
                .multilineTextAlignment(.center)
                .font(.headline)
            if model.engine.needsPermissionInSettings {
                Button("Open Settings") {
                    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                    UIApplication.shared.open(url)
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button("Try Again") { Task { await model.engine.startCamera() } }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(32)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24))
        .padding(40)
    }

    // MARK: - Actions

    private func handleTrigger(_ source: TriggerCoordinator.Source) {
        guard let highlight = model.mark() else {
            // Not recording — say so rather than silently doing nothing.
            withAnimation(.spring(duration: 0.25)) { markBanner = "Not recording" }
            Task {
                try? await Task.sleep(for: .seconds(1.2))
                withAnimation { markBanner = nil }
            }
            return
        }

        UINotificationFeedbackGenerator().notificationOccurred(.success)
        withAnimation(.easeOut(duration: 0.12)) { flashOpacity = 0.35 }
        withAnimation(.easeIn(duration: 0.45).delay(0.12)) { flashOpacity = 0 }

        withAnimation(.spring(duration: 0.25)) {
            markBanner = "Marked · \(Int(highlight.durationSeconds))s"
        }
        Task {
            try? await Task.sleep(for: .seconds(1.4))
            withAnimation { markBanner = nil }
        }
    }

    private func dim() {
        restoreBrightness = UIScreen.main.brightness
        isDimmed = true
        UIScreen.main.brightness = 0.0
    }

    private func wake() {
        isDimmed = false
        // Never restore to something unusable — if we somehow captured a near-zero value, hand
        // back something the user can actually see and correct.
        UIScreen.main.brightness = max(restoreBrightness, 0.35)
    }

    private func timecode(_ seconds: Double) -> String {
        let total = Int(max(0, seconds))
        return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }
}
