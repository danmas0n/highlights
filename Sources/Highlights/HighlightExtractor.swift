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

    /// Captures why AVFoundation considers a video composition invalid.
    private final class VideoCompositionValidator: NSObject, AVVideoCompositionValidationHandling {
        private(set) var problems: [String] = []
        var summary: String { problems.isEmpty ? "no detail reported" : problems.joined(separator: "; ") }

        func videoComposition(
            _ videoComposition: AVVideoComposition,
            shouldContinueValidatingAfterFindingInvalidValueForKey key: String
        ) -> Bool {
            problems.append("invalid value for \(key)")
            return true
        }

        func videoComposition(
            _ videoComposition: AVVideoComposition,
            shouldContinueValidatingAfterFindingEmptyTimeRange timeRange: CMTimeRange
        ) -> Bool {
            problems.append("empty time range at \(timeRange.start.seconds)s")
            return true
        }

        func videoComposition(
            _ videoComposition: AVVideoComposition,
            shouldContinueValidatingAfterFindingInvalidTimeRangeIn videoCompositionInstruction: any AVVideoCompositionInstructionProtocol
        ) -> Bool {
            problems.append("invalid instruction time range")
            return true
        }

        func videoComposition(
            _ videoComposition: AVVideoComposition,
            shouldContinueValidatingAfterFindingInvalidTrackIDIn videoCompositionInstruction: any AVVideoCompositionInstructionProtocol,
            layerInstruction: AVVideoCompositionLayerInstruction,
            asset: AVAsset
        ) -> Bool {
            problems.append("layer instruction references a track not in the asset")
            return true
        }
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

        // Only build a video composition when the crop actually does something. An uncropped
        // export is the common case — you framed it wide and it was fine — and compositing it
        // means re-rendering every 4K frame to produce a pixel-identical result. Skipping it is
        // faster, cooler, and removes an entire class of "invalid video composition" failure
        // from the path most exports take.
        let videoComposition: AVMutableVideoComposition?
        if cropPath.isFullFrame {
            videoComposition = nil
        } else {
            videoComposition = ClipComposer.makeVideoComposition(
                track: videoTrack,
                naturalSize: try await videoTrack.load(.naturalSize),
                preferredTransform: try await videoTrack.load(.preferredTransform),
                cropPath: cropPath,
                quality: quality,
                duration: composition.duration
            )
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("highlight-\(highlight.id.uuidString).mov")
        try? FileManager.default.removeItem(at: outputURL)

        // Without a composition to set the size, the preset has to do the downscaling itself.
        let presetName: String
        if videoComposition == nil, quality == .fullHD {
            presetName = AVAssetExportPreset1920x1080
        } else {
            presetName = AVAssetExportPresetHEVCHighestQuality
        }

        // The initialiser returns nil for a preset this asset can't use, which is a cheaper and
        // less deprecated compatibility check than asking for the whole list.
        var resolvedPreset = presetName
        var made = AVAssetExportSession(asset: composition, presetName: presetName)
        if made == nil {
            captureLog.error("preset \(presetName, privacy: .public) unavailable; falling back")
            resolvedPreset = AVAssetExportPresetHighestQuality
            made = AVAssetExportSession(asset: composition, presetName: resolvedPreset)
        }
        guard let session = made else {
            throw ExtractError.exportFailed("Couldn't create an export session.")
        }
        session.outputURL = outputURL
        session.outputFileType = .mov
        session.videoComposition = videoComposition
        session.shouldOptimizeForNetworkUse = true

        // Ask AVFoundation to check the composition before it refuses to export it. Its own
        // failure surfaces as the useless string "Operation Stopped"; the validation delegate
        // names the offending instruction instead.
        if let videoComposition {
            let validator = VideoCompositionValidator()
            let valid = (try? await videoComposition.isValid(
                for: composition,
                timeRange: CMTimeRange(start: .zero, duration: composition.duration),
                validationDelegate: validator
            )) ?? false
            if !valid {
                captureLog.error("""
                    invalid video composition: \(validator.summary, privacy: .public) \
                    renderSize=\(Int(videoComposition.renderSize.width), privacy: .public)×\
                    \(Int(videoComposition.renderSize.height), privacy: .public) \
                    duration=\(composition.duration.seconds, privacy: .public)s
                    """)
            }
        }

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
            // "Operation Stopped" is AVFoundation's catch-all description for several distinct
            // failures, so log the domain and code — that's what actually identifies the cause.
            let error = session.error as NSError?
            captureLog.error("""
                export failed: \(error?.domain ?? "?", privacy: .public) \
                code=\(error?.code ?? 0, privacy: .public) \
                "\(error?.localizedDescription ?? "unknown", privacy: .public)" \
                underlying=\(String(describing: error?.userInfo[NSUnderlyingErrorKey]), privacy: .public) \
                preset=\(resolvedPreset, privacy: .public) \
                composited=\(videoComposition != nil, privacy: .public)
                """)
            throw ExtractError.exportFailed(
                session.error?.localizedDescription ?? "unknown error"
            )
        }
        progress?(1.0)
        // Bound separately: `??` takes an autoclosure, which can't contain an `await`.
        let naturalSize = (try? await videoTrack.load(.naturalSize)) ?? .zero
        let renderSize = videoComposition?.renderSize ?? naturalSize
        captureLog.info("""
            exported \(composition.duration.seconds, privacy: .public)s at \
            \(Int(renderSize.width), privacy: .public)×\(Int(renderSize.height), privacy: .public) \
            preset=\(resolvedPreset, privacy: .public)
            """)

        var identifier: String?
        if saveToPhotoLibrary {
            identifier = try await saveToLibrary(outputURL)
        }
        return Output(
            fileURL: outputURL,
            assetIdentifier: identifier,
            renderSize: renderSize
        )
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
