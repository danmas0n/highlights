import SwiftUI

@main
struct HighlightsApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .preferredColorScheme(.dark)
                .statusBarHidden()
        }
    }
}

/// Single owner of the capture engine, the mark library, and the extractor, so a highlight
/// marked on the capture screen and edited in the library refer to the same segment store.
@MainActor
@Observable
final class AppModel {
    var settings: CaptureSettings {
        didSet {
            settings.save()
            triggers.setVolumeTriggerEnabled(settings.volumeButtonTriggerEnabled)
            Task { await engine.store.setRetention(settings.retention) }
        }
    }

    let engine: CaptureEngine
    let library = HighlightLibrary()
    let triggers = TriggerCoordinator()
    let extractor: HighlightExtractor

    init() {
        let settings = CaptureSettings.load()
        self.settings = settings
        let engine = CaptureEngine(settings: settings)
        self.engine = engine
        self.extractor = HighlightExtractor(store: engine.store)
        triggers.setVolumeTriggerEnabled(settings.volumeButtonTriggerEnabled)
    }

    /// Marks the current moment. Everything before the tap is already on disk.
    /// Returns nil if we aren't recording, so the UI can decline rather than create a dead mark.
    @discardableResult
    func mark() -> Highlight? {
        guard engine.state == .recording, let sessionID = engine.activeSessionID else { return nil }

        let highlight = Highlight(
            sessionID: sessionID,
            triggerSeconds: engine.elapsed.seconds,
            preRollSeconds: settings.preRollSeconds,
            postRollSeconds: settings.postRollSeconds
        )
        library.add(highlight)

        // Pin the pre-roll immediately, then keep re-pinning while the post-roll encodes.
        //
        // A single deferred pass isn't enough: the segments covering the seconds *after* the tap
        // don't exist yet at mark time, and they only land as the writer closes each segment. We
        // re-pin once a second until the whole window has had time to be written — one segment
        // interval past the post-roll — so the tail can't be pruned before it's claimed.
        // `protectRange` is a no-op when nothing changed, so the repeats are nearly free.
        let deadline = settings.postRollSeconds + settings.segmentSeconds + 1
        Task {
            var elapsed = 0.0
            while elapsed <= deadline {
                await engine.store.protectRange(highlight.timeRange, in: sessionID)
                try? await Task.sleep(for: .seconds(1))
                elapsed += 1
            }
        }
        return highlight
    }

    /// Frees a highlight's footage — only if the user has asked for that.
    ///
    /// Exporting used to release automatically, which meant saving to Photos silently destroyed
    /// the local copy. That's the wrong default: the exported file is cropped and flattened, so
    /// the retained footage is the only route back to the full 4K frame if you want to reframe
    /// the same moment later.
    func releaseFootageIfConfigured(for highlight: Highlight) async {
        guard !settings.keepFootageAfterExport else { return }
        await engine.store.releaseRange(highlight.timeRange, in: highlight.sessionID)
    }

    /// Deletes a highlight and frees its footage. The explicit way to reclaim space.
    func delete(_ highlight: Highlight) async {
        library.remove(highlight)
        await engine.store.releaseRange(highlight.timeRange, in: highlight.sessionID)
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        CaptureView()
    }
}
