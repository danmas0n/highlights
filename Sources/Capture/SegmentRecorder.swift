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

    /// Sample tallies, so "are we capturing audio?" is a question with an answer rather than a
    /// guess made from a downstream symptom.
    private var videoSamples = 0
    private var audioSamples = 0
    private var audioDropped = 0

    /// Wall-clock stamp of the last video sample, for the stall watchdog. Read from another
    /// thread, so it gets its own lock rather than relying on the queue discipline.
    private let frameClock = NSLock()
    private var _lastVideoSampleAt: Date?

    var lastVideoSampleAt: Date? {
        frameClock.withLock { _lastVideoSampleAt }
    }

    /// Audio goes to its own continuous file rather than into the segments.
    ///
    /// Muxing audio into HLS-segmented output turned out to fail two ways at once: the writer
    /// stalls audio while interleaving it against video (a third of buffers were refused), and
    /// what it did write came back unreadable from a single-fragment file. Audio at 64 kbps is
    /// about half a megabyte a minute, so it needs neither segmenting nor pruning — one plain file
    /// per session, muxed in at export by time range, and the whole problem disappears.
    private let audioURL: URL
    private var audioWriter: AVAssetWriter?

    init(settings: CaptureSettings, queue: DispatchQueue, audioURL: URL) {
        self.settings = settings
        self.queue = queue
        self.audioURL = audioURL
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

        guard writer.startWriting() else {
            throw RecorderError.startFailed(writer.error?.localizedDescription ?? "unknown")
        }

        try? FileManager.default.removeItem(at: audioURL)
        let audioWriter = try AVAssetWriter(outputURL: audioURL, fileType: .mp4)
        // Fragmented, so the file is readable while still being written. Without this the moov
        // atom only lands at finishWriting, and a clip opened mid-game would have no audio until
        // the recording stopped. One-second fragments rather than the video's four: audio
        // fragments cost almost nothing, and the readable extent then trails live by at most a
        // second instead of leaving the tail of a just-stopped clip silent.
        audioWriter.movieFragmentInterval = CMTime(seconds: 1, preferredTimescale: 1)
        let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVNumberOfChannelsKey: 1,
            AVSampleRateKey: 44_100,
            AVEncoderBitRateKey: 64_000,
        ])
        audio.expectsMediaDataInRealTime = true
        guard audioWriter.canAdd(audio) else { throw RecorderError.cannotAddInput }
        audioWriter.add(audio)
        guard audioWriter.startWriting() else {
            throw RecorderError.startFailed(audioWriter.error?.localizedDescription ?? "audio writer")
        }

        self.writer = writer
        self.videoInput = video
        self.audioWriter = audioWriter
        self.audioInput = audio
        self.videoSamples = 0
        self.audioSamples = 0
        self.audioDropped = 0
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
            captureReport("""
                recorded \(self.videoSamples) video / \(self.audioSamples) audio samples \
                (\(self.audioDropped) audio dropped)
                """)
            self.videoInput?.markAsFinished()
            self.audioInput?.markAsFinished()
            // Finish both writers, then report once. Each is finished on its own rather than
            // chained inside the other's completion, which would carry a non-Sendable writer
            // into a @Sendable closure; a small counter joins them instead.
            let pending = FinishGate(count: self.audioWriter?.status == .writing ? 2 : 1, then: completion)
            writer.finishWriting { pending.arrive() }
            if let audioWriter = self.audioWriter, audioWriter.status == .writing {
                audioWriter.finishWriting { pending.arrive() }
            }
            self.writer = nil
            self.audioWriter = nil
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
            // track that every later composition would have to compensate for. The audio writer
            // starts at the same instant, so the two files share a timeline origin.
            guard isVideo else { return }
            sessionStartPTS = pts
            writer.startSession(atSourceTime: pts)
            audioWriter?.startSession(atSourceTime: pts)
        }

        if isVideo {
            guard let videoInput, videoInput.isReadyForMoreMediaData else { return }
            videoInput.append(sampleBuffer)
            videoSamples += 1
        } else {
            guard let audioWriter, audioWriter.status == .writing,
                  let audioInput, audioInput.isReadyForMoreMediaData else {
                audioDropped += 1
                return
            }
            audioInput.append(sampleBuffer)
            audioSamples += 1
        }

        if isVideo, let start = sessionStartPTS {
            frameClock.withLock { _lastVideoSampleAt = Date() }
            delegate?.recorder(self, didAdvanceTo: pts - start)
        }
    }

    /// Runs `then` once `count` arrivals have been recorded, from whichever thread arrives last.
    private final class FinishGate: @unchecked Sendable {
        private let lock = NSLock()
        private var remaining: Int
        private let then: @Sendable () -> Void

        init(count: Int, then: @escaping @Sendable () -> Void) {
            self.remaining = count
            self.then = then
        }

        func arrive() {
            let done: Bool = lock.withLock {
                remaining -= 1
                return remaining == 0
            }
            if done { then() }
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
