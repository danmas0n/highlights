import AVFoundation
import Foundation

/// Owns the `AVCaptureSession` and the capture device.
///
/// Deliberately not main-actor isolated, for the same reason `SegmentRecorder` isn't:
/// `startRunning()` blocks, and session reconfiguration is slow enough that doing either on the
/// main actor visibly stutters the preview. All mutable state is confined to `queue`.
final class CaptureSessionController: @unchecked Sendable {

    /// Handed to `AVCaptureVideoPreviewLayer`, which is UIKit's to touch on the main thread.
    /// The session object itself is internally thread-safe for this use.
    let session = AVCaptureSession()

    private let queue = DispatchQueue(label: "highlights.session")
    private var videoDevice: AVCaptureDevice?
    private var videoConnection: AVCaptureConnection?

    /// Attached only while recording. In standby the preview layer draws straight from the
    /// session, so delivering every 4K frame into our own callback — and running stabilisation
    /// over them — buys nothing and costs a great deal of power.
    private var videoDataOutput: AVCaptureVideoDataOutput?
    private var audioDataOutput: AVCaptureAudioDataOutput?
    /// Likewise held only while recording, so standby doesn't light the microphone indicator.
    private var audioInput: AVCaptureDeviceInput?
    private var currentSettings: CaptureSettings?

    /// Tracks device orientation against gravity. Kept alive for the whole session — reading the
    /// angle once at configure time is what left recordings stuck in the orientation the app
    /// happened to launch in.
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var rotationObservation: NSKeyValueObservation?

    /// Called on the main thread whenever the capture rotation changes, so the preview layer's
    /// own connection can be kept in step.
    var onRotationChange: (@Sendable (CGFloat) -> Void)?

    /// Reports the zoom stops this device can reach optically, in Camera-app terms.
    var onLensesResolved: (@Sendable ([Double]) -> Void)?
    /// Reports which physical lens is live, so the UI can distinguish real zoom from digital.
    var onActiveLensChanged: (@Sendable (String) -> Void)?

    /// Device zoom factor corresponding to a display zoom of 1.0 (the main camera).
    ///
    /// A virtual multi-camera device numbers its zoom from its *widest* constituent, so on a phone
    /// with an ultra-wide, `videoZoomFactor == 1` is 0.5x in the language everyone actually uses.
    private var mainCameraZoomBase: Double = 1
    private var lensObservation: NSKeyValueObservation?

    // MARK: - Start / stop

    func configureAndStart(settings: CaptureSettings) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                do {
                    try configure(settings: settings)
                    session.startRunning()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Attaches or detaches the capture outputs that feed the encoder.
    ///
    /// This is the difference between standby costing a preview and standby costing a full 4K
    /// encode pipeline. Reconfiguring takes a moment, so it happens on the record transition
    /// rather than continuously.
    func setRecordingActive(
        _ active: Bool,
        sampleBufferDelegate: SampleBufferProxy,
        recorderQueue: DispatchQueue
    ) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                defer { continuation.resume() }
                guard let settings = currentSettings else { return }

                session.beginConfiguration()
                defer { session.commitConfiguration() }

                if active {
                    guard videoDataOutput == nil else { return }

                    if let device = AVCaptureDevice.default(for: .audio) {
                        if let input = try? AVCaptureDeviceInput(device: device),
                           session.canAddInput(input) {
                            session.addInput(input)
                            audioInput = input
                        } else {
                            captureReport("audio: microphone input REFUSED by session")
                        }
                    } else {
                        captureReport("audio: no microphone device")
                    }

                    let videoOut = AVCaptureVideoDataOutput()
                    videoOut.videoSettings = [
                        kCVPixelBufferPixelFormatTypeKey as String:
                            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                    ]
                    // Drop late frames rather than queueing them. Refusing to drop means a
                    // momentary encoder stall backs buffers up through the capture pipeline,
                    // which grows memory and heat until it never catches up — and under thermal
                    // throttling that becomes a spiral. One missing frame is invisible.
                    videoOut.alwaysDiscardsLateVideoFrames = true
                    videoOut.setSampleBufferDelegate(sampleBufferDelegate, queue: recorderQueue)
                    guard session.canAddOutput(videoOut) else { return }
                    session.addOutput(videoOut)
                    videoDataOutput = videoOut

                    if let connection = videoOut.connection(with: .video) {
                        // Cinematic Extended runs continuous motion analysis alongside the
                        // encode. Worth it for hand-panning a tripod — but only while we're
                        // actually recording something.
                        if connection.isVideoStabilizationSupported {
                            connection.preferredVideoStabilizationMode = settings.stabilization
                        }
                        videoConnection = connection
                        if let angle = rotationCoordinator?.videoRotationAngleForHorizonLevelCapture,
                           connection.isVideoRotationAngleSupported(angle) {
                            connection.videoRotationAngle = angle
                        }
                    }

                    let audioOut = AVCaptureAudioDataOutput()
                    audioOut.setSampleBufferDelegate(sampleBufferDelegate, queue: recorderQueue)
                    if session.canAddOutput(audioOut) {
                        session.addOutput(audioOut)
                        audioDataOutput = audioOut
                    } else {
                        captureReport("audio: data output REFUSED by session")
                    }
                    captureReport("""
                        audio wiring: input=\(audioInput != nil) output=\(audioDataOutput != nil) \
                        authorized=\(AVCaptureDevice.authorizationStatus(for: .audio).rawValue)
                        """)
                } else {
                    // Clear the delegates before removing, so no buffer can arrive mid-teardown.
                    videoDataOutput?.setSampleBufferDelegate(nil, queue: nil)
                    audioDataOutput?.setSampleBufferDelegate(nil, queue: nil)
                    if let output = videoDataOutput { session.removeOutput(output) }
                    if let output = audioDataOutput { session.removeOutput(output) }
                    if let input = audioInput { session.removeInput(input) }
                    videoDataOutput = nil
                    audioDataOutput = nil
                    audioInput = nil
                    videoConnection = nil
                }
                captureLog.info("recording outputs \(active ? "attached" : "detached", privacy: .public)")
            }
        }
    }

    func stop() {
        queue.async { [self] in
            rotationObservation?.invalidate()
            rotationObservation = nil
            rotationCoordinator = nil
            if session.isRunning { session.stopRunning() }
        }
    }

    /// Turns stabilization off without tearing down the session — the heaviest thing we can shed
    /// while still recording.
    func setStabilizationEnabled(_ enabled: Bool) {
        queue.async { [self] in
            guard let connection = videoConnection, connection.isVideoStabilizationSupported else { return }
            connection.preferredVideoStabilizationMode = enabled ? .cinematicExtended : .off
        }
    }

    /// Changes frame rate without tearing down the session — used to shed thermal load mid-game.
    func setFrameRate(_ fps: Int) {
        queue.async { [self] in
            guard let device = videoDevice, (try? device.lockForConfiguration()) != nil else { return }
            defer { device.unlockForConfiguration() }
            let supported = device.activeFormat.videoSupportedFrameRateRanges.contains {
                $0.minFrameRate <= Double(fps) && Double(fps) <= $0.maxFrameRate
            }
            guard supported else { return }
            let duration = CMTime(value: 1, timescale: CMTimeScale(fps))
            device.activeVideoMinFrameDuration = duration
            device.activeVideoMaxFrameDuration = duration
        }
    }

    deinit {
        rotationObservation?.invalidate()
        lensObservation?.invalidate()
    }

    // MARK: - Configuration

    /// Brings up the camera for preview only. Recording outputs are attached separately by
    /// `setRecordingActive` so standby stays cheap.
    private func configure(settings: CaptureSettings) throws {
        currentSettings = settings
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        // Start from empty. `configure` runs again every time the app returns from the
        // background, and an `AVCaptureSession` keeps its inputs and outputs across a
        // `stopRunning()` — so without this, `canAddInput` refuses the camera that's already
        // attached and the whole thing fails with "couldn't attach the camera".
        for input in session.inputs { session.removeInput(input) }
        for output in session.outputs { session.removeOutput(output) }
        videoConnection = nil
        videoDataOutput = nil
        audioDataOutput = nil
        audioInput = nil
        rotationObservation?.invalidate()
        rotationObservation = nil
        rotationCoordinator = nil

        // `.inputPriority` hands format selection to us — `activeFormat` below picks the exact
        // 4K format, and a preset would otherwise stomp it.
        session.sessionPreset = .inputPriority

        // A virtual device spanning every rear lens, so requesting a zoom factor lets iOS serve it
        // from whichever physical camera can do so optically — and switch between them without us
        // reconfiguring the session mid-game.
        //
        // This used to be pinned to the wide camera on the theory that cropping 4K was reach
        // enough. From a real sideline it isn't: cropping can only subdivide detail the sensor
        // already resolved, and from forty yards there isn't enough of it to subdivide.
        guard let device = Self.preferredCamera() else { throw CaptureError.noCamera }
        videoDevice = device
        captureReport("camera: \(device.localizedName)")

        let videoInput = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(videoInput) else { throw CaptureError.cannotAddInput }
        session.addInput(videoInput)

        // The microphone input is deliberately *not* added here — it goes on with the recording
        // outputs, so standby neither draws mic power nor lights the privacy indicator.

        try configureFormat(on: device, settings: settings)
        resolveLenses(on: device)
        applyZoom(settings.zoomFactor, on: device)
        startTrackingRotation(device: device)
        startTrackingActiveLens(on: device)
    }

    /// Widest-spanning rear camera available, so the zoom range covers as many lenses as possible.
    private static func preferredCamera() -> AVCaptureDevice? {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [
                .builtInTripleCamera,
                .builtInDualWideCamera,
                .builtInDualCamera,
                .builtInWideAngleCamera,
            ],
            mediaType: .video,
            position: .back
        ).devices.first
    }

    // MARK: - Zoom

    /// Works out where the main camera sits in the virtual device's zoom numbering, and which
    /// display zoom factors correspond to a genuine lens change.
    private func resolveLenses(on device: AVCaptureDevice) {
        let constituents = device.constituentDevices
        let switchOvers = device.virtualDeviceSwitchOverVideoZoomFactors.map(\.doubleValue)

        guard !constituents.isEmpty, switchOvers.count >= constituents.count - 1 else {
            // A single-lens device already numbers its zoom from the main camera.
            mainCameraZoomBase = 1
            onLensesResolved?([1])
            return
        }

        // Constituent i covers zoom upward from base(i), where base(0) is 1 and every later base
        // is the switch-over factor immediately before it.
        func base(_ index: Int) -> Double { index == 0 ? 1 : switchOvers[index - 1] }
        let mainIndex = constituents.firstIndex { $0.deviceType == .builtInWideAngleCamera } ?? 0
        mainCameraZoomBase = base(mainIndex)

        let stops = constituents.indices.map { base($0) / mainCameraZoomBase }
        captureReport("lenses: stops=\(stops.map { String(format: "%.1f", $0) }.joined(separator: "/")) base=\(mainCameraZoomBase)")
        onLensesResolved?(stops)
    }

    /// `displayFactor` is in Camera-app terms: 1.0 is the main lens, 5.0 the telephoto.
    func setZoom(_ displayFactor: Double) {
        queue.async { [self] in
            guard let device = videoDevice else { return }
            applyZoom(displayFactor, on: device)
        }
    }

    private func applyZoom(_ displayFactor: Double, on device: AVCaptureDevice) {
        guard (try? device.lockForConfiguration()) != nil else { return }
        defer { device.unlockForConfiguration() }
        let requested = displayFactor * mainCameraZoomBase
        let applied = min(
            max(requested, device.minAvailableVideoZoomFactor),
            device.maxAvailableVideoZoomFactor
        )
        device.videoZoomFactor = applied
        if abs(applied - requested) > 0.01 {
            captureReport("zoom: requested \(requested) clamped to \(applied)")
        }
    }

    /// Watches which physical lens is actually serving the current zoom.
    ///
    /// Worth surfacing: if the active format can't drive the telephoto, iOS quietly digitally
    /// zooms the wide instead. That looks like zoom and isn't — and you want to know which one
    /// you're getting *before* filming a game with it.
    private func startTrackingActiveLens(on device: AVCaptureDevice) {
        lensObservation?.invalidate()
        report(activeLens: device)
        lensObservation = device.observe(\.activePrimaryConstituent, options: [.new]) { [weak self] device, _ in
            self?.report(activeLens: device)
        }
    }

    private func report(activeLens device: AVCaptureDevice) {
        let name: String
        switch device.activePrimaryConstituent?.deviceType ?? device.deviceType {
        case .builtInUltraWideCamera: name = "ultra-wide"
        case .builtInTelephotoCamera: name = "telephoto"
        default: name = "wide"
        }
        captureReport("active lens: \(name), device zoom \(String(format: "%.1f", device.videoZoomFactor))")
        onActiveLensChanged?(name)
    }

    /// Selects the format matching the requested resolution and frame rate, so we get the 4K
    /// source the crop-later workflow depends on.
    private func configureFormat(on device: AVCaptureDevice, settings: CaptureSettings) throws {
        let target = settings.resolution
        let candidates = device.formats.filter { format in
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            guard dims.width == target.width, dims.height == target.height else { return false }
            return format.videoSupportedFrameRateRanges.contains {
                $0.minFrameRate <= Double(settings.frameRate) && Double(settings.frameRate) <= $0.maxFrameRate
            }
        }
        // Among equally-sized formats, take the one that can zoom furthest. On a virtual device the
        // telephoto is reached by crossing a zoom switch-over point, so a format whose maximum zoom
        // falls short of that point can never engage the tele — it would quietly digitally zoom the
        // wide instead, which looks like zoom and isn't.
        guard let format = candidates.max(by: { $0.videoMaxZoomFactor < $1.videoMaxZoomFactor }) else {
            throw CaptureError.unsupportedFormat
        }
        captureReport("format: \(target.label)@\(settings.frameRate), max zoom \(format.videoMaxZoomFactor)")

        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        device.activeFormat = format
        let duration = CMTime(value: 1, timescale: CMTimeScale(settings.frameRate))
        device.activeVideoMinFrameDuration = duration
        device.activeVideoMaxFrameDuration = duration
        if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
        if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
    }

    // MARK: - Rotation

    /// Keeps the recorded video upright as the phone is turned.
    ///
    /// Rotation is applied to the connection rather than by transforming pixels, so turning the
    /// phone mid-game costs nothing and never interrupts the encode. Horizon-level (rather than
    /// interface-level) is the right reference for a tripod: what matters is which way is down,
    /// not which way the UI happens to be laid out.
    private func startTrackingRotation(device: AVCaptureDevice) {
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)
        rotationCoordinator = coordinator

        applyRotation(coordinator.videoRotationAngleForHorizonLevelCapture)

        // Reach the connection through `videoConnection` rather than capturing it: the KVO
        // callback is `@Sendable` and `AVCaptureConnection` is not, so the reference has to be
        // re-read on `queue` where our own isolation guarantees hold.
        rotationObservation = coordinator.observe(
            \.videoRotationAngleForHorizonLevelCapture, options: [.new]
        ) { [weak self] _, change in
            guard let self, let angle = change.newValue else { return }
            self.queue.async { self.applyRotation(angle) }
        }
    }

    private func applyRotation(_ angle: CGFloat) {
        if let connection = videoConnection, connection.isVideoRotationAngleSupported(angle) {
            connection.videoRotationAngle = angle
        }
        onRotationChange?(angle)
    }

    // MARK: - Focus

    /// `point` is in the camera's normalized coordinate space.
    func focus(at point: CGPoint) {
        queue.async { [self] in
            guard let device = videoDevice, (try? device.lockForConfiguration()) != nil else { return }
            defer { device.unlockForConfiguration() }
            if device.isFocusPointOfInterestSupported {
                device.focusPointOfInterest = point
                device.focusMode = .autoFocus
            }
            if device.isExposurePointOfInterestSupported {
                device.exposurePointOfInterest = point
                device.exposureMode = .autoExpose
            }
        }
    }

    enum CaptureError: LocalizedError {
        case noCamera, cannotAddInput, cannotAddOutput, unsupportedFormat

        var errorDescription: String? {
            switch self {
            case .noCamera:
                "No rear camera available. Highlights needs to run on a real iPhone — the Simulator has no camera."
            case .cannotAddInput: "Couldn't attach the camera to the capture session."
            case .cannotAddOutput: "Couldn't attach the recording output."
            case .unsupportedFormat: "This device can't record at the selected resolution and frame rate."
            }
        }
    }
}

/// Bridges the two capture outputs into the current recorder without dragging any actor isolation
/// into the sample-buffer hot path.
///
/// The delegate target changes every time a new recording starts, so the swap is performed on the
/// delivery queue itself — assigning it from the main actor while frames are being read on the
/// capture queue is a data race, and one that would surface as a torn read mid-game.
final class SampleBufferProxy: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate,
                               AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let queue: DispatchQueue
    private weak var recorder: SegmentRecorder?

    init(queue: DispatchQueue) {
        self.queue = queue
        super.init()
    }

    func setRecorder(_ recorder: SegmentRecorder?) {
        queue.async { [weak self] in self?.recorder = recorder }
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }
        recorder?.append(sampleBuffer, isVideo: output is AVCaptureVideoDataOutput)
    }
}
