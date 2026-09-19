import AVFoundation
import SwiftUI

/// The sideline screen. Every decision here assumes: bright sun, one hand on the tripod, eyes on
/// the game rather than the phone, and no willingness to hunt for a small button.
struct CaptureView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    @State private var showLibrary = false
    @State private var showSettings = false
    @State private var showAbout = false
    @State private var dimTask: Task<Void, Never>?
    @State private var flashOpacity: Double = 0
    @State private var markBanner: String?
    @State private var isDimmed = false
    @State private var restoreBrightness: CGFloat = UIScreen.main.brightness
    @AppStorage("onboarding.seen") private var hasSeenTour = false
    @State private var showTour = false

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

            chrome
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
            // The tour goes first on a fresh install so the camera permission prompt arrives
            // after the app has explained what it's for, not before.
            if hasSeenTour {
                await model.engine.startCamera()
            } else {
                showTour = true
            }
        }
        .fullScreenCover(isPresented: $showTour, onDismiss: {
            hasSeenTour = true
            Task { await model.engine.startCamera() }
        }) {
            OnboardingView()
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
        .sheet(isPresented: $showAbout) { AboutView() }
        // Dimming is automatic rather than a button: on a tripod you want it to just happen
        // once recording is underway, and to lift the moment you stop.
        .onChange(of: isRecording) { _, recording in
            if recording {
                model.gameClock.startIfIdle()
                scheduleDim(after: 8)
            } else {
                cancelDim()
                if isDimmed { wake() }
            }
        }
        .persistentSystemOverlays(.hidden)
    }

    // MARK: - Chrome

    /// Landscape on a phone: the size class the sideline actually uses.
    private var isLandscape: Bool { verticalSizeClass == .compact }

    /// While watching, the chrome shrinks into the corners and the middle of the screen — the
    /// part with the game in it — is left alone. Full-width bars and a hint line sitting exactly
    /// where you're trying to see the ball were the first thing an actual sideline complained
    /// about. Anything you'd only do between plays (Clips, Settings, About) is hidden until the
    /// eye closes; zoom stays, small, because you might want it between plays without stopping.
    private var chrome: some View {
        ZStack {
            VStack { HStack { clockCluster; Spacer() }; Spacer() }
            VStack { HStack { Spacer(); statusCluster }; Spacer() }

            if isRecording {
                // Corners only: zoom small at bottom-left, the eye small at bottom-right, and
                // the whole middle of the screen left to the game.
                VStack { Spacer(); HStack { zoomControl; Spacer() } }
                VStack { Spacer(); HStack { Spacer(); eyeCluster } }
            } else {
                // Idle: one bottom row. Three equal slots keep the eye dead centre regardless of
                // what's beside it — the first cut put the navigation and the eye in the same
                // corner and they collided in portrait.
                VStack(spacing: 8) {
                    Spacer()
                    Text("Tap the eye to start watching")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    if !isLandscape { zoomControl }
                    HStack(spacing: 0) {
                        HStack { navigationCluster; Spacer() }.frame(maxWidth: .infinity)
                        watchButton
                        HStack { Spacer(); if isLandscape { zoomControl } }.frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .padding(.horizontal, isLandscape ? 16 : 20)
        .padding(.vertical, isLandscape ? 8 : 14)
        .animation(.easeInOut(duration: 0.2), value: isRecording)
    }

    // MARK: Clock

    private static let wallClock: DateFormatter = {
        let f = DateFormatter(); f.timeStyle = .short; f.dateStyle = .none; return f
    }()

    /// Wall-clock time, the half's elapsed time, and when the half started. Tap for halftime.
    private var clockCluster: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Menu {
                Button {
                    model.gameClock.startNextPeriod()
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                } label: {
                    Label(model.gameClock.isRunning
                          ? "Start \(ordinal(model.gameClock.period + 1)) half"
                          : "Start 1st half",
                          systemImage: "flag.checkered")
                }
                if model.gameClock.isRunning {
                    Button(role: .destructive) {
                        model.gameClock.reset()
                    } label: {
                        Label("Reset game clock", systemImage: "arrow.counterclockwise")
                    }
                }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(Self.wallClock.string(from: context.date))
                        .font(.system(isRecording ? .headline : .title2, design: .rounded).weight(.bold).monospacedDigit())
                    if model.gameClock.isRunning, let started = model.gameClock.periodStartedAt {
                        Text("\(model.gameClock.periodLabel) \(timecode(model.gameClock.elapsed))")
                            .font(isRecording ? .caption.weight(.semibold) : .subheadline.weight(.semibold))
                            .monospacedDigit()
                        if !isRecording {
                            Text("kicked off \(Self.wallClock.string(from: started))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    } else if !isRecording {
                        Text("Game clock starts with the eye")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
        }
    }

    private func ordinal(_ n: Int) -> String {
        switch n { case 1: "1st"; case 2: "2nd"; case 3: "3rd"; default: "\(n)th" }
    }

    // MARK: Status

    private var statusCluster: some View {
        VStack(alignment: .trailing, spacing: 6) {
            HStack(spacing: 6) {
                Circle()
                    .fill(isRecording ? .red : .gray)
                    .frame(width: 8, height: 8)
                Text(isRecording
                     ? "\(model.library.highlights.count) marked · \(Int(model.engine.availableHistory.seconds))s back"
                     : "\(model.library.highlights.count) marked · \(model.engine.activeLens)")
                    .font(.caption.weight(.semibold).monospacedDigit())
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(.ultraThinMaterial, in: Capsule())

            if model.engine.thermalState == .serious || model.engine.thermalState == .critical {
                pill("Phone is hot", "thermometer.high", .orange)
            }
            if model.engine.isInterrupted {
                pill("Interrupted", "exclamationmark.triangle.fill", .red)
            } else if model.engine.isStalled {
                pill("No video", "eye.slash.fill", .red)
            }
            if let note = model.engine.thermalDowngradeNote {
                Text(note).font(.caption2).foregroundStyle(.orange)
            }
        }
    }

    private func pill(_ text: String, _ symbol: String, _ color: Color) -> some View {
        Label(text, systemImage: symbol)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(color.opacity(0.85), in: Capsule())
    }

    // MARK: Navigation

    private var navigationCluster: some View {
        HStack(spacing: 0) {
            chromeButton("photo.stack", "Clips") { showLibrary = true }
            chromeButton("gearshape.fill", "Settings") { showSettings = true }
            chromeButton("info.circle", "About") { showAbout = true }
        }
        .padding(.horizontal, 4).padding(.vertical, 2)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: Eye

    private var eyeCluster: some View {
        VStack(spacing: 4) {
            watchButton
            Text("tap anywhere to mark")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
        }
    }

    /// Optical zoom, on the capture screen rather than buried in Settings.
    ///
    /// How far away you are is something you discover on arriving at the pitch, not something you
    /// configure at home — and it changes between a full-size field and a small-sided one. Safe to
    /// change mid-recording: zoom doesn't alter the recorded dimensions. Small while watching.
    @ViewBuilder
    private var zoomControl: some View {
        if model.engine.zoomStops.count > 1 {
            let compact = isRecording
            HStack(spacing: compact ? 4 : 6) {
                ForEach(model.engine.zoomStops, id: \.self) { stop in
                    let selected = abs(model.settings.zoomFactor - stop) < 0.01
                    Button {
                        model.engine.setZoom(stop)
                        model.settings.zoomFactor = stop
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    } label: {
                        Text(stop < 1 ? String(format: "%.1f×", stop) : String(format: "%g×", stop))
                            .font((compact ? Font.caption2 : .footnote).weight(.bold).monospacedDigit())
                            .foregroundStyle(selected ? .black : .white)
                            .frame(minWidth: compact ? 34 : 42, minHeight: compact ? 26 : 34)
                            .background(selected ? Color.yellow : Color.white.opacity(0.16), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(compact ? 4 : 5)
            .background(.ultraThinMaterial, in: Capsule())
        }
    }

    /// An eye, not a record button.
    ///
    /// A record button promises a video at the end, and this doesn't give you one — it watches,
    /// keeps the recent past, and hands you only the moments you point at. Calling it "record"
    /// set exactly the wrong expectation. Closed eye: not watching. Open red eye: watching.
    /// Halftime, warm-ups, and the drive home all want it closed; watching only when you say so
    /// is also the single biggest lever on heat and battery.
    private var watchButton: some View {
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
            let size: CGFloat = isRecording ? 44 : 58
            VStack(spacing: 4) {
                ZStack {
                    Circle()
                        .fill(isRecording ? Color.red : Color.white.opacity(0.14))
                        .frame(width: size, height: size)
                    Circle()
                        .strokeBorder(isRecording ? Color.red.opacity(0.5) : Color.white.opacity(0.9), lineWidth: 3)
                        .frame(width: size, height: size)
                    Image(systemName: isRecording ? "eye.fill" : "eye.slash")
                        .font(.system(size: isRecording ? 18 : 24, weight: .semibold))
                        .foregroundStyle(.white)
                        .contentTransition(.symbolEffect(.replace))
                }
                .animation(.spring(duration: 0.25), value: isRecording)
                Text(isRecording ? "Watching" : "Watch")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(isRecording ? .red : .white)
            }
        }
        .buttonStyle(.plain)
        .disabled(model.engine.state == .starting)
        .accessibilityLabel(isRecording ? "Stop watching" : "Start watching")
    }

    private func chromeButton(_ icon: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: icon).font(.body)
                Text(label).font(.caption2)
            }
            .frame(minWidth: 44, minHeight: 44)
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

    private func scheduleDim(after seconds: Double) {
        cancelDim()
        guard model.settings.dimWhileRecording else { return }
        dimTask = Task {
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, isRecording else { return }
            dim()
        }
    }

    private func cancelDim() {
        dimTask?.cancel()
        dimTask = nil
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
        // Waking is for a glance; go back to sleep unless the recording has ended.
        if isRecording { scheduleDim(after: 20) }
    }

    private func timecode(_ seconds: Double) -> String {
        let total = Int(max(0, seconds))
        return total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
            : String(format: "%d:%02d", total / 60, total % 60)
    }
}
