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
        /// Which strategy actually produced the file, so the UI can be honest about it.
        let strategyLabel: String
        /// False when the export had to fall back past the crop to succeed at all.
        let croppedAsRequested: Bool
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

    /// One way of trying to produce the file, in descending order of ambition.
    private struct Strategy {
        let label: String
        let preset: String
        /// Passthrough ignores a video composition entirely, so a crop can't survive it.
        let appliesCrop: Bool
    }

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
        let naturalSize = (try? await videoTrack.load(.naturalSize)) ?? .zero
        let preferredTransform = (try? await videoTrack.load(.preferredTransform)) ?? .identity

        // Only composite when the crop actually does something. An uncropped export is the common
        // case, and compositing it means re-rendering every 4K frame to produce a pixel-identical
        // result.
        let cropPath = highlight.cropPath ?? .fixed(widthFraction: 1.0)
        let wantsCrop = !cropPath.isFullFrame

        var videoComposition: AVMutableVideoComposition?
        if wantsCrop {
            let built = ClipComposer.makeVideoComposition(
                track: videoTrack,
                naturalSize: naturalSize,
                preferredTransform: preferredTransform,
                cropPath: cropPath,
                quality: quality,
                duration: composition.duration
            )
            // Ask AVFoundation why it dislikes a composition *before* it refuses to export one:
            // its own failure surfaces as the useless string "Operation Stopped".
            let validator = VideoCompositionValidator()
            let valid = (try? await built.isValid(
                for: composition,
                timeRange: CMTimeRange(start: .zero, duration: composition.duration),
                validationDelegate: validator
            )) ?? false
            if !valid {
                report("""
                    invalid video composition (\(validator.summary)) \
                    renderSize=\(Int(built.renderSize.width))x\(Int(built.renderSize.height))
                    """)
            }
            videoComposition = built
        }

        // Ordered from "exactly what was asked for" down to "something you can actually watch".
        // The point is that a failure shouldn't cost you the highlight: worst case you get an
        // uncropped clip and a note saying so, rather than an error and nothing.
        var strategies: [Strategy] = []
        if wantsCrop {
            strategies.append(Strategy(label: "HEVC + crop", preset: AVAssetExportPresetHEVCHighestQuality, appliesCrop: true))
            strategies.append(Strategy(label: "H.264 + crop", preset: AVAssetExportPresetHighestQuality, appliesCrop: true))
        } else if quality == .fullHD {
            strategies.append(Strategy(label: "1080p", preset: AVAssetExportPreset1920x1080, appliesCrop: false))
        }
        strategies.append(Strategy(label: "HEVC", preset: AVAssetExportPresetHEVCHighestQuality, appliesCrop: false))
        strategies.append(Strategy(label: "H.264", preset: AVAssetExportPresetHighestQuality, appliesCrop: false))
        strategies.append(Strategy(label: "passthrough", preset: AVAssetExportPresetPassthrough, appliesCrop: false))

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("highlight-\(highlight.id.uuidString).mov")

        var lastFailure = "unknown error"
        for strategy in strategies {
            try? FileManager.default.removeItem(at: outputURL)

            guard let session = AVAssetExportSession(asset: composition, presetName: strategy.preset) else {
                report("\(strategy.label): preset unavailable for this asset")
                lastFailure = "\(strategy.label): preset unavailable"
                continue
            }
            session.outputURL = outputURL
            session.outputFileType = .mov
            session.videoComposition = strategy.appliesCrop ? videoComposition : nil
            session.shouldOptimizeForNetworkUse = true

            let progressTask = progress.map { report -> Task<Void, Never> in
                let box = UncheckedBox(session)
                return Task {
                    while !Task.isCancelled {
                        report(box.value.progress)
                        try? await Task.sleep(for: .milliseconds(200))
                    }
                }
            }
            await session.export()
            progressTask?.cancel()

            if session.status == .completed {
                progress?(1.0)
                let renderSize = strategy.appliesCrop
                    ? (videoComposition?.renderSize ?? naturalSize)
                    : naturalSize
                report("""
                    exported via \(strategy.label): \(composition.duration.seconds)s \
                    at \(Int(renderSize.width))x\(Int(renderSize.height))
                    """)

                var identifier: String?
                if saveToPhotoLibrary {
                    identifier = try await saveToLibrary(outputURL)
                }
                return Output(
                    fileURL: outputURL,
                    assetIdentifier: identifier,
                    renderSize: renderSize,
                    strategyLabel: strategy.label,
                    croppedAsRequested: strategy.appliesCrop || !wantsCrop
                )
            }

            // "Operation Stopped" is AVFoundation's catch-all description for several unrelated
            // failures, so the domain and code are what actually identify the cause.
            let error = session.error as NSError?
            let detail = "\(error?.domain ?? "?") \(error?.code ?? 0): \(error?.localizedDescription ?? "unknown")"
            report("\(strategy.label) failed — \(detail)")
            if let underlying = error?.userInfo[NSUnderlyingErrorKey] {
                report("  underlying: \(underlying)")
            }
            lastFailure = detail
        }

        throw ExtractError.exportFailed(lastFailure)
    }

    /// Writes to both the unified log and stdout.
    ///
    /// `devicectl --console` only relays stdout, so `Logger` alone is invisible over a cable —
    /// which is exactly when you most want to read it.
    private nonisolated func report(_ message: String) {
        captureLog.error("\(message, privacy: .public)")
        print("[highlights] \(message)")
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
