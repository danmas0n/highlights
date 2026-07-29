import AVFoundation
import Foundation
import Photos
import UIKit

/// Turns a bookmark plus the segments on disk into a finished clip in the photo library.
///
/// This is where the "shoot wide, zoom later" trade is cashed in: the source is 4K, so a crop
/// window at 50% of source width is exactly 1080p with no scaling at all.
actor HighlightExtractor {

    enum ExtractError: LocalizedError {
        case footageUnavailable
        case noVideoTrack
        case exportFailed(String)
        case photoLibraryDenied

        var errorDescription: String? {
            switch self {
            case .footageUnavailable:
                "That moment's footage has been deleted. Increase the retention window in Settings to keep more history."
            case .noVideoTrack: "The recorded footage didn't contain a video track."
            case .exportFailed(let reason): "Export failed: \(reason)"
            case .photoLibraryDenied: "Highlights needs permission to add clips to your photo library."
            }
        }
    }

    struct Output {
        let fileURL: URL
        let assetIdentifier: String?
        let renderSize: CGSize
    }

    /// Narrow escape hatch for carrying a non-Sendable reference into a child task where the
    /// specific access is known to be safe. Kept private so it can't become a habit.
    private final class UncheckedBox<T>: @unchecked Sendable {
        let value: T
        init(_ value: T) { self.value = value }
    }

    private let store: SegmentStore

    init(store: SegmentStore) {
        self.store = store
    }

    // MARK: - Preview

    /// Materialises the highlight's *full* capture window on disk for the editor.
    ///
    /// Returns the raw parts rather than a composition because `AVComposition` isn't `Sendable`;
    /// the editor rebuilds it locally via `ClipComposer`, so preview and export share the timing
    /// logic without sharing a non-Sendable object across the actor boundary.
    func materialise(_ highlight: Highlight) async throws -> SegmentStore.ReassembledClip {
        let range = highlight.timeRange
        guard await store.canSatisfy(range, in: highlight.sessionID) else {
            throw ExtractError.footageUnavailable
        }
        return try await store.reassemble(range: range, in: highlight.sessionID)
    }

    // MARK: - Export

    func export(
        highlight: Highlight,
        quality: CaptureSettings.ExportQuality,
        saveToPhotoLibrary: Bool = true,
        progress: (@Sendable (Float) -> Void)? = nil
    ) async throws -> Output {
        let clip = try await materialise(highlight)

        let composition = try await ClipComposer.makeComposition(
            clip: clip, window: highlight.trimmedRange
        )
        guard let videoTrack = composition.tracks(withMediaType: .video).first else {
            throw ExtractError.noVideoTrack
        }

        let cropPath = highlight.cropPath ?? .fixed(widthFraction: 1.0)
        let videoComposition = try await makeVideoComposition(
            track: videoTrack,
            cropPath: cropPath,
            quality: quality,
            duration: composition.duration
        )

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("highlight-\(highlight.id.uuidString).mov")
        try? FileManager.default.removeItem(at: outputURL)

        // `HEVCHighestQuality` caps at 1080p on some presets; the passthrough-ish
        // `HEVC3840x2160` and friends force a ceiling we don't want either. `AVAssetExportPreset`
        // choice matters less than the video composition's render size, which we set explicitly.
        guard let session = AVAssetExportSession(
            asset: composition, presetName: AVAssetExportPresetHEVCHighestQuality
        ) else {
            throw ExtractError.exportFailed("Couldn't create an export session.")
        }
        session.outputURL = outputURL
        session.outputFileType = .mov
        session.videoComposition = videoComposition
        session.shouldOptimizeForNetworkUse = true

        // `AVAssetExportSession` isn't Sendable, but reading `.progress` while the export runs is
        // exactly what the property is for. Box it rather than making the whole method
        // non-concurrent for a progress bar.
        let progressTask = progress.map { report -> Task<Void, Never> in
            let box = UncheckedBox(session)
            return Task {
                while !Task.isCancelled {
                    report(box.value.progress)
                    try? await Task.sleep(for: .milliseconds(200))
                }
            }
        }
        defer { progressTask?.cancel() }

        await session.export()

        guard session.status == .completed else {
            throw ExtractError.exportFailed(session.error?.localizedDescription ?? "unknown error")
        }
        progress?(1.0)
        captureLog.info("""
            exported \(composition.duration.seconds, privacy: .public)s at \
            \(Int(videoComposition.renderSize.width), privacy: .public)×\
            \(Int(videoComposition.renderSize.height), privacy: .public)
            """)

        var identifier: String?
        if saveToPhotoLibrary {
            identifier = try await saveToLibrary(outputURL)
        }
        return Output(
            fileURL: outputURL,
            assetIdentifier: identifier,
            renderSize: videoComposition.renderSize
        )
    }

    // MARK: - Video composition

    /// Builds the crop as a sequence of transform ramps on the composition's layer instruction.
    ///
    /// Using ramps rather than a custom `AVVideoCompositing` keeps the whole thing on
    /// AVFoundation's own hardware-accelerated render path, with no per-frame callback into our
    /// code, and the same composition can be handed to `AVPlayer` for preview unchanged.
    private func makeVideoComposition(
        track: AVCompositionTrack,
        cropPath: CropPath,
        quality: CaptureSettings.ExportQuality,
        duration: CMTime
    ) async throws -> AVMutableVideoComposition {
        let naturalSize = try await track.load(.naturalSize)
        let preferredTransform = try await track.load(.preferredTransform)

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

    // MARK: - Photos

    private func saveToLibrary(_ url: URL) async throws -> String {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw ExtractError.photoLibraryDenied }

        var identifier: String?
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .video, fileURL: url, options: nil)
            identifier = request.placeholderForCreatedAsset?.localIdentifier
        }
        guard let identifier else { throw ExtractError.exportFailed("Couldn't confirm the saved clip.") }
        return identifier
    }
}
