import AVFoundation
import Foundation
import OSLog
import UIKit

/// Shared diagnostic log. A capture app that fails silently on a tripod is useless, so the
/// start-up path and every fault are traceable after the fact via Console or `log show`.
let captureLog = Logger(subsystem: "com.danmason.highlights", category: "capture")

/// Writes to both the unified log and stdout.
///
/// `devicectl --console` only relays stdout, so `Logger` alone is invisible over a cable — which
/// is exactly when you most want to read it.
func captureReport(_ message: String) {
    captureLog.log("\(message, privacy: .public)")
    print("[highlights] \(message)")
}

/// Coordinates the capture session, the continuous encode, and the segment store, and publishes
/// the handful of things the UI needs to show.
///
/// Main-actor isolated because SwiftUI observes it. Everything performance- or blocking-sensitive
/// lives in `CaptureSessionController` and `SegmentRecorder`, which are not.
@MainActor
@Observable
final class CaptureEngine {

    enum State: Equatable {
        /// Nothing running. The state at launch, and after backgrounding.
        case idle
        case starting
        /// Camera is live and you can see the framing, but nothing is being written to disk.
        case standby
        case recording
        case failed(String)
    }

    // Must start `.idle`, not `.standby`. `.standby` means "camera already live", so starting
    // there makes `startCamera()`'s own guard reject the initial start — the camera never comes
    // up and `requestAccess` is never called, which also means the app never appears under
    // Privacy & Security at all.
    private(set) var state: State = .idle
    /// Position on the current session's timeline. Bookmarks are stamped with this.
    private(set) var elapsed: CMTime = .zero
    /// How far back retention currently reaches — the honest answer to "can I still grab that
    /// thing from a minute ago?"
    private(set) var availableHistory: CMTime = .zero
    private(set) var isInterrupted = false
    /// Session claims to be running but no video has arrived for a while. Distinct from `failed`:
    /// it may recover on its own, and we'd rather warn loudly than tear down a live recording.
    private(set) var isStalled = false
    private(set) var thermalState: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState
    private(set) var bytesOnDisk: Int64 = 0
    private(set) var activeSessionID: UUID?
    /// True when the failure is a denied permission, so the UI can offer a jump to Settings
    /// rather than a pointless retry button.
    private(set) var needsPermissionInSettings = false
    /// Set when heat forced a quality reduction mid-recording, so the UI can say so.
    private(set) var thermalDowngradeNote: String?
    /// Zoom stops this phone can reach optically, in Camera-app terms (1.0 is the main lens).
    private(set) var zoomStops: [Double] = [1]
    /// Which physical lens is live — "wide", "telephoto", "ultra-wide".
    private(set) var activeLens: String = "wide"

    let store: SegmentStore
    var settings: CaptureSettings

    private let sessionController = CaptureSessionController()
    /// One writer queue for the life of the engine. The capture outputs bind to it once when the
    /// camera starts, so it must not be re-created per recording.
    private let writerQueue: DispatchQueue
    private var recorder: SegmentRecorder
    private let outputProxy: SampleBufferProxy

    private let observers = NotificationObserverBag()
    private var diskPollTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?
    /// Detaching the recording outputs is asynchronous, so a quick stop-then-start could otherwise
    /// let the teardown land *after* the next recording had attached — silently removing the
    /// outputs from a session that had just started.
    private var outputTeardown: Task<Void, Never>?

    /// How long without a video frame before we call it stalled. Long enough not to trip on a
    /// momentary hitch, short enough that you find out during the warm-up rather than at halftime.
    private let stallThreshold: TimeInterval = 5

    var session: AVCaptureSession { sessionController.session }
    var isCameraLive: Bool { state == .standby || state == .recording }

    init(settings: CaptureSettings) {
        self.settings = settings
        let queue = DispatchQueue(label: "highlights.writer")
        self.writerQueue = queue
        self.outputProxy = SampleBufferProxy(queue: queue)
        self.recorder = SegmentRecorder(settings: settings, queue: queue)
        self.store = SegmentStore(
            directory: URL.applicationSupportDirectory.appendingPathComponent("segments", isDirectory: true),
            retention: settings.retention
        )
        outputProxy.setRecorder(recorder)
        recorder.delegate = self
        sessionController.onLensesResolved = { [weak self] stops in
            Task { @MainActor in self?.zoomStops = stops }
        }
        sessionController.onActiveLensChanged = { [weak self] lens in
            Task { @MainActor in self?.activeLens = lens }
        }
        registerForSystemNotifications()
        Task { await store.restore() }
    }

    // MARK: - Permissions

    static func requestPermissions() async -> Bool {
        // Bind both before combining: `&&` takes an autoclosure, and an `async let` can't be
        // captured by one. Awaiting into locals also keeps the two prompts genuinely concurrent.
        async let video = AVCaptureDevice.requestAccess(for: .video)
        async let audio = AVCaptureDevice.requestAccess(for: .audio)
        let hasVideo = await video
        let hasAudio = await audio
        return hasVideo && hasAudio
    }

    // MARK: - Camera lifecycle

    /// Brings the camera up without recording, so you can frame the shot before kickoff.
    ///
    /// Separating this from recording is what makes an on/off switch possible at all: the session
    /// stays live across a halftime stop, so resuming is instant rather than a two-second
    /// reconfigure while play restarts.
    func startCamera() async {
        guard !isCameraLive, state != .starting else { return }
        state = .starting

        captureLog.info("camera: requesting permissions")
        needsPermissionInSettings = false
        guard await Self.requestPermissions() else {
            // Once denied, iOS never prompts again — a retry button would do nothing, so send
            // the user where the switch actually is.
            needsPermissionInSettings =
                AVCaptureDevice.authorizationStatus(for: .video) != .notDetermined
            captureLog.error("camera: permission denied")
            state = .failed("Highlights needs camera and microphone access to record.")
            return
        }

        do {
            captureLog.info("camera: configuring session")
            try await sessionController.configureAndStart(settings: settings)
        } catch {
            captureLog.error("camera failed: \(error.localizedDescription, privacy: .public)")
            state = .failed(error.localizedDescription)
            return
        }

        if state == .starting { state = .standby }
        startDiskPolling()
        captureLog.info("camera: live")
    }

    func stopCamera() {
        stopRecording()
        diskPollTask?.cancel(); diskPollTask = nil
        sessionController.stop()
        state = .idle
    }

    // MARK: - Recording lifecycle

    func startRecording() async {
        guard state == .standby else { return }
        await outputTeardown?.value

        do {
            let sessionID = try await store.beginSession()
            activeSessionID = sessionID
            // A fresh recorder per session: the writer can't be restarted once finished, and each
            // session needs its own initialization segment anyway. The queue is shared, so frames
            // keep arriving somewhere valid across the handoff.
            let recorder = SegmentRecorder(settings: settings, queue: writerQueue)
            recorder.delegate = self
            self.recorder = recorder
            outputProxy.setRecorder(recorder)
            try await recorder.prepareOnQueue()
            // Attach *after* the writer is ready so the first frames delivered aren't discarded.
            await sessionController.setRecordingActive(
                true, sampleBufferDelegate: outputProxy, recorderQueue: writerQueue
            )
        } catch {
            captureLog.error("record failed: \(error.localizedDescription, privacy: .public)")
            state = .failed(error.localizedDescription)
            return
        }

        elapsed = .zero
        availableHistory = .zero
        thermalDowngradeNote = nil
        // Only the screen needs to stay awake while we're actually capturing.
        UIApplication.shared.isIdleTimerDisabled = true
        state = .recording
        startStallWatchdog()
        captureLog.info("recording: started")
    }

    func stopRecording() {
        guard state == .recording else { return }
        UIApplication.shared.isIdleTimerDisabled = false
        watchdogTask?.cancel(); watchdogTask = nil
        isStalled = false
        let controller = sessionController
        let proxy = outputProxy
        let queue = writerQueue
        outputTeardown = Task {
            await controller.setRecordingActive(
                false, sampleBufferDelegate: proxy, recorderQueue: queue
            )
        }
        recorder.finish {}
        Task { await store.endSession() }
        state = .standby
        captureLog.info("recording: stopped at \(self.elapsed.seconds, privacy: .public)s")
    }

    /// `point` is in the camera's normalized coordinate space.
    func focus(at point: CGPoint) { sessionController.focus(at: point) }

    /// Changes optical zoom live — safe mid-recording, since it doesn't alter the recorded
    /// dimensions and so can't disturb the writer.
    func setZoom(_ factor: Double) {
        settings.zoomFactor = factor
        sessionController.setZoom(factor)
    }

    // MARK: - Disk

    private func startDiskPolling() {
        diskPollTask?.cancel()
        // Every tick stats every segment on disk, so keep it infrequent and skip it entirely in
        // standby, where the number can't be changing.
        diskPollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.state == .recording || self.bytesOnDisk == 0 {
                    self.bytesOnDisk = await self.store.bytesOnDisk()
                }
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }

    /// Frees every byte of stored footage, including clips not yet exported.
    func purgeAllFootage() async {
        await store.purgeAll()
        bytesOnDisk = await store.bytesOnDisk()
    }

    // MARK: - Watchdog

    /// Catches the case where the session reports itself running but has quietly stopped
    /// delivering frames.
    ///
    /// This matters more here than in a normal camera app: the phone is on a tripod with the
    /// screen dimmed and nobody is watching the preview. Without this you'd find out at the end
    /// of the game that the last hour recorded nothing.
    private func startStallWatchdog() {
        let startedAt = Date()
        watchdogTask?.cancel()
        watchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, self.state == .recording else { continue }
                let reference = self.recorder.lastVideoSampleAt ?? startedAt
                self.isStalled = Date().timeIntervalSince(reference) > self.stallThreshold
            }
        }
    }

    // MARK: - Thermal

    /// Sheds load when the phone gets hot rather than waiting for iOS to throttle the encoder
    /// underneath us, which shows up as dropped frames rather than an honest warning.
    ///
    /// Only frame rate is reduced, never resolution: 4K *is* the zoom, and quietly dropping to
    /// 1080p would silently degrade every clip's framing rather than just its smoothness.
    private func handleThermalChange() {
        thermalState = ProcessInfo.processInfo.thermalState
        guard state == .recording, settings.reduceQualityWhenHot else { return }

        switch thermalState {
        case .serious:
            guard settings.frameRate > 24 else { return }
            settings.frameRate = 24
            thermalDowngradeNote = "Dropped to 24 fps to cool down."
            captureLog.info("thermal: reducing frame rate to 24")
            sessionController.setFrameRate(24)
        case .critical:
            // Stabilisation is the most expensive thing still running at this point, and a
            // shakier clip beats a phone that throttles the encoder out from under us.
            if settings.stabilizationEnabled {
                settings.stabilizationEnabled = false
                sessionController.setStabilizationEnabled(false)
                thermalDowngradeNote = "Stabilization off — phone is very hot."
                captureLog.info("thermal: disabling stabilization")
            }
            if settings.frameRate > 24 {
                settings.frameRate = 24
                sessionController.setFrameRate(24)
            }
        default:
            break
        }
    }

    // MARK: - System notifications

    private func registerForSystemNotifications() {
        let center = NotificationCenter.default
        observers.add(center.addObserver(
            forName: AVCaptureSession.wasInterruptedNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.isInterrupted = true }
        })
        observers.add(center.addObserver(
            forName: AVCaptureSession.interruptionEndedNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.isInterrupted = false }
        })
        observers.add(center.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleThermalChange() }
        })
        // `startRunning()` doesn't throw when the capture graph fails to build — the failure
        // arrives here, asynchronously, and without this the app would keep showing a running
        // timer over a session that is dead.
        observers.add(center.addObserver(
            forName: AVCaptureSession.runtimeErrorNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let error = notification.userInfo?[AVCaptureSessionErrorKey] as? NSError
            let reason = error?.localizedFailureReason ?? error?.localizedDescription ?? "unknown error"
            MainActor.assumeIsolated {
                captureLog.error("session runtime error: \(reason, privacy: .public)")
                self?.state = .failed("The camera stopped: \(reason)")
            }
        })
    }
}

// MARK: - SegmentRecorderDelegate

extension CaptureEngine: SegmentRecorderDelegate {
    nonisolated func recorder(_ recorder: SegmentRecorder, didProduceInitializationSegment data: Data) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do { try await self.store.storeInitializationSegment(data) }
            catch { self.state = .failed("Couldn't write to disk: \(error.localizedDescription)") }
        }
    }

    nonisolated func recorder(
        _ recorder: SegmentRecorder, didProduceSegment data: Data, start: CMTime, duration: CMTime
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.store.appendSegment(data, start: start, duration: duration)
                if let earliest = await self.store.earliestAvailable() {
                    self.availableHistory = (start + duration) - earliest
                }
            } catch {
                self.state = .failed("Couldn't write to disk: \(error.localizedDescription)")
            }
        }
    }

    nonisolated func recorder(_ recorder: SegmentRecorder, didAdvanceTo time: CMTime) {
        // Fires per video frame. Coalesce to ~4 Hz so we aren't republishing at 30 Hz into SwiftUI.
        guard time.seconds.truncatingRemainder(dividingBy: 0.25) < (1.0 / 60.0) else { return }
        Task { @MainActor [weak self] in self?.elapsed = time }
    }

    nonisolated func recorder(_ recorder: SegmentRecorder, didFailWith error: Error) {
        Task { @MainActor [weak self] in
            self?.state = .failed("Recording stopped: \(error.localizedDescription)")
        }
    }
}

/// Holds block-based notification tokens and unregisters them when it deallocates.
///
/// Exists because a main-actor-isolated type can't touch its own non-Sendable stored properties
/// from `deinit` (which is nonisolated). Moving the tokens into their own object puts the
/// teardown somewhere it's legal.
private final class NotificationObserverBag: @unchecked Sendable {
    private var tokens: [NSObjectProtocol] = []
    private let lock = NSLock()

    func add(_ token: NSObjectProtocol) {
        lock.withLock { tokens.append(token) }
    }

    deinit {
        tokens.forEach(NotificationCenter.default.removeObserver)
    }
}
