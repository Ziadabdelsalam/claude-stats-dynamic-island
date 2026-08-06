import Foundation

/// Health/telemetry counters produced while parsing one or more transcript
/// files. `duplicatesDropped` is the per-file `message.id` dedup count (D2);
/// cross-file dedup (`crossFileDuplicatesDropped`) is a separate counter that
/// only `Aggregator` produces — this task never sees more than one file's
/// worth of duplicates at a time.
public struct ParseCounters: Sendable {
    public var filesScanned: Int
    public var linesRead: Int
    public var eventsKept: Int
    public var duplicatesDropped: Int
    public var malformedLines: Int
    /// Files `parseAll` could not open or read to completion — dangling
    /// symlinks, vanished files, permission failures — and therefore skipped
    /// instead of aborting the whole run (D10: "IO errors skip the file").
    public var unreadableFiles: Int

    public init(
        filesScanned: Int = 0,
        linesRead: Int = 0,
        eventsKept: Int = 0,
        duplicatesDropped: Int = 0,
        malformedLines: Int = 0,
        unreadableFiles: Int = 0
    ) {
        self.filesScanned = filesScanned
        self.linesRead = linesRead
        self.eventsKept = eventsKept
        self.duplicatesDropped = duplicatesDropped
        self.malformedLines = malformedLines
        self.unreadableFiles = unreadableFiles
    }

    public static func + (l: Self, r: Self) -> Self {
        ParseCounters(
            filesScanned: l.filesScanned + r.filesScanned,
            linesRead: l.linesRead + r.linesRead,
            eventsKept: l.eventsKept + r.eventsKept,
            duplicatesDropped: l.duplicatesDropped + r.duplicatesDropped,
            malformedLines: l.malformedLines + r.malformedLines,
            unreadableFiles: l.unreadableFiles + r.unreadableFiles
        )
    }

    public static func += (l: inout Self, r: Self) {
        l = l + r
    }
}

/// The result of parsing a single file (possibly from a nonzero starting
/// offset for incremental re-reads — see `TranscriptParser.parseFile`).
public struct FileParseResult: Sendable {
    public var events: [UsageEvent]
    public var counters: ParseCounters
    public var endOffset: UInt64

    public init(events: [UsageEvent], counters: ParseCounters, endOffset: UInt64) {
        self.events = events
        self.counters = counters
        self.endOffset = endOffset
    }
}

/// Streams `~/.claude/projects/<encoded-cwd>/<sessionId>.jsonl` transcripts
/// and turns `assistant` lines that carry real usage into `UsageEvent`s.
///
/// Per D2, dedup here is scoped to a single file, keyed on `message.id`
/// alone (`requestId` is nullable in real data and must never be the key).
/// Global, cross-file dedup is explicitly `Aggregator`'s job (T4), not this
/// type's.
public struct TranscriptParser: Sendable {
    public let root: URL

    public init(root: URL = TranscriptParser.defaultRoot) {
        self.root = root
    }

    public static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)
    }

    /// Enumerates `**/*.jsonl` recursively under `root` (D2a — real transcripts
    /// live at depth 4-6, e.g. `<encoded-dir>/<sessionId>/subagents/agent-*.jsonl`
    /// and `wf_*` dirs, not just one level down) and parses every file
    /// concurrently (bounded per D3), each from offset 0. Only per-file dedup
    /// is applied; duplicate `message.id`s across different files are left
    /// untouched for `Aggregator.rollup` to resolve.
    ///
    /// A file `parseFile` cannot open or finish reading (dangling symlink,
    /// vanished mid-read, permission failure) never aborts the run: that
    /// single file's events are dropped and it's counted in
    /// `ParseCounters.unreadableFiles` instead (D10: "IO errors skip the
    /// file", matching `UsageStore`'s per-file-failure tolerance). `parseFile`
    /// itself is unaffected and keeps throwing — this tolerance is `parseAll`
    /// only, since T5's incremental path relies on per-file errors surfacing.
    public func parseAll() async throws -> (events: [UsageEvent], counters: ParseCounters) {
        let files = Self.enumerateTranscriptFiles(under: root)
        let maxConcurrency = max(1, min(8, ProcessInfo.processInfo.activeProcessorCount))

        var allEvents: [UsageEvent] = []
        var totalCounters = ParseCounters()

        await withTaskGroup(of: FileParseResult.self) { group in
            var iterator = files.makeIterator()
            var inFlight = 0

            func submitNext() {
                guard let url = iterator.next() else { return }
                inFlight += 1
                group.addTask {
                    do {
                        return try self.parseFile(at: url, from: 0)
                    } catch {
                        return FileParseResult(
                            events: [],
                            counters: ParseCounters(filesScanned: 1, unreadableFiles: 1),
                            endOffset: 0
                        )
                    }
                }
            }

            for _ in 0..<maxConcurrency {
                submitNext()
            }

            while inFlight > 0 {
                let result = await group.next()
                inFlight -= 1
                if let result {
                    allEvents.append(contentsOf: result.events)
                    totalCounters += result.counters
                }
                submitNext()
            }
        }

        return (allEvents, totalCounters)
    }

    /// Streams `url` line-by-line off a `FileHandle` starting at `offset`,
    /// never loading the whole file into memory. Applies the byte-prefilter
    /// (only lines whose raw bytes contain `"type":"assistant"` are decoded)
    /// and per-file `message.id` dedup.
    ///
    /// `endOffset` is the byte position after the last *complete*,
    /// newline-terminated line consumed. Claude Code appends to these files
    /// live, so a read can catch a half-written trailing line; that line is
    /// never parsed and `endOffset` never advances past it, so its tokens
    /// are picked up whole on the next incremental read.
    ///
    /// Throws (and returns nothing) if `url` can't be opened, or if it
    /// vanishes/becomes unreadable partway through — this function's result
    /// is all-or-nothing, so a mid-read failure drops everything parsed from
    /// this file so far rather than returning a partial result; `parseAll`
    /// is where that's made tolerable (counted, not fatal). T5's incremental
    /// path relies on this throwing behavior, so it's unchanged here.
    public func parseFile(at url: URL, from offset: UInt64) throws -> FileParseResult {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)

        var counters = ParseCounters(filesScanned: 1)
        var pendingEvents: [PendingEvent] = []
        var seenMessageIDs = Set<String>()
        // D2b: round-trip-validated `cwd` basenames seen anywhere in this
        // file, tallied so the winning display name can be resolved once the
        // whole file has been read (most-frequent, tie-break lexicographic).
        var cwdCandidateCounts: [String: Int] = [:]

        let projectKey = projectKey(for: url)

        var buffer = Data()
        var consumedOffset = offset
        var endOffset = offset
        let chunkSize = 1 << 20 // 1 MB

        // `read(upToCount:)` (not the older, NSException-raising
        // `readData(ofLength:)`) so a file that vanishes mid-read throws a
        // catchable Swift error instead of crashing the process.
        while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
            buffer.append(chunk)

            while let newlineIndex = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer[buffer.startIndex..<newlineIndex]
                let consumedLength = buffer.distance(from: buffer.startIndex, to: newlineIndex) + 1
                buffer.removeSubrange(buffer.startIndex...newlineIndex)

                consumedOffset += UInt64(consumedLength)
                endOffset = consumedOffset
                counters.linesRead += 1

                Self.process(
                    lineData: lineData,
                    projectKey: projectKey,
                    seenMessageIDs: &seenMessageIDs,
                    cwdCandidateCounts: &cwdCandidateCounts,
                    pendingEvents: &pendingEvents,
                    counters: &counters
                )
            }
        }
        // Any bytes left in `buffer` are a trailing line with no terminating
        // newline — a partially-written line mid-append. It is intentionally
        // dropped, and `endOffset` stays at the end of the last complete line.

        let displayName = Self.resolveDisplayName(candidates: cwdCandidateCounts, projectKey: projectKey)
        let events = pendingEvents.map { pending in
            UsageEvent(
                timestamp: pending.timestamp,
                sessionId: pending.sessionId,
                projectKey: projectKey,
                projectDisplayName: displayName,
                model: pending.model,
                tokens: pending.tokens,
                messageId: pending.messageId,
                requestId: pending.requestId
            )
        }

        return FileParseResult(events: events, counters: counters, endOffset: endOffset)
    }

    /// D2a: `projectKey` is the first path component under `root`, regardless
    /// of how deeply the file itself is nested (subagent transcripts live at
    /// `<encoded-dir>/<sessionId>/subagents/agent-*.jsonl`). Falls back to the
    /// file's immediate parent directory name for URLs that aren't actually
    /// under `root` (e.g. ad-hoc files handed to `parseFile` directly).
    private func projectKey(for url: URL) -> String {
        let rootComponents = root.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let urlComponents = url.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        if urlComponents.count > rootComponents.count,
           Array(urlComponents.prefix(rootComponents.count)) == rootComponents {
            return urlComponents[rootComponents.count]
        }
        return url.deletingLastPathComponent().lastPathComponent
    }

    // MARK: - Line processing

    /// A kept event's fields except `projectDisplayName`, which is only
    /// known once the whole file has been scanned (D2b).
    private struct PendingEvent {
        let timestamp: Date
        let sessionId: String
        let model: String
        let tokens: TokenCounts
        let messageId: String
        let requestId: String?
    }

    private static let assistantMarker = Data("\"type\":\"assistant\"".utf8)

    private static func process(
        lineData: Data,
        projectKey: String,
        seenMessageIDs: inout Set<String>,
        cwdCandidateCounts: inout [String: Int],
        pendingEvents: inout [PendingEvent],
        counters: inout ParseCounters
    ) {
        // Byte-prefilter (D3): skip decoding entirely for lines that cannot
        // possibly be an assistant line.
        guard lineData.range(of: assistantMarker) != nil else { return }

        guard let raw = try? decoder.decode(RawLine.self, from: lineData) else {
            counters.malformedLines += 1
            return
        }
        guard raw.type == "assistant" else { return }

        // D2b: collect this line's own `cwd` (or the longest ancestor of it
        // that round-trips) as a display-name candidate, even if the line
        // itself turns out to carry no billable usage.
        if let cwd = raw.cwd, !cwd.isEmpty,
           let basename = validatedBasename(forCwd: cwd, encodedDirectoryName: projectKey) {
            cwdCandidateCounts[basename, default: 0] += 1
        }

        guard let message = raw.message, let usage = message.usage else { return }
        // `<synthetic>` lines do carry a usage object (environment fact) —
        // filter on the model id, never on usage presence.
        guard let model = message.model, model != "<synthetic>" else { return }
        guard let messageId = message.id else {
            counters.malformedLines += 1
            return
        }
        guard let sessionId = raw.sessionId else {
            counters.malformedLines += 1
            return
        }
        guard let timestampString = raw.timestamp, let timestamp = parseTimestamp(timestampString) else {
            counters.malformedLines += 1
            return
        }

        // D2: dedup on `message.id` alone. `requestId` is nullable in real
        // data and never used as (or as part of) the key.
        if seenMessageIDs.contains(messageId) {
            counters.duplicatesDropped += 1
            return
        }
        seenMessageIDs.insert(messageId)

        pendingEvents.append(PendingEvent(
            timestamp: timestamp,
            sessionId: sessionId,
            model: model,
            tokens: tokenCounts(from: usage),
            messageId: messageId,
            requestId: raw.requestId
        ))
        counters.eventsKept += 1
    }

    // MARK: - Decoding helpers

    private static let decoder = JSONDecoder()

    // `ISO8601DateFormatter` is a class with genuinely mutable internal state
    // and is not `Sendable`, so it cannot live in `static let` storage on a
    // `Sendable` type. `Date.ISO8601FormatStyle` is a value-type equivalent
    // (Sendable by construction) with no shared mutable state, so it is safe
    // as global immutable constants here.
    private static let isoStrategyWithFractionalSeconds = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let isoStrategy = Date.ISO8601FormatStyle(includingFractionalSeconds: false)

    private static func parseTimestamp(_ string: String) -> Date? {
        (try? Date(string, strategy: isoStrategyWithFractionalSeconds))
            ?? (try? Date(string, strategy: isoStrategy))
    }

    /// D5 usage mapping: `cache_creation.ephemeral_5m_input_tokens` ->
    /// `cacheWrite5m`, `ephemeral_1h_...` -> `cacheWrite1h`. If the
    /// `cache_creation` object is absent, `cache_creation_input_tokens`
    /// (the flat legacy field) becomes `cacheWrite5m` and `cacheWrite1h` is 0.
    private static func tokenCounts(from usage: RawLine.Message.Usage) -> TokenCounts {
        let input = usage.inputTokens ?? 0
        let output = usage.outputTokens ?? 0
        let cacheRead = usage.cacheReadInputTokens ?? 0

        let cacheWrite5m: Int
        let cacheWrite1h: Int
        if let cacheCreation = usage.cacheCreation {
            cacheWrite5m = cacheCreation.ephemeral5mInputTokens ?? 0
            cacheWrite1h = cacheCreation.ephemeral1hInputTokens ?? 0
        } else {
            cacheWrite5m = usage.cacheCreationInputTokens ?? 0
            cacheWrite1h = 0
        }

        return TokenCounts(
            input: input,
            output: output,
            cacheWrite5m: cacheWrite5m,
            cacheWrite1h: cacheWrite1h,
            cacheRead: cacheRead
        )
    }

    /// D2b round-trip rule (E12 amendment): a `cwd` value is only trustworthy
    /// as a display name source if re-encoding the *whole* string — every
    /// `/`, `.` and space replaced with `-` — reproduces the file's own
    /// encoded directory name, **case-insensitively** (fixes lines like
    /// `/volumes/ssd/workspace/...`). This is a forward, unambiguous check
    /// (no guessing at how to invert the encoding): e.g.
    /// `/Users/z/.claude-mem/observer-sessions` re-encodes to
    /// `-Users-z--claude-mem-observer-sessions`.
    ///
    /// The space belongs in the class because Claude Code demonstrably encodes
    /// it: the real transcript directory `-Volumes-SSD-Workspace-my-website`
    /// holds lines whose `cwd` is `/Volumes/SSD/Workspace/my website`, and no
    /// space-named sibling directory exists. Measured over the whole corpus,
    /// adding the space changes the outcome of exactly two (directory, cwd)
    /// pairs — both in that directory, both to the correct name — and leaves
    /// every other pair, accepted or rejected, unchanged.
    private static func roundTrips(cwd: String, encodedDirectoryName: String) -> Bool {
        let reencoded = String(cwd.map { $0 == "/" || $0 == "." || $0 == " " ? "-" : $0 })
        return reencoded.compare(encodedDirectoryName, options: .caseInsensitive) == .orderedSame
    }

    /// E12 amendment: a full `cwd` doesn't always round-trip on its own (the
    /// transcript line can be for a subdirectory of the actual project root,
    /// e.g. `/Volumes/SSD/Workspace/ideas/stitchlist` under encoded dir
    /// `-Volumes-SSD-Workspace-ideas`). Walk `cwd`'s ancestors from most to
    /// least specific and accept the *longest* one that round-trips — still
    /// an exact (case-insensitive) validation, never a guessed suffix decode.
    /// The returned basename keeps `cwd`'s own casing, not the directory's.
    private static func validatedBasename(forCwd cwd: String, encodedDirectoryName: String) -> String? {
        var candidate = cwd
        while true {
            if roundTrips(cwd: candidate, encodedDirectoryName: encodedDirectoryName) {
                let basename = URL(fileURLWithPath: candidate).lastPathComponent
                return basename.isEmpty ? nil : basename
            }
            let parent = URL(fileURLWithPath: candidate).deletingLastPathComponent().path
            if parent == candidate {
                return nil
            }
            candidate = parent
        }
    }

    /// Resolves the single display name to use for every event in a file:
    /// the most frequent round-trip-validated `cwd` basename (tie-break
    /// lexicographically smallest), or — if none round-tripped — the encoded
    /// directory name with only its leading `-` stripped, verbatim. Never a
    /// guessed suffix decode.
    private static func resolveDisplayName(candidates: [String: Int], projectKey: String) -> String {
        if let maxCount = candidates.values.max() {
            let winners = candidates.filter { $0.value == maxCount }.keys
            if let winner = winners.sorted().first {
                return winner
            }
        }
        var trimmed = projectKey
        if trimmed.hasPrefix("-") {
            trimmed.removeFirst()
        }
        return trimmed
    }

    // MARK: - File enumeration

    /// Recursive per D2a: transcripts live at depth 4-6 under `root`
    /// (`<encoded-dir>/<sessionId>/subagents/agent-*.jsonl`, `wf_*` dirs,
    /// etc.), not just one level down.
    static func enumerateTranscriptFiles(under root: URL) -> [URL] {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var files: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            files.append(url)
        }
        return files
    }
}

// MARK: - Raw JSON line shape

/// Minimal mirror of the on-disk assistant-line shape (see environment facts
/// in the team plan) — only the fields this parser actually needs.
private struct RawLine: Decodable {
    struct Message: Decodable {
        struct Usage: Decodable {
            struct CacheCreation: Decodable {
                let ephemeral5mInputTokens: Int?
                let ephemeral1hInputTokens: Int?

                enum CodingKeys: String, CodingKey {
                    case ephemeral5mInputTokens = "ephemeral_5m_input_tokens"
                    case ephemeral1hInputTokens = "ephemeral_1h_input_tokens"
                }
            }

            let inputTokens: Int?
            let outputTokens: Int?
            let cacheCreationInputTokens: Int?
            let cacheReadInputTokens: Int?
            let cacheCreation: CacheCreation?

            enum CodingKeys: String, CodingKey {
                case inputTokens = "input_tokens"
                case outputTokens = "output_tokens"
                case cacheCreationInputTokens = "cache_creation_input_tokens"
                case cacheReadInputTokens = "cache_read_input_tokens"
                case cacheCreation = "cache_creation"
            }
        }

        let id: String?
        let model: String?
        let usage: Usage?
    }

    let type: String?
    let timestamp: String?
    let sessionId: String?
    let cwd: String?
    let requestId: String?
    let message: Message?
}
