import AVFoundation
import Foundation

/// One fragmented-MP4 media segment on disk, plus where it sits on its session's timeline.
struct Segment: Identifiable, Sendable, Codable {
    let id: Int
    /// Filename only, relative to the session directory — the app container path changes on
    /// every reinstall, so absolute URLs must never be persisted.
    let filename: String
    /// Seconds from the start of the recording session that produced it.
    let startSeconds: Double
    let durationSeconds: Double
    /// Recorded at write time so the storage readout never has to stat every file on disk.
    let byteCount: Int64
    var isProtected: Bool = false

    var endSeconds: Double { startSeconds + durationSeconds }

    func overlaps(_ range: CMTimeRange) -> Bool {
        startSeconds < range.end.seconds && endSeconds > range.start.seconds
    }
}

/// One continuous recording. Stopping and restarting capture — at halftime, say — starts a new
/// one rather than extending the old.
struct RecordingSession: Identifiable, Sendable, Codable {
    let id: UUID
    var segments: [Segment] = []
    var hasInitializationSegment = false
    var nextIndex = 0

    var hasProtectedFootage: Bool { segments.contains(where: \.isProtected) }
}

/// Owns the on-disk segment store: a directory per recording session, each holding its own
/// initialization segment, media segments, and nothing else.
///
/// fMP4 rules force the per-session split. The initialization segment carries the track headers,
/// and every media segment is meaningless without *its own* session's copy. Restarting the writer
/// mints a new one, so a single shared directory would silently orphan everything recorded before
/// halftime. To hand a span of footage to AVFoundation we write `init + [media segments]` into
/// one file — that concatenation is a valid fMP4 and `AVURLAsset` reads it directly.
///
/// The manifest is persisted after every change. A phone that overheats and kills the app at
/// halftime must not take the first half's highlights with it.
actor SegmentStore {
    enum StoreError: Error, LocalizedError {
        case unknownSession
        case missingInitializationSegment
        case noSegmentsInRange

        var errorDescription: String? {
            switch self {
            case .unknownSession:
                "That recording is no longer on this phone."
            case .missingInitializationSegment:
                "This recording's header is missing, so the footage can't be read."
            case .noSegmentsInRange:
                "No footage was found for that moment."
            }
        }
    }

    private let root: URL
    private var sessions: [UUID: RecordingSession] = [:]
    private var activeSessionID: UUID?
    /// The active session's fMP4 initialization header, kept in memory so it can be prepended to
    /// every media segment as it's written.
    private var initializationData: Data?

    /// How much history to keep, within the active session, for segments nothing depends on.
    var retention: CMTime

    init(directory: URL, retention: CMTime) {
        self.root = directory
        self.retention = retention
    }

    // MARK: - Paths

    /// Versioned because the on-disk layout has changed shape: segments now carry their own
    /// initialization header. Bumping the filename retires anything written by an older build
    /// instead of leaving unplayable footage lying around claiming to be valid.
    private var manifestURL: URL { root.appendingPathComponent("manifest-v2.json") }
    private func directory(for id: UUID) -> URL {
        root.appendingPathComponent(id.uuidString, isDirectory: true)
    }
    private func initURL(for id: UUID) -> URL {
        directory(for: id).appendingPathComponent("init.mp4")
    }
    private func url(for segment: Segment, in id: UUID) -> URL {
        directory(for: id).appendingPathComponent(segment.filename)
    }

    // MARK: - Lifecycle

    /// Loads sessions left behind by previous runs. Call once at launch.
    func restore() {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let decoded: [RecordingSession] = (try? Data(contentsOf: manifestURL))
            .flatMap { try? JSONDecoder().decode([RecordingSession].self, from: $0) } ?? []

        for var session in decoded {
            // Trust the filesystem over the manifest — a segment whose file vanished is worse
            // than one we simply forget about.
            session.segments = session.segments.filter {
                FileManager.default.fileExists(atPath: url(for: $0, in: session.id).path)
            }
            session.hasInitializationSegment =
                FileManager.default.fileExists(atPath: initURL(for: session.id).path)
            guard session.hasInitializationSegment, !session.segments.isEmpty else {
                try? FileManager.default.removeItem(at: directory(for: session.id))
                continue
            }
            sessions[session.id] = session
        }

        // Anything on disk the manifest doesn't know about is unreadable by definition — which
        // includes everything left by a previous on-disk format.
        let known = Set(sessions.keys.map(\.uuidString))
        let onDisk = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        for entry in onDisk where entry != manifestURL.lastPathComponent && !known.contains(entry) {
            try? FileManager.default.removeItem(at: root.appendingPathComponent(entry))
        }

        persist()
        captureLog.info("restored \(self.sessions.count, privacy: .public) recording session(s)")
    }

    /// Starts a new recording session and returns its id. Sessions holding footage a highlight
    /// still needs are kept; the rest are deleted.
    @discardableResult
    func beginSession() throws -> UUID {
        reclaimFinishedSessions()

        let id = UUID()
        try FileManager.default.createDirectory(at: directory(for: id), withIntermediateDirectories: true)
        sessions[id] = RecordingSession(id: id)
        activeSessionID = id
        persist()
        captureLog.info("began session \(id.uuidString, privacy: .public)")
        return id
    }

    func endSession() {
        activeSessionID = nil
        reclaimFinishedSessions()
        persist()
    }

    /// Deletes every inactive session that nothing depends on any more.
    private func reclaimFinishedSessions() {
        for (id, session) in sessions where id != activeSessionID && !session.hasProtectedFootage {
            try? FileManager.default.removeItem(at: directory(for: id))
            sessions[id] = nil
            captureLog.info("reclaimed session \(id.uuidString, privacy: .public)")
        }
    }

    func setRetention(_ retention: CMTime) {
        self.retention = retention
        if let id = activeSessionID { pruneUnprotected(in: id) }
    }

    // MARK: - Ingest

    func storeInitializationSegment(_ data: Data) throws {
        guard let id = activeSessionID else { throw StoreError.unknownSession }
        initializationData = data
        try data.write(to: initURL(for: id), options: .atomic)
        sessions[id]?.hasInitializationSegment = true
        persist()
    }

    @discardableResult
    func appendSegment(_ data: Data, start: CMTime, duration: CMTime) throws -> Segment {
        guard let id = activeSessionID, var session = sessions[id] else {
            throw StoreError.unknownSession
        }

        guard let header = initializationData else { throw StoreError.missingInitializationSegment }

        let index = session.nextIndex
        session.nextIndex += 1
        let filename = String(format: "seg-%06d.mp4", index)

        // Prepend the initialization header so each segment is a standalone, playable
        // single-fragment fMP4. The header is around a kilobyte, and paying it per segment here
        // means opening a clip later is pure metadata instead of copying tens of megabytes.
        var payload = header
        payload.append(data)
        try payload.write(to: directory(for: id).appendingPathComponent(filename), options: .atomic)

        let segment = Segment(
            id: index,
            filename: filename,
            startSeconds: start.seconds,
            durationSeconds: duration.seconds,
            byteCount: Int64(payload.count)
        )
        session.segments.append(segment)
        sessions[id] = session

        pruneUnprotected(in: id)
        persist()
        return segment
    }

    // MARK: - Retention

    /// Drops unprotected segments that have fallen out of the retention window.
    ///
    /// Protected segments are skipped rather than stopping the sweep — a promoted region in the
    /// middle of history must not pin everything older than it.
    private func pruneUnprotected(in id: UUID) {
        guard var session = sessions[id], let newest = session.segments.last?.endSeconds else { return }
        let cutoff = newest - retention.seconds
        guard cutoff > 0 else { return }

        session.segments.removeAll { segment in
            guard !segment.isProtected, segment.endSeconds <= cutoff else { return false }
            try? FileManager.default.removeItem(at: url(for: segment, in: id))
            return true
        }
        sessions[id] = session
    }

    /// Pins every segment covering `range` so retention can't delete a bookmark's source footage.
    func protectRange(_ range: CMTimeRange, in id: UUID) {
        guard var session = sessions[id] else { return }
        var changed = false
        for index in session.segments.indices
        where session.segments[index].overlaps(range) && !session.segments[index].isProtected {
            session.segments[index].isProtected = true
            changed = true
        }
        guard changed else { return }
        sessions[id] = session
        persist()
    }

    /// Releases a protected range and reclaims the space. Call once a highlight is exported.
    func releaseRange(_ range: CMTimeRange, in id: UUID) {
        guard var session = sessions[id] else { return }
        for index in session.segments.indices where session.segments[index].overlaps(range) {
            session.segments[index].isProtected = false
        }
        sessions[id] = session
        pruneUnprotected(in: id)
        reclaimFinishedSessions()
        persist()
    }

    /// Drops everything, protected or not. Backs the "free up space" action.
    func purgeAll() {
        for id in sessions.keys { try? FileManager.default.removeItem(at: directory(for: id)) }
        sessions.removeAll()
        activeSessionID = nil
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(Array(sessions.values)) else { return }
        try? data.write(to: manifestURL, options: .atomic)
    }

    // MARK: - Reassembly

    /// Whether the *start* of the requested range is still on disk.
    ///
    /// Deliberately not a full-coverage check. The tail routinely isn't written yet — you tap,
    /// and the post-roll is still encoding — and refusing to open a clip for that reason would be
    /// maddening. A short tail is fine; a missing head is not, because the pre-roll is the point.
    func canSatisfy(_ range: CMTimeRange, in id: UUID) -> Bool {
        guard let session = sessions[id], session.hasInitializationSegment else { return false }
        guard let first = session.segments.first(where: { $0.overlaps(range) }) else { return false }
        return first.startSeconds <= range.start.seconds + 0.001
    }

    /// The footage covering a requested range, as a run of individually playable files.
    struct ReassembledClip {
        /// Ordered and contiguous. These are the stored segments themselves — each is already a
        /// standalone single-fragment fMP4 — so they are owned by the store and must not be
        /// deleted by the caller.
        let parts: [URL]
        /// Session-timeline position of the first frame of `parts[0]`.
        let startSeconds: Double
    }

    /// Returns the stored segments covering a range, in order.
    ///
    /// No copying: every segment already carries its own initialization header, written in at
    /// capture time. This used to duplicate tens of megabytes of 4K footage on every clip open,
    /// serialized on this actor behind the 15 MB segment writes happening during recording —
    /// which is why opening a clip could take seconds.
    func reassemble(range: CMTimeRange, in id: UUID) throws -> ReassembledClip {
        guard let session = sessions[id] else { throw StoreError.unknownSession }
        guard session.hasInitializationSegment else { throw StoreError.missingInitializationSegment }

        let covering = session.segments.filter { $0.overlaps(range) }.sorted { $0.id < $1.id }
        guard let first = covering.first else { throw StoreError.noSegmentsInRange }

        captureLog.info("""
            clip covers \(covering.count, privacy: .public) segments for \
            [\(range.start.seconds, privacy: .public)…\(range.end.seconds, privacy: .public)]s, \
            first at \(first.startSeconds, privacy: .public)s
            """)

        return ReassembledClip(
            parts: covering.map { url(for: $0, in: id) },
            startSeconds: first.startSeconds
        )
    }

    // MARK: - Introspection

    /// Summed from recorded sizes rather than the filesystem. Stat'ing every segment was real
    /// work happening on the same actor that services clip opening.
    func bytesOnDisk() -> Int64 {
        sessions.values.reduce(Int64(0)) { total, session in
            total + session.segments.reduce(Int64(0)) { $0 + $1.byteCount }
        }
    }

    /// Oldest point in the active session still recoverable — drives the "you can reach back
    /// this far" readout.
    func earliestAvailable() -> CMTime? {
        guard let id = activeSessionID, let first = sessions[id]?.segments.first else { return nil }
        return CMTime(seconds: first.startSeconds, preferredTimescale: 600)
    }
}
