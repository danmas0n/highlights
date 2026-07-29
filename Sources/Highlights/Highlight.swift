import AVFoundation
import Foundation

/// A marked moment. Created the instant the trigger fires; the footage it refers to is already
/// on disk by then, which is the whole point.
struct Highlight: Identifiable, Codable, Equatable {
    let id: UUID
    /// Which recording session's footage this refers to. Stopping and restarting capture starts
    /// a new session, and a highlight is only meaningful against the one it was marked in.
    let sessionID: UUID
    /// Trigger position on that session's timeline.
    let triggerSeconds: Double
    /// Wall-clock time, purely for display ("2:14 into the second half" is not something we know).
    let markedAt: Date

    var preRollSeconds: Double
    var postRollSeconds: Double

    /// Nil until the user has framed it; nil means "export the full frame".
    var cropPath: CropPath?
    var title: String
    var exportedAssetIdentifier: String?

    /// Trim handles, in seconds from the start of the capture window. `trimEnd` nil means "run to
    /// the end". Kept separate from pre/post-roll: those decide how much footage to pull off the
    /// recording, while these decide what to keep once you can see it.
    var trimStart: Double = 0
    var trimEnd: Double?

    init(
        id: UUID = UUID(),
        sessionID: UUID,
        triggerSeconds: Double,
        markedAt: Date = Date(),
        preRollSeconds: Double,
        postRollSeconds: Double,
        cropPath: CropPath? = nil,
        title: String = "",
        exportedAssetIdentifier: String? = nil
    ) {
        self.id = id
        self.sessionID = sessionID
        self.triggerSeconds = triggerSeconds
        self.markedAt = markedAt
        self.preRollSeconds = preRollSeconds
        self.postRollSeconds = postRollSeconds
        self.cropPath = cropPath
        self.title = title
        self.exportedAssetIdentifier = exportedAssetIdentifier
    }

    var isExported: Bool { exportedAssetIdentifier != nil }

    /// The span of capture timeline this highlight needs. Clamped at zero so a bookmark in the
    /// first few seconds of a session doesn't ask for negative time.
    var timeRange: CMTimeRange {
        let start = max(0, triggerSeconds - preRollSeconds)
        let end = triggerSeconds + postRollSeconds
        return CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 600),
            end: CMTime(seconds: end, preferredTimescale: 600)
        )
    }

    var durationSeconds: Double { timeRange.duration.seconds }

    /// The window actually exported, after the trim handles.
    var trimmedRange: CMTimeRange {
        let window = timeRange
        let start = window.start + CMTime(seconds: max(0, trimStart), preferredTimescale: 600)
        let end = trimEnd.map { window.start + CMTime(seconds: $0, preferredTimescale: 600) } ?? window.end
        guard end > start else { return window }
        return CMTimeRange(start: start, end: CMTimeMinimum(end, window.end))
    }

    var trimmedDurationSeconds: Double { trimmedRange.duration.seconds }
    var isTrimmed: Bool { trimStart > 0.05 || (trimEnd.map { $0 < durationSeconds - 0.05 } ?? false) }
}

/// Persisted list of marks for the current session.
///
/// Deliberately survives app relaunch: if the app is killed at halftime, the marks and their
/// protected footage are both still there.
@MainActor
@Observable
final class HighlightLibrary {
    private(set) var highlights: [Highlight] = []

    private let url = URL.applicationSupportDirectory.appendingPathComponent("highlights.json")

    init() { load() }

    func add(_ highlight: Highlight) {
        highlights.append(highlight)
        save()
    }

    func update(_ highlight: Highlight) {
        guard let index = highlights.firstIndex(where: { $0.id == highlight.id }) else { return }
        highlights[index] = highlight
        save()
    }

    func remove(_ highlight: Highlight) {
        highlights.removeAll { $0.id == highlight.id }
        save()
    }

    func removeAll() {
        highlights.removeAll()
        save()
    }

    /// Newest first — during a game the thing you just marked is the thing you want to see.
    var sorted: [Highlight] { highlights.sorted { $0.triggerSeconds > $1.triggerSeconds } }

    private func load() {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([Highlight].self, from: data)
        else { return }
        highlights = decoded
    }

    private func save() {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        guard let data = try? JSONEncoder().encode(highlights) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
