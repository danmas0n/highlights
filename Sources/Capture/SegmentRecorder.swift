import AVFoundation
import Foundation
import VideoToolbox

protocol SegmentRecorderDelegate: AnyObject, Sendable {
    func recorder(_ recorder: SegmentRecorder, didProduceInitializationSegment data: Data)
    func recorder(_ recorder: SegmentRecorder, didProduceSegment data: Data, start: CMTime, duration: CMTime)
    func recorder(_ recorder: SegmentRecorder, didAdvanceTo time: CMTime)
    func recorder(_ recorder: SegmentRecorder, didFailWith error: Error)
}

/// Owns the `AVAssetWriter` and everything that touches it.
///
/// Every method here must run on `queue` — the same queue set as the sample-buffer delegate queue
/// for both capture outputs and as the asset writer's delegate queue. That single-queue discipline
/// is what makes the mutable writer state safe without locks, and it is why this type is
/// deliberately *not* main-actor isolated: sample buffers arrive far too fast to hop actors, and
/// `MainActor.assumeIsolated` in that path would simply be a lie that traps at runtime.
final class SegmentRecorder: NSObject, @unchecked Sendable {

    /// Injected rather than owned. Each recording session gets a fresh recorder, but the capture
    /// outputs bind their delegate queue once when the camera starts — so a per-recorder queue
    /// would leave buffers arriving on the previous recorder's queue and trip the
    /// `dispatchPrecondition` below. The queue has to outlive any single recording.
    let queue: DispatchQueue
    weak var delegate: SegmentRecorderDelegate?

    private let settings: CaptureSettings
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?

    /// PTS of the first video frame. Everything downstream is expressed relative to this so the
    /// timeline starts at zero regardless of the device's arbitrary clock origin.
    private var sessionStartPTS: CMTime?
    private var segmentCursor: CMTime = .zero
    private var hasFailed = false

    /// Presentation time reported for the very first media segment, used as the origin for all
    /// later ones.
    ///
    /// `AVAssetSegmentReport` timestamps arrive in the writer session's *source* time — i.e. the
    /// absolute presentation timestamps coming off the capture clock, which are tens of thousands
    /// of seconds since boot, not zero-based. Bookmarks are stamped with session-relative elapsed
    /// time, so without this the two timelines never intersect and every clip looks like footage
    /// that has already been pruned.
    ///
    /// Anchoring on the first report rather than on `sessionStartPTS` makes this correct whether
    /// the reports turn out to be absolute or already-relative: the first media segment begins at
    /// the session start either way.
    private var segmentOrigin: CMTime?

    /// Wall-clock stamp of the last video sample, for the stall watchdog. Read from another
    /// thread, so it gets its own lock rather than relying on the queue discipline.
    private let frameClock = NSLock()
    private var _lastVideoSampleAt: Date?

    var lastVideoSampleAt: Date? {
        frameClock.withLock { _lastVideoSampleAt }
    }

    init(settings: CaptureSettings, queue: DispatchQueue) {
        self.settings = settings
        self.queue = queue
        super.init()
    }

    // MARK: - Setup

    /// Async entry point for callers that aren't already on `queue`.
    func prepareOnQueue() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                do { try prepare(); continuation.resume() }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    func prepare() throws {
        dispatchPrecondition(condition: .onQueue(queue))

        let writer = AVAssetWriter(contentType: .mpeg4Movie)
        writer.outputFileTypeProfile = .mpeg4AppleHLS
        writer.preferredOutputSegmentInterval = CMTime(seconds: settings.segmentSeconds, preferredTimescale: 1)
        writer.initialSegmentStartTime = .zero
        writer.delegate = self

        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: settings.bitRate,
            AVVideoExpectedSourceFrameRateKey: settings.frameRate,
            // Every segment must begin on an IDR frame or it isn't independently decodable,
            // which would break reassembly of an arbitrary segment range.
            AVVideoMaxKeyFrameIntervalDurationKey: settings.segmentSeconds,
        ]
        if settings.codec == .hevc {
            compression[AVVideoProfileLevelKey] = kVTProfileLevel_HEVC_Main_AutoLevel as String
        }

        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: settings.codec == .hevc ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
            AVVideoWidthKey: settings.resolution.width,
            AVVideoHeightKey: settings.resolution.height,
            AVVideoCompressionPropertiesKey: compression,
        ])
        video.expectsMediaDataInRealTime = true
        guard writer.canAdd(video) else { throw RecorderError.cannotAddInput }
        writer.add(video)

        let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVNumberOfChannelsKey: 1,
            AVSampleRateKey: 44_100,
            AVEncoderBitRateKey: 64_000,
        ])
        audio.expectsMediaDataInRealTime = true
        if writer.canAdd(audio) { writer.add(audio); audioInput = audio }

        guard writer.startWriting() else {
            throw RecorderError.startFailed(writer.error?.localizedDescription ?? "unknown")
        }

        self.writer = writer
        self.videoInput = video
        self.sessionStartPTS = nil
        self.segmentCursor = .zero
        self.segmentOrigin = nil
        self.hasFailed = false
    }

    func finish(completion: @escaping @Sendable () -> Void) {
        queue.async { [weak self] in
            guard let self, let writer = self.writer, writer.status == .writing else {
                completion()
                return
            }
            self.videoInput?.markAsFinished()
            self.audioInput?.markAsFinished()
            writer.finishWriting { completion() }
            self.writer = nil
        }
    }

    // Note: no manual segment flush. `AVAssetWriter.flushSegment()` is only legal when
    // `preferredOutputSegmentInterval` is `kCMTimeIndefinite`; calling it on a writer that is
    // auto-segmenting raises an Objective-C exception. Since we auto-segment every
    // `segmentSeconds`, the tail of a marked moment becomes durable on its own within one
    // segment interval, which is all the manual flush ever bought us.

    // MARK: - Intake

    func append(_ sampleBuffer: CMSampleBuffer, isVideo: Bool) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let writer, writer.status == .writing, !hasFailed else {
            if let writer, writer.status == .failed, !hasFailed {
                hasFailed = true
                delegate?.recorder(self, didFailWith: writer.error ?? RecorderError.startFailed("writer failed"))
            }
            return
        }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        if sessionStartPTS == nil {
            // Anchor on the first *video* frame. Anchoring on audio (which usually arrives first)
            // would open the session before any video exists, leaving a leading gap in the video
            // track that every later composition would have to compensate for.
            guard isVideo else { return }
            sessionStartPTS = pts
            writer.startSession(atSourceTime: pts)
        }

        let input = isVideo ? videoInput : audioInput
        guard let input, input.isReadyForMoreMediaData else { return }
        input.append(sampleBuffer)

        if isVideo, let start = sessionStartPTS {
            frameClock.withLock { _lastVideoSampleAt = Date() }
            delegate?.recorder(self, didAdvanceTo: pts - start)
        }
    }

    enum RecorderError: LocalizedError {
        case cannotAddInput
        case startFailed(String)

        var errorDescription: String? {
            switch self {
            case .cannotAddInput: "Couldn't configure the video encoder."
            case .startFailed(let reason): "Recorder failed to start: \(reason)"
            }
        }
    }
}

// MARK: - AVAssetWriterDelegate

extension SegmentRecorder: AVAssetWriterDelegate {
    func assetWriter(
        _ writer: AVAssetWriter,
        didOutputSegmentData segmentData: Data,
        segmentType: AVAssetSegmentType,
        segmentReport: AVAssetSegmentReport?
    ) {
        switch segmentType {
        case .initialization:
            delegate?.recorder(self, didProduceInitializationSegment: segmentData)

        case .separable:
            // Prefer the video track's report; the audio track's timing can lead or lag it
            // slightly and we key the whole timeline off video.
            let report = segmentReport?.trackReports.first { $0.mediaType == .video }
                ?? segmentReport?.trackReports.first

            let duration = report?.duration
                ?? CMTime(seconds: settings.segmentSeconds, preferredTimescale: 600)

            let start: CMTime
            if let reported = report?.earliestPresentationTimeStamp {
                if segmentOrigin == nil {
                    segmentOrigin = reported
                    captureLog.info(
                        "segment origin anchored at \(reported.seconds, privacy: .public)s"
                    )
                }
                start = reported - (segmentOrigin ?? .zero)
            } else {
                // No timing in the report: fall back to the running cursor, which is already
                // in the normalized timeline.
                start = segmentCursor
            }
            segmentCursor = start + duration

            delegate?.recorder(self, didProduceSegment: segmentData, start: start, duration: duration)

        @unknown default:
            break
        }
    }
}
