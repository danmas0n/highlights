import AVFoundation
import CoreGraphics
import Foundation
import Vision

/// Follows a subject across a clip and produces a smoothed crop path.
///
/// This runs offline in the editor, never during capture, which is what makes it viable: it can
/// take ten seconds and use as much of the neural engine as it likes, because nobody is waiting
/// on a live preview. Realtime tracking on a hot phone that is also encoding 4K would be a much
/// worse trade for a much worse result.
actor SubjectTracker {

    struct Observation {
        let time: Double
        let center: CGPoint
        let confidence: Float
    }

    enum TrackError: LocalizedError {
        case noVideoTrack
        case trackingLost

        var errorDescription: String? {
            switch self {
            case .noVideoTrack: "Couldn't read the clip's video."
            case .trackingLost: "Lost track of your player. Try tapping them in a frame where they're clearly visible."
            }
        }
    }

    /// Samples the clip at `sampleRate` Hz, tracking the box seeded at `initialBox`.
    ///
    /// Takes a file URL rather than an `AVAsset` because `AVAsset` isn't `Sendable` and this runs
    /// on an actor. The asset is built here and never leaves.
    ///
    /// - Parameters:
    ///   - initialBox: normalized, Vision coordinate space (origin bottom-left).
    ///   - seedTime: where in the clip the user tapped. Tracking runs backward to the clip start
    ///     and forward to the end, because the user almost always picks a frame where the subject
    ///     is obvious — usually mid-action, not at the very beginning.
    /// - Parameters:
    ///   - window: the span of the stitched timeline to track over, bounded by the trim handles —
    ///     there's no point tracking frames that won't be exported.
    ///   - seedTime: also in the stitched timeline.
    func track(
        parts: [URL],
        initialBox: CGRect,
        seedTime: Double,
        window: ClosedRange<Double>,
        sampleRate: Double = 10,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> [Observation] {
        // Stitched through the same path the preview uses, so a tracked crop path lines up with
        // the footage the user was watching when they seeded it.
        let asset = try await ClipComposer.stitch(parts: parts)
        guard asset.tracks(withMediaType: .video).first != nil else {
            throw TrackError.noVideoTrack
        }
        let seed = min(max(seedTime, window.lowerBound), window.upperBound)

        // Sequential rather than concurrent: two image generators decoding the same file at once
        // thrash the hardware decoder and finish no sooner than doing them in turn.
        let backward = try await run(
            asset: asset, initialBox: initialBox,
            from: seed, to: window.lowerBound, sampleRate: sampleRate, reversed: true
        )
        progress?(0.5)
        let forward = try await run(
            asset: asset, initialBox: initialBox,
            from: seed, to: window.upperBound, sampleRate: sampleRate, reversed: false
        )
        progress?(1.0)

        let results = backward.reversed() + forward
        guard !results.isEmpty else { throw TrackError.trackingLost }
        return results.sorted { $0.time < $1.time }
    }

    private func run(
        asset: AVAsset,
        initialBox: CGRect,
        from: Double,
        to: Double,
        sampleRate: Double,
        reversed: Bool
    ) async throws -> [Observation] {
        let step = 1.0 / sampleRate
        var times: [Double] = []
        if reversed {
            var t = from - step
            while t >= to { times.append(t); t -= step }
        } else {
            var t = from
            while t <= to { times.append(t); t += step }
        }
        guard !times.isEmpty else { return [] }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        // Tolerances at zero: a tracker fed frames that don't match their claimed timestamps
        // produces a crop path that drifts out of sync with the action.
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        // Downscale aggressively — tracking a player doesn't need 4K, and the decode is the
        // dominant cost here.
        generator.maximumSize = CGSize(width: 960, height: 540)

        let sequenceHandler = VNSequenceRequestHandler()
        var currentBox = initialBox
        var observations: [Observation] = []
        var consecutiveFailures = 0

        for time in times {
            guard !Task.isCancelled else { break }
            let cmTime = CMTime(seconds: time, preferredTimescale: 600)
            guard let cgImage = try? generator.copyCGImage(at: cmTime, actualTime: nil) else { continue }

            let request = VNTrackObjectRequest(detectedObjectObservation:
                VNDetectedObjectObservation(boundingBox: currentBox))
            request.trackingLevel = .accurate

            do {
                try sequenceHandler.perform([request], on: cgImage, orientation: .up)
            } catch {
                consecutiveFailures += 1
                if consecutiveFailures > 5 { break }
                continue
            }

            guard let result = request.results?.first as? VNDetectedObjectObservation else {
                consecutiveFailures += 1
                if consecutiveFailures > 5 { break }
                continue
            }

            // Vision keeps returning boxes long after it has actually lost the subject, with
            // steadily decaying confidence. Cutting out here beats emitting a path that
            // confidently follows a patch of grass.
            if result.confidence < 0.3 {
                consecutiveFailures += 1
                if consecutiveFailures > 5 { break }
                continue
            }
            consecutiveFailures = 0
            currentBox = result.boundingBox

            // Vision's origin is bottom-left; crop paths are top-left.
            let center = CGPoint(
                x: result.boundingBox.midX,
                y: 1 - result.boundingBox.midY
            )
            observations.append(Observation(time: time, center: center, confidence: result.confidence))
        }

        return observations
    }
}
