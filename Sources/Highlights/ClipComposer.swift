import AVFoundation
import Foundation

/// Turns the run of per-segment files from `SegmentStore` into a single, correctly-timed asset.
///
/// Shared by the editor's preview, the subject tracker, and the exporter so all three agree on
/// timing — a preview that disagreed with the exported file about where a clip starts would be
/// worse than no preview at all.
enum ClipComposer {

    enum ComposeError: LocalizedError {
        case noVideoTrack
        case emptyWindow

        var errorDescription: String? {
            switch self {
            case .noVideoTrack: "The recorded footage didn't contain a video track."
            case .emptyWindow: "That clip has no footage in it."
            }
        }
    }

    /// Builds a composition trimmed to `window`, expressed in the recording session's timeline.
    static func makeComposition(
        clip: SegmentStore.ReassembledClip,
        window: CMTimeRange
    ) async throws -> sending AVMutableComposition {
        let stitched = try await stitch(parts: clip.parts)
        let transform = stitched.tracks(withMediaType: .video).first?.preferredTransform
        let stitchedDuration = stitched.duration

        // Map the requested session-timeline window onto the stitched timeline, then clamp: the
        // post-roll may still have been encoding when the clip was opened.
        let partsStart = CMTime(seconds: clip.startSeconds, preferredTimescale: 600)
        let localStart = CMTimeMaximum(window.start - partsStart, .zero)
        let available = stitchedDuration - localStart
        guard available > .zero else { throw ComposeError.emptyWindow }
        let localRange = CMTimeRange(
            start: localStart,
            duration: CMTimeMinimum(window.duration, available)
        )

        let trimmed = AVMutableComposition()
        try await trimmed.insertTimeRange(localRange, of: stitched, at: .zero)
        if let track = trimmed.tracks(withMediaType: .video).first, let transform {
            track.preferredTransform = transform
        }

        captureLog.info("""
            composed \(clip.parts.count, privacy: .public) parts → \
            stitched=\(stitchedDuration.seconds, privacy: .public)s \
            trimmed=\(trimmed.duration.seconds, privacy: .public)s \
            (requested \(window.duration.seconds, privacy: .public)s)
            """)

        return trimmed
    }

    /// Lays the parts end to end, reproducing the recording session's timeline offset by the
    /// first part's start.
    ///
    /// The parts are contiguous by construction — they come from one uninterrupted encode — so
    /// appending them in order is enough; no gap detection is needed.
    static func stitch(parts: [URL]) async throws -> sending AVMutableComposition {
        let stitched = AVMutableComposition()
        guard let stitchedVideo = stitched.addMutableTrack(
            withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid
        ) else { throw ComposeError.noVideoTrack }
        let stitchedAudio = stitched.addMutableTrack(
            withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid
        )

        var cursor = CMTime.zero
        var transform: CGAffineTransform?

        for part in parts {
            let asset = AVURLAsset(
                url: part, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
            )
            guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else { continue }
            let videoRange = try await videoTrack.load(.timeRange)
            guard videoRange.duration.isNumeric, videoRange.duration > .zero else { continue }

            try stitchedVideo.insertTimeRange(videoRange, of: videoTrack, at: cursor)
            if transform == nil {
                transform = try await videoTrack.load(.preferredTransform)
            }

            if let stitchedAudio,
               let audioTrack = try await asset.loadTracks(withMediaType: .audio).first {
                let audioRange = try await audioTrack.load(.timeRange)
                // Audio fragments can be marginally shorter than their video counterparts. Placing
                // audio at the *video* cursor rather than its own running total keeps a few lost
                // milliseconds of sound from desynchronising everything after it.
                try? stitchedAudio.insertTimeRange(audioRange, of: audioTrack, at: cursor)
            }

            cursor = cursor + videoRange.duration
        }

        guard cursor > .zero else { throw ComposeError.emptyWindow }
        if let transform { stitchedVideo.preferredTransform = transform }
        return stitched
    }
}
