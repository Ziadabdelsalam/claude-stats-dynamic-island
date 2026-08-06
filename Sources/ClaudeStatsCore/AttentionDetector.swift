import Foundation

/// A session parked on a waiting-set `tool_use` (D10 in the team plan) —
/// `AskUserQuestion` or `ExitPlanMode` — detected from the tail of one
/// transcript file.
public struct AttentionState: Sendable, Equatable, Identifiable {
    public var projectKey: String
    public var sessionId: String
    public var filePath: String
    public var toolName: String
    /// First question's header/text, truncated to 80 chars; the literal
    /// `"Plan ready for review"` for `ExitPlanMode`.
    public var prompt: String?
    public var since: Date
    /// The waiting `tool_use`'s id.
    public var id: String
}

/// Detects sessions waiting on user input by reading only the tail of each
/// transcript file — never a full re-parse (D10).
///
/// The waiting set is deliberately narrow. Live re-verification against the
/// real corpus (T11) confirmed the advisor's probe: ordinary tools (Bash,
/// Edit, ...) leave an identical "dangling `tool_use`" shape on disk while
/// merely *executing*, and a pre-approval permission prompt is
/// indistinguishable from that — `tool_use` content blocks only ever carry
/// `type`/`id`/`name`/`input`/`caller`, no approval-state field, across a
/// sample spanning every tool name seen in the corpus (`Bash`, `Edit`,
/// `WebFetch`, MCP tools, ...). So permission prompts stay excluded from
/// the waiting set: undetectable folds to "no nudge", never a guess.
public struct AttentionDetector: Sendable {
    public let root: URL
    public let waitingToolNames: Set<String>
    public let staleAfterMinutes: Int
    public let tailBytes: Int
    /// Minimum seconds a file must have been quiet (mtime age) before a
    /// finished turn is reported — see `turnCompletedToolName`.
    public let turnQuietSeconds: Int
    /// Staleness window for `turnCompletedToolName` only — much shorter
    /// than `staleAfterMinutes`: "Claude finished" is ambient status, not a
    /// question; camping on the notch for 30 minutes would keep the
    /// character parked near-permanently (some session has always just
    /// finished) and starve the idle roam entirely.
    public let turnStaleAfterMinutes: Int
    /// Project keys containing any of these substrings never report
    /// `turnCompletedToolName` (waiting tools are unaffected). Live-corpus
    /// probe: `claude-mem`'s background observer sessions complete a turn
    /// after every real session ends and are never "responded to" — without
    /// this they keep the finished-turn nudge lit near-permanently.
    public let turnIgnoredProjectKeySubstrings: [String]

    /// The `toolName` carried by a "turn completed" attention state: the
    /// session's tail ends with a plain assistant text message (no
    /// `tool_use` at all), meaning Claude finished its turn and is waiting
    /// for the user. Cleared by any subsequent `user` line (the user came
    /// back and responded) or by the staleness window — a transcript
    /// records no "the user looked at this" signal, so responding is the
    /// nearest observable proxy.
    ///
    /// Two false-positive guards, both live-verified shapes:
    ///  - A dangling *ordinary* `tool_use` (Bash, Edit, ...) still means
    ///    "running or at a permission prompt" (T11) — never a finish.
    ///  - Mid-turn text (assistant prose written moments before its next
    ///    tool call lands) is filtered by `turnQuietSeconds`: the file
    ///    must have been quiet for that long before the finish counts.
    ///  - Sidechain (subagent) transcripts finish constantly mid-task;
    ///    any `isSidechain` line in the tail suppresses the finish signal
    ///    for that file.
    public static let turnCompletedToolName = "TurnCompleted"

    public init(
        root: URL = TranscriptParser.defaultRoot,
        waitingToolNames: Set<String> = ["AskUserQuestion", "ExitPlanMode"],
        staleAfterMinutes: Int = 30,
        tailBytes: Int = 262_144,
        turnQuietSeconds: Int = 10,
        turnStaleAfterMinutes: Int = 5,
        turnIgnoredProjectKeySubstrings: [String] = ["claude-mem"]
    ) {
        self.root = root
        self.waitingToolNames = waitingToolNames
        self.staleAfterMinutes = staleAfterMinutes
        self.tailBytes = tailBytes
        self.turnQuietSeconds = turnQuietSeconds
        self.turnStaleAfterMinutes = turnStaleAfterMinutes
        self.turnIgnoredProjectKeySubstrings = turnIgnoredProjectKeySubstrings
    }

    /// Every still-waiting `tool_use`, most recent (`since`) first.
    ///
    /// A `tool_use` in `waitingToolNames` is pending iff, scanning forward
    /// from it to the end of the file's tail:
    ///  (a) no `tool_result` matching its `tool_use_id` appears, and
    ///  (b) no subsequent `user` or `assistant` line appears at all —
    ///      `system`/`attachment`/`ai-title`/etc. lines do NOT cancel it,
    ///      and (E19) an `assistant` line whose `message.id` equals the
    ///      candidate's own `message.id` does NOT cancel it either: that is
    ///      a parallel same-turn sibling tool call (or an in-file duplicate
    ///      of the very same line, T3), not subsequent progress. Measured
    ///      on the real corpus: 1,845 same-`message.id` parallel-call
    ///      occurrences — the pre-E19 rule was a false-negative class.
    /// (b) is strictly stronger than (a): on the real corpus a matching
    /// `tool_result` is *always* carried on a `user`-role line (verified —
    /// see T11's notes), so any subsequent `user` line, or any subsequent
    /// `assistant` line from a genuinely later turn, is enough to
    /// disqualify a candidate. Also applies (c) a staleness cutoff on the
    /// `tool_use`'s own timestamp, plus an mtime pre-filter that skips
    /// (never opens) files already older than the staleness window.
    ///
    /// I/O or decode failures on a given file are swallowed — an unreadable
    /// or malformed file produces no nudge, not a guess. Mirrored files
    /// (the same session written under two project dirs) are deduped by
    /// `tool_use` id, keeping the lexicographically smallest `projectKey`.
    public func pendingAttention(now: Date) -> [AttentionState] {
        let staleWindow = TimeInterval(staleAfterMinutes * 60)
        var winners: [String: AttentionState] = [:] // tool_use id -> winning state

        for url in TranscriptParser.enumerateTranscriptFiles(under: root) {
            guard let mtime = Self.modificationDate(atPath: url.path) else { continue }
            guard now.timeIntervalSince(mtime) <= staleWindow else { continue }

            let projectKey = Self.projectKey(for: url, root: root)
            for state in Self.scanTail(of: url, tailBytes: tailBytes, waitingToolNames: waitingToolNames, projectKey: projectKey) {
                guard now.timeIntervalSince(state.since) <= staleWindow else { continue }
                // Turn-completed only counts once the file has settled: a
                // fresh mtime means Claude may still be mid-turn, about to
                // append its next tool call.
                if state.toolName == Self.turnCompletedToolName {
                    if now.timeIntervalSince(mtime) < TimeInterval(turnQuietSeconds) {
                        continue
                    }
                    if now.timeIntervalSince(state.since) > TimeInterval(turnStaleAfterMinutes * 60) {
                        continue
                    }
                    if turnIgnoredProjectKeySubstrings.contains(where: { state.projectKey.contains($0) }) {
                        continue
                    }
                }
                if let existing = winners[state.id] {
                    if state.projectKey < existing.projectKey {
                        winners[state.id] = state
                    }
                } else {
                    winners[state.id] = state
                }
            }
        }

        // `since` desc; ties broken by `tool_use` id so the order is stable
        // across runs (dictionary iteration order and `sorted` are both
        // unordered/unstable) — consumers diff this array.
        return winners.values.sorted { $0.since == $1.since ? $0.id < $1.id : $0.since > $1.since }
    }

    // MARK: - Current task (latest user prompt)

    /// The most recent genuine user prompt per project — "what is this
    /// project's newest session working on right now". Same enumeration,
    /// staleness pre-filter and tail discipline as `pendingAttention`.
    ///
    /// "Genuine" excludes, all live-verified shapes: sidechain (subagent)
    /// files, whose `user` lines are agent briefs rather than the user;
    /// `tool_result` carrier lines (block content with no `text` block);
    /// and slash-command/caveat meta lines (`<command-name>...`,
    /// `Caveat: ...`) plus interruption stubs.
    public func latestUserPrompts(now: Date) -> [String: String] {
        let staleWindow = TimeInterval(staleAfterMinutes * 60)
        var best: [String: (since: Date, text: String)] = [:]

        for url in TranscriptParser.enumerateTranscriptFiles(under: root) {
            guard let mtime = Self.modificationDate(atPath: url.path) else { continue }
            guard now.timeIntervalSince(mtime) <= staleWindow else { continue }

            let projectKey = Self.projectKey(for: url, root: root)
            guard let found = Self.scanTailForUserPrompt(of: url, tailBytes: tailBytes) else { continue }
            guard now.timeIntervalSince(found.since) <= staleWindow else { continue }
            if let existing = best[projectKey], existing.since >= found.since { continue }
            best[projectKey] = found
        }
        return best.mapValues(\.text)
    }

    private static func scanTailForUserPrompt(of url: URL, tailBytes: Int) -> (since: Date, text: String)? {
        var latest: (since: Date, text: String)?
        for lineData in tailLines(of: url, tailBytes: tailBytes) {
            guard !lineData.isEmpty, let parsed = try? decoder.decode(TailLine.self, from: lineData) else {
                continue
            }
            if parsed.isSidechain == true { return nil }
            guard parsed.type == "user",
                  let timestampString = parsed.timestamp,
                  let since = parseTimestamp(timestampString),
                  let snippet = parsed.message?.content?.textSnippet
            else { continue }
            if snippet.hasPrefix("<") || snippet.hasPrefix("Caveat:") || snippet.hasPrefix("[Request interrupted") {
                continue
            }
            latest = (since, snippet)
        }
        return latest
    }

    // MARK: - projectKey

    // D2a: first path component under root. Duplicated from
    // `TranscriptParser`'s private `projectKey(for:)` rather than exposed
    // as shared internal API — this detector reads only a file's tail and
    // must stay independently correct without any dependency on
    // `TranscriptParser`'s own parsing state. The advisor ruled this small
    // duplication permanent.
    private static func projectKey(for url: URL, root: URL) -> String {
        let rootComponents = root.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let urlComponents = url.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        if urlComponents.count > rootComponents.count,
           Array(urlComponents.prefix(rootComponents.count)) == rootComponents {
            return urlComponents[rootComponents.count]
        }
        return url.deletingLastPathComponent().lastPathComponent
    }

    // MARK: - mtime pre-filter

    /// A single `stat(2)` call, matching `TranscriptWatcher`'s convention
    /// (E14) — cheaper than `FileManager.attributesOfItem` for a value this
    /// method only ever reads once.
    private static func modificationDate(atPath path: String) -> Date? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        let seconds = TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000
        return Date(timeIntervalSince1970: seconds)
    }

    // MARK: - Tail scan

    /// Reads the tail window of `url` and splits it into complete lines —
    /// the shared front half of every tail scanner here. Tail discipline
    /// (D7/D10): if the window starts mid-file, the bytes before the first
    /// newline are a fragment of a line that began before the window —
    /// discarded rather than guessed at; a partial trailing line (Claude
    /// Code mid-append) is likewise not parsed, same as `parseFile`.
    private static func tailLines(of url: URL, tailBytes: Int) -> [Data] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }

        guard let fileSize = try? handle.seekToEnd() else { return [] }
        let startOffset = fileSize > UInt64(tailBytes) ? fileSize - UInt64(tailBytes) : 0
        guard (try? handle.seek(toOffset: startOffset)) != nil else { return [] }
        var data = (try? handle.readToEnd()) ?? Data()

        if startOffset > 0 {
            if let newlineIndex = data.firstIndex(of: 0x0A) {
                data.removeSubrange(data.startIndex...newlineIndex)
            } else {
                data.removeAll()
            }
        }

        var lines: [Data] = []
        var remaining = data
        while let newlineIndex = remaining.firstIndex(of: 0x0A) {
            lines.append(Data(remaining[remaining.startIndex..<newlineIndex]))
            remaining.removeSubrange(remaining.startIndex...newlineIndex)
        }
        return lines
    }

    private static func scanTail(
        of url: URL,
        tailBytes: Int,
        waitingToolNames: Set<String>,
        projectKey: String
    ) -> [AttentionState] {
        let lines = tailLines(of: url, tailBytes: tailBytes)

        var open: [String: (name: String, prompt: String?, since: Date, messageId: String?)] = [:]
        var sessionId = ""
        // The finished-turn candidate: the tail's last conversational line,
        // iff it's an assistant line carrying no `tool_use` at all.
        var lastTurn: (since: Date, messageId: String?, snippet: String?, hasToolUse: Bool)?
        var sawSidechain = false

        for lineData in lines {
            guard !lineData.isEmpty, let parsed = try? decoder.decode(TailLine.self, from: lineData) else {
                continue // malformed tail line: skip, never crash
            }
            if let sid = parsed.sessionId {
                sessionId = sid
            }
            if parsed.isSidechain == true {
                sawSidechain = true
            }

            switch parsed.type {
            case "assistant":
                let lineMessageId = parsed.message?.id
                // D10 (b) + E19: a subsequent assistant line cancels
                // whatever was open, UNLESS it shares this line's own
                // `message.id` — a parallel same-turn sibling tool call (or
                // an in-file duplicate of the same line, T3) is not
                // subsequent progress.
                open = open.filter { $0.value.messageId != nil && $0.value.messageId == lineMessageId }
                guard let timestampString = parsed.timestamp, let since = parseTimestamp(timestampString) else { continue }
                let content = parsed.message?.content
                let hasToolUse = content?.blocks.contains { $0.type == "tool_use" } ?? false
                lastTurn = (since, lineMessageId, content?.textSnippet, hasToolUse)
                for block in content?.blocks ?? [] where block.type == "tool_use" {
                    guard let name = block.name, waitingToolNames.contains(name), let toolID = block.id else { continue }
                    open[toolID] = (name, prompt(forTool: name, input: block.input), since, lineMessageId)
                }
            case "user":
                open.removeAll() // D10 (b): ANY subsequent user line cancels — including the answer itself
                lastTurn = nil   // the user responded — the finished turn is handled
            default:
                break // system / attachment / ai-title / etc. do NOT cancel (D10)
            }
        }

        var states = open.map { id, candidate in
            AttentionState(
                projectKey: projectKey,
                sessionId: sessionId,
                filePath: url.path,
                toolName: candidate.name,
                prompt: candidate.prompt,
                since: candidate.since,
                id: id
            )
        }
        // A finished turn: assistant text with no tool_use ended the tail.
        // Suppressed for sidechain (subagent) files, and redundant when a
        // waiting tool is already open (that tool IS the tail's last line).
        if !sawSidechain, states.isEmpty, let turn = lastTurn, !turn.hasToolUse {
            states.append(AttentionState(
                projectKey: projectKey,
                sessionId: sessionId,
                filePath: url.path,
                toolName: turnCompletedToolName,
                prompt: turn.snippet,
                since: turn.since,
                id: "turn:" + (turn.messageId ?? sessionId)
            ))
        }
        return states
    }

    /// D10: the literal "Plan ready for review" for `ExitPlanMode`;
    /// otherwise the first question's `header` (always short in the real
    /// corpus, max observed 18 chars) falling back to its `question` text,
    /// truncated to 80 chars.
    private static func prompt(forTool name: String, input: TailLine.ToolInput?) -> String? {
        if name == "ExitPlanMode" {
            return "Plan ready for review"
        }
        guard let question = input?.questions?.first else { return nil }
        let header = question.header?.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = question.question?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let raw = (header?.isEmpty == false ? header : nil) ?? (text?.isEmpty == false ? text : nil) else {
            return nil
        }
        return String(raw.prefix(80))
    }

    // MARK: - Decoding

    private static let decoder = JSONDecoder()

    // See `TranscriptParser`'s identical comment: `ISO8601DateFormatter` is
    // a non-`Sendable` class; `Date.ISO8601FormatStyle` is a `Sendable`
    // value type safe to hold as a global constant.
    private static let isoWithFractionalSeconds = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let iso = Date.ISO8601FormatStyle(includingFractionalSeconds: false)

    private static func parseTimestamp(_ string: String) -> Date? {
        (try? Date(string, strategy: isoWithFractionalSeconds)) ?? (try? Date(string, strategy: iso))
    }
}

/// Minimal mirror of the on-disk line shape needed to walk `tool_use`
/// blocks — only the fields this detector actually needs.
private struct TailLine: Decodable {
    let type: String?
    let timestamp: String?
    let sessionId: String?
    let isSidechain: Bool?
    let message: Message?

    struct Message: Decodable {
        let id: String?
        let content: ContentValue?
    }

    struct ToolInput: Decodable {
        let questions: [Question]?
    }

    struct Question: Decodable {
        let header: String?
        let question: String?
    }

    struct ContentBlock: Decodable {
        let type: String?
        let id: String?
        let name: String?
        let text: String?
        let input: ToolInput?
    }

    /// `message.content` is a plain string for ordinary text messages, or
    /// an array of typed blocks for anything carrying `tool_use`.
    enum ContentValue: Decodable {
        case blocks([ContentBlock])
        case text(String)
        case other

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let blocks = try? container.decode([ContentBlock].self) {
                self = .blocks(blocks)
            } else if let text = try? container.decode(String.self) {
                self = .text(text)
            } else {
                self = .other
            }
        }

        var blocks: [ContentBlock] {
            if case .blocks(let blocks) = self { return blocks }
            return []
        }

        /// First 80 chars of the message's text — the string form directly,
        /// or the first non-empty `text` block.
        var textSnippet: String? {
            switch self {
            case .text(let text):
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : String(trimmed.prefix(80))
            case .blocks(let blocks):
                for block in blocks where block.type == "text" {
                    if let trimmed = block.text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty {
                        return String(trimmed.prefix(80))
                    }
                }
                return nil
            case .other:
                return nil
            }
        }
    }
}
