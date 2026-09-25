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
        window: CMTimeRange,
        includeAudio: Bool = true
    ) async throws -> sending AVMutableComposition {
        let stitched = try await stitch(parts: clip.parts)
        let transform = stitched.tracks(withMediaType: .video).first?.preferredTransform
        let stitchedDuration = stitched.duration
        if includeAudio {
            try await addAudio(to: stitched, from: clip, coveringDuration: stitchedDuration)
        }

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
        // Trimming can empty a track too — an audio tail shorter than the video means a window
        // near the end may contain no audio at all.
        removeEmptyTracks(from: trimmed)

        captureLog.info("""
            composed \(clip.parts.count, privacy: .public) parts → \
            stitched=\(stitchedDuration.seconds, privacy: .public)s \
            trimmed=\(trimmed.duration.seconds, privacy: .public)s \
            (requested \(window.duration.seconds, privacy: .public)s)
            """)

        return trimmed
    }

    /// Lays the video parts end to end, reproducing the recording session's timeline offset by
    /// the first part's start. Video only; audio comes from the session file via `addAudio`.
    ///
    /// The parts are contiguous by construction — they come from one uninterrupted encode — so
    /// appending them in order is enough; no gap detection is needed.
    static func stitch(parts: [URL]) async throws -> sending AVMutableComposition {
        let stitched = AVMutableComposition()
        guard let stitchedVideo = stitched.addMutableTrack(
            withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid
        ) else { throw ComposeError.noVideoTrack }

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
            cursor = cursor + videoRange.duration
        }

        guard cursor > .zero else { throw ComposeError.emptyWindow }
        if let transform { stitchedVideo.preferredTransform = transform }
        captureReport("stitched \(parts.count) parts: video=\(cursor.seconds)s")
        return stitched
    }

    /// Lays the session's continuous audio under the stitched video.
    ///
    /// Both files anchor their timelines on the first video frame, so the audio covering the
    /// stitched span is simply `[clip.startSeconds, clip.startSeconds + duration]` of the audio
    /// file, placed at zero. Best-effort throughout: a clip without sound is still a clip.
    private static func addAudio(
        to composition: AVMutableComposition,
        from clip: SegmentStore.ReassembledClip,
        coveringDuration duration: CMTime
    ) async throws {
        guard let audioURL = clip.audioURL else {
            captureReport("audio: no session audio file")
            return
        }
        let asset = AVURLAsset(url: audioURL, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard let audioTrack = try await asset.loadTracks(withMediaType: .audio).first else {
            captureReport("audio: session file has no audio track")
            return
        }
        let available = try await audioTrack.load(.timeRange)
        let wanted = CMTimeRange(
            start: CMTime(seconds: clip.startSeconds, preferredTimescale: 600),
            duration: duration
        )
        // The audio file is still being written during a game, so its readable extent can trail
        // the video by up to one fragment. Take what's there.
        let usable = CMTimeRangeGetIntersection(wanted, otherRange: available)
        guard usable.duration > .zero else {
            captureReport("audio: file covers \(available.start.seconds)–\(available.end.seconds)s, clip wants \(wanted.start.seconds)–\(wanted.end.seconds)s; none usable")
            return
        }
        guard let target = composition.addMutableTrack(
            withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid
        ) else { return }
        try target.insertTimeRange(usable, of: audioTrack, at: usable.start - wanted.start)
        captureReport("audio: laid \(usable.duration.seconds)s of \(duration.seconds)s")
    }

    /// Drops tracks that ended up with no media in them.
    ///
    /// The audio track is created up front and filled best-effort, so a clip whose fragments
    /// carried no usable audio leaves a zero-length track behind. `AVPlayer` shrugs at that, which
    /// is why preview always looked fine, but `AVAssetExportSession` can refuse the whole export —
    /// reporting only the catch-all "Operation Stopped".
    private static func removeEmptyTracks(from composition: AVMutableComposition) {
        for track in composition.tracks where track.timeRange.duration <= .zero || track.segments.isEmpty {
            captureReport("dropping empty \(track.mediaType.rawValue) track")
            composition.removeTrack(track)
        }
    }

    // MARK: - Crop compositing

    /// Builds the crop as a sequence of transform ramps on the composition's layer instruction.
    ///
    /// Shared by the exporter and the full-screen preview, so what you inspect before saving is
    /// produced by exactly the same code that writes the file.
    ///
    /// Using ramps rather than a custom `AVVideoCompositing` keeps the whole thing on
    /// AVFoundation's own hardware-accelerated render path, with no per-frame callback into our
    /// code, and the same composition can be handed to `AVPlayer` for preview unchanged.
    /// Synchronous on purpose. The track's `naturalSize` and `preferredTransform` are loaded by
    /// the caller and passed in, which keeps a non-Sendable `AVCompositionTrack` from crossing an
    /// isolation boundary — it stays in whatever context already owns the composition.
    static func makeVideoComposition(
        track: AVCompositionTrack,
        naturalSize: CGSize,
        preferredTransform: CGAffineTransform,
        cropPath: CropPath,
        quality: CaptureSettings.ExportQuality,
        duration: CMTime
    ) -> AVMutableVideoComposition {
        let orientedSize = naturalSize.applying(preferredTransform)
        let sourceSize = CGSize(width: abs(orientedSize.width), height: abs(orientedSize.height))
        let sourceAspect = sourceSize.width / sourceSize.height

        let renderSize = quality.renderSize(
            forCropFraction: cropPath.rect(at: 0, sourceAspect: sourceAspect).width,
            sourceSize: sourceSize
        )

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)

        func transform(at time: Double) -> CGAffineTransform {
            let rect = cropPath.rect(at: time, sourceAspect: sourceAspect)
            let cropOrigin = CGPoint(x: rect.origin.x * sourceSize.width, y: rect.origin.y * sourceSize.height)
            let cropWidth = max(rect.width * sourceSize.width, 1)
            let scale = renderSize.width / cropWidth

            // Orientation first, then scale the crop up to the render size, then slide the crop's
            // top-left corner to the origin. Order matters: translating before scaling would move
            // by unscaled pixels.
            return preferredTransform
                .concatenating(CGAffineTransform(scaleX: scale, y: scale))
                .concatenating(CGAffineTransform(translationX: -cropOrigin.x * scale, y: -cropOrigin.y * scale))
        }

        if cropPath.isStatic {
            layer.setTransform(transform(at: 0), at: .zero)
        } else {
            // Sample densely enough that the piecewise-linear ramps are indistinguishable from
            // the smoothstep curve, but not so densely that we emit thousands of ramps.
            let step = 1.0 / 10.0
            var time = 0.0
            while time < duration.seconds {
                let next = min(time + step, duration.seconds)
                layer.setTransformRamp(
                    fromStart: transform(at: time),
                    toEnd: transform(at: next),
                    timeRange: CMTimeRange(
                        start: CMTime(seconds: time, preferredTimescale: 600),
                        duration: CMTime(seconds: next - time, preferredTimescale: 600)
                    )
                )
                time = next
            }
        }

        instruction.layerInstructions = [layer]

        let videoComposition = AVMutableVideoComposition()
        videoComposition.instructions = [instruction]
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
        return videoComposition
    }
}
