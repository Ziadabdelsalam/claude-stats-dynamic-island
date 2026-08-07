import Foundation
import Testing
@testable import ClaudeStatsCore

/// D10's pending rule: a waiting-set (`AskUserQuestion` / `ExitPlanMode`)
/// `tool_use` at the file's tail is pending iff no subsequent `user` or
/// `assistant` line follows it (system/attachment/etc. do NOT cancel it) and
/// it isn't stale. These fixtures hand-write that shape directly — no
/// dependency on real transcripts.
private enum Fixture {
    static func askUserQuestionLine(id: String, toolUseID: String, timestamp: String, sessionId: String = "sess-1", messageId: String? = nil) -> String {
        let msgId = messageId ?? "msg_\(id)"
        return """
        {"type":"assistant","uuid":"\(id)","timestamp":"\(timestamp)","sessionId":"\(sessionId)","cwd":"/tmp/proj","message":{"id":"\(msgId)","model":"claude-sonnet-5","content":[{"type":"tool_use","id":"\(toolUseID)","name":"AskUserQuestion","input":{"questions":[{"header":"Privacy","question":"Is the repo private? This is a much longer question body used only as a fallback when no header is present, to prove truncation to eighty characters works as specified."}]}}]}}
        """
    }

    static func exitPlanModeLine(id: String, toolUseID: String, timestamp: String, sessionId: String = "sess-1") -> String {
        """
        {"type":"assistant","uuid":"\(id)","timestamp":"\(timestamp)","sessionId":"\(sessionId)","cwd":"/tmp/proj","message":{"id":"msg_\(id)","model":"claude-sonnet-5","content":[{"type":"tool_use","id":"\(toolUseID)","name":"ExitPlanMode","input":{"plan":"# Some plan"}}]}}
        """
    }

    static func bashLine(id: String, toolUseID: String, timestamp: String, sessionId: String = "sess-1", messageId: String? = nil) -> String {
        let msgId = messageId ?? "msg_\(id)"
        return """
        {"type":"assistant","uuid":"\(id)","timestamp":"\(timestamp)","sessionId":"\(sessionId)","cwd":"/tmp/proj","message":{"id":"\(msgId)","model":"claude-sonnet-5","content":[{"type":"tool_use","id":"\(toolUseID)","name":"Bash","input":{"command":"ls"}}]}}
        """
    }

    static func toolResultLine(id: String, toolUseID: String, timestamp: String, sessionId: String = "sess-1") -> String {
        """
        {"type":"user","uuid":"\(id)","timestamp":"\(timestamp)","sessionId":"\(sessionId)","message":{"content":[{"type":"tool_result","tool_use_id":"\(toolUseID)","content":"the answer"}]}}
        """
    }

    static func plainUserLine(id: String, timestamp: String, sessionId: String = "sess-1") -> String {
        """
        {"type":"user","uuid":"\(id)","timestamp":"\(timestamp)","sessionId":"\(sessionId)","message":{"content":"never mind, stop"}}
        """
    }

    static func plainAssistantLine(id: String, timestamp: String, sessionId: String = "sess-1") -> String {
        """
        {"type":"assistant","uuid":"\(id)","timestamp":"\(timestamp)","sessionId":"\(sessionId)","message":{"id":"msg_\(id)","model":"claude-sonnet-5","content":[{"type":"text","text":"ok, continuing"}]}}
        """
    }

    static func systemLine(id: String, timestamp: String) -> String {
        """
        {"type":"system","uuid":"\(id)","timestamp":"\(timestamp)","subtype":"turn_duration"}
        """
    }

    static func attachmentLine(id: String, timestamp: String) -> String {
        """
        {"type":"attachment","uuid":"\(id)","timestamp":"\(timestamp)"}
        """
    }
}

/// Writes `content` (newline-joined lines, trailing newline added) to
/// `<root>/<projectDir>/<sessionFile>` and returns the file URL.
///
/// The file's mtime is forced to `mtime` (default: the tests' fixed `now`)
/// because the detector's pre-filter reads it: leaving it at wall-clock time
/// would make every positive-detection test start failing once real time
/// drifts more than the staleness window away from `now`.
@discardableResult
private func writeSession(root: URL, projectDir: String, sessionFile: String = "session.jsonl", lines: [String], mtime: Date = now) throws -> URL {
    let dir = root.appendingPathComponent(projectDir, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let fileURL = dir.appendingPathComponent(sessionFile)
    let content = lines.map { $0 + "\n" }.joined()
    try Data(content.utf8).write(to: fileURL)
    try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: fileURL.path)
    return fileURL
}

private func makeTempRoot() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("AttentionDetectorTests-\(UUID().uuidString)", isDirectory: true)
}

private let now = Date(timeIntervalSince1970: 1_785_000_000) // fixed instant
// 5 minutes before `now` — comfortably inside the default 30-minute staleness window.
private let recentTimestamp = ISO8601DateFormatter().string(from: now.addingTimeInterval(-5 * 60))
private let staleTimestamp = "2000-01-01T00:00:00.000Z" // decades before `now`
// 2 minutes before `now` — inside the short TurnCompleted window (3 minutes).
private let freshTimestamp = ISO8601DateFormatter().string(from: now.addingTimeInterval(-2 * 60))

@Test func pendingAskUserQuestionAtTailIsDetected() throws {
    let root = makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try writeSession(root: root, projectDir: "-tmp-proj", lines: [
        Fixture.askUserQuestionLine(id: "a1", toolUseID: "toolu_1", timestamp: recentTimestamp),
    ])

    let detector = AttentionDetector(root: root)
    let states = detector.pendingAttention(now: now)

    #expect(states.count == 1)
    let state = try #require(states.first)
    #expect(state.id == "toolu_1")
    #expect(state.toolName == "AskUserQuestion")
    #expect(state.projectKey == "-tmp-proj")
    #expect(state.sessionId == "sess-1")
    #expect(state.prompt == "Privacy") // header wins over the long question fallback
}

@Test func answeredQuestionIsNotDetected() throws {
    let root = makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try writeSession(root: root, projectDir: "-tmp-proj", lines: [
        Fixture.askUserQuestionLine(id: "a1", toolUseID: "toolu_1", timestamp: recentTimestamp),
        Fixture.toolResultLine(id: "a2", toolUseID: "toolu_1", timestamp: recentTimestamp),
    ])

    let states = AttentionDetector(root: root).pendingAttention(now: now)
    #expect(states.isEmpty)
}

@Test func interruptedByPlainUserLineIsNotDetected() throws {
    let root = makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try writeSession(root: root, projectDir: "-tmp-proj", lines: [
        Fixture.askUserQuestionLine(id: "a1", toolUseID: "toolu_1", timestamp: recentTimestamp),
        Fixture.plainUserLine(id: "a2", timestamp: recentTimestamp), // no matching tool_result — an interrupt, not an answer
    ])

    let states = AttentionDetector(root: root).pendingAttention(now: now)
    #expect(states.isEmpty)
}

@Test func subsequentAssistantLineIsNotDetected() throws {
    let root = makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try writeSession(root: root, projectDir: "-tmp-proj", lines: [
        Fixture.askUserQuestionLine(id: "a1", toolUseID: "toolu_1", timestamp: recentTimestamp),
        Fixture.plainAssistantLine(id: "a2", timestamp: recentTimestamp),
    ])

    let states = AttentionDetector(root: root).pendingAttention(now: now)
    #expect(states.isEmpty)
}

@Test func systemAndAttachmentLinesAfterStillDetected() throws {
    let root = makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try writeSession(root: root, projectDir: "-tmp-proj", lines: [
        Fixture.askUserQuestionLine(id: "a1", toolUseID: "toolu_1", timestamp: recentTimestamp),
        Fixture.systemLine(id: "a2", timestamp: recentTimestamp),
        Fixture.attachmentLine(id: "a3", timestamp: recentTimestamp),
    ])

    let states = AttentionDetector(root: root).pendingAttention(now: now)
    #expect(states.count == 1)
    #expect(states.first?.id == "toolu_1")
}

@Test func staleTimestampBeyondCutoffIsNotDetected() throws {
    let root = makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try writeSession(root: root, projectDir: "-tmp-proj", lines: [
        Fixture.askUserQuestionLine(id: "a1", toolUseID: "toolu_1", timestamp: staleTimestamp),
    ])

    // File mtime is "now" (just written), so the mtime pre-filter alone
    // would not exclude it — condition (c), the per-candidate timestamp
    // cutoff, is what must reject this one.
    let states = AttentionDetector(root: root, staleAfterMinutes: 30).pendingAttention(now: now)
    #expect(states.isEmpty)
}

@Test func exitPlanModePendingUsesFixedPrompt() throws {
    let root = makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try writeSession(root: root, projectDir: "-tmp-proj", lines: [
        Fixture.exitPlanModeLine(id: "a1", toolUseID: "toolu_plan", timestamp: recentTimestamp),
    ])

    let states = AttentionDetector(root: root).pendingAttention(now: now)
    #expect(states.count == 1)
    #expect(states.first?.toolName == "ExitPlanMode")
    #expect(states.first?.prompt == "Plan ready for review")
}

@Test func danglingBashToolUseIsNeverDetected() throws {
    let root = makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try writeSession(root: root, projectDir: "-tmp-proj", lines: [
        Fixture.bashLine(id: "a1", toolUseID: "toolu_bash", timestamp: recentTimestamp),
        // No subsequent line at all: Bash "looks" identical to a pending
        // question by shape alone. It must never surface — Bash is not in
        // the default waiting set (D10).
    ])

    let states = AttentionDetector(root: root).pendingAttention(now: now)
    #expect(states.isEmpty)
}

@Test func mirroredDuplicateDedupsByToolUseIDKeepingSmallestProjectKey() throws {
    let root = makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    // Same session (and the same tool_use id) mirrored under two project
    // dirs, as real cross-file duplicates are (D2/E-series).
    try writeSession(root: root, projectDir: "-tmp-zzz-later", lines: [
        Fixture.askUserQuestionLine(id: "a1", toolUseID: "toolu_shared", timestamp: recentTimestamp),
    ])
    try writeSession(root: root, projectDir: "-tmp-aaa-earlier", lines: [
        Fixture.askUserQuestionLine(id: "a1", toolUseID: "toolu_shared", timestamp: recentTimestamp),
    ])

    let states = AttentionDetector(root: root).pendingAttention(now: now)
    #expect(states.count == 1)
    #expect(states.first?.projectKey == "-tmp-aaa-earlier")
}

@Test func malformedTailLineIsSkippedWithoutCrashing() throws {
    let root = makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try writeSession(root: root, projectDir: "-tmp-proj", lines: [
        Fixture.askUserQuestionLine(id: "a1", toolUseID: "toolu_1", timestamp: recentTimestamp),
        "{ this is not valid json at all }}}",
    ])

    // The malformed line is neither `user` nor `assistant`-shaped JSON, so
    // it must be skipped like any other non-cancelling line — no crash,
    // and the candidate ahead of it is still pending.
    let states = AttentionDetector(root: root).pendingAttention(now: now)
    #expect(states.count == 1)
    #expect(states.first?.id == "toolu_1")
}

@Test func toolUseStraddlingOutsideTheTailWindowIsNotDetected() throws {
    let root = makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let padding = String(repeating: "x", count: 500)
    try writeSession(root: root, projectDir: "-tmp-proj", lines: [
        Fixture.askUserQuestionLine(id: "a1", toolUseID: "toolu_1", timestamp: recentTimestamp),
        // A filler line alone bigger than the (deliberately tiny) tail
        // window, so the tail cut lands inside it — the pending tool_use
        // above is pushed entirely outside the last `tailBytes` bytes.
        Fixture.systemLine(id: "a2", timestamp: recentTimestamp) + padding,
    ])

    let detector = AttentionDetector(root: root, tailBytes: 64)
    let states = detector.pendingAttention(now: now)
    #expect(states.isEmpty, "a tool_use id straddling outside the tail window must never surface, and must never crash")
}

@Test func fileWithStaleMtimeIsSkippedUnopened() throws {
    let root = makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    // Line timestamp is fresh, so only the mtime pre-filter (D10) can
    // reject this file — it is what keeps a full-corpus scan cheap.
    try writeSession(root: root, projectDir: "-tmp-proj", lines: [
        Fixture.askUserQuestionLine(id: "a1", toolUseID: "toolu_1", timestamp: recentTimestamp),
    ], mtime: now.addingTimeInterval(-31 * 60))

    #expect(AttentionDetector(root: root, staleAfterMinutes: 30).pendingAttention(now: now).isEmpty)
}

@Test func stalenessBoundaryIsInclusive() throws {
    let root = makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let atCutoff = ISO8601DateFormatter().string(from: now.addingTimeInterval(-30 * 60))
    let pastCutoff = ISO8601DateFormatter().string(from: now.addingTimeInterval(-30 * 60 - 1))
    try writeSession(root: root, projectDir: "-tmp-at", lines: [
        Fixture.askUserQuestionLine(id: "a1", toolUseID: "toolu_at", timestamp: atCutoff),
    ])
    try writeSession(root: root, projectDir: "-tmp-past", lines: [
        Fixture.askUserQuestionLine(id: "a2", toolUseID: "toolu_past", timestamp: pastCutoff),
    ])

    // D10 (c): pending iff `now − timestamp ≤ staleAfterMinutes`.
    let states = AttentionDetector(root: root, staleAfterMinutes: 30).pendingAttention(now: now)
    #expect(states.map(\.id) == ["toolu_at"])
}

@Test func duplicateOfTheToolUseLineDoesNotSelfCancel() throws {
    let root = makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    // Claude Code re-writes the same assistant message several times in a
    // file. The duplicate IS a subsequent `assistant` line, so it cancels —
    // but it carries the same `tool_use`, which re-opens the candidate. A
    // still-unanswered question must survive its own duplicates.
    let line = Fixture.askUserQuestionLine(id: "a1", toolUseID: "toolu_1", timestamp: recentTimestamp)
    try writeSession(root: root, projectDir: "-tmp-proj", lines: [line, line, line])

    let states = AttentionDetector(root: root).pendingAttention(now: now)
    #expect(states.count == 1)
    #expect(states.first?.id == "toolu_1")
}

@Test func sameMessageIdSiblingAssistantLineDoesNotCancel() throws {
    let root = makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    // A parallel same-turn sibling tool call: a second physical line for
    // the SAME `message.id`, calling a different tool (Bash) alongside the
    // pending question. E19: this is not subsequent progress and must not
    // cancel the still-open AskUserQuestion.
    try writeSession(root: root, projectDir: "-tmp-proj", lines: [
        Fixture.askUserQuestionLine(id: "a1", toolUseID: "toolu_ask", timestamp: recentTimestamp, messageId: "msg_shared"),
        Fixture.bashLine(id: "a2", toolUseID: "toolu_bash", timestamp: recentTimestamp, messageId: "msg_shared"),
    ])

    let states = AttentionDetector(root: root).pendingAttention(now: now)
    #expect(states.count == 1)
    #expect(states.first?.id == "toolu_ask")
}

@Test func differentMessageIdAssistantLineStillCancels() throws {
    let root = makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    // Same shape as above, but the follow-up line is a genuinely later
    // turn (a different `message.id`) — E19 does not protect this case,
    // D10 (b) still cancels.
    try writeSession(root: root, projectDir: "-tmp-proj", lines: [
        Fixture.askUserQuestionLine(id: "a1", toolUseID: "toolu_ask", timestamp: recentTimestamp, messageId: "msg_one"),
        Fixture.bashLine(id: "a2", toolUseID: "toolu_bash", timestamp: recentTimestamp, messageId: "msg_two"),
    ])

    let states = AttentionDetector(root: root).pendingAttention(now: now)
    #expect(states.isEmpty)
}

@Test func unreadableFileProducesNoNudgeAndNoCrash() throws {
    let root = makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let fileURL = try writeSession(root: root, projectDir: "-tmp-proj", lines: [
        Fixture.askUserQuestionLine(id: "a1", toolUseID: "toolu_1", timestamp: recentTimestamp),
    ])
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: fileURL.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fileURL.path) }

    // D10: an I/O failure degrades to "no nudge", never to a guess.
    #expect(AttentionDetector(root: root).pendingAttention(now: now).isEmpty)
}

@Test func candidatesWithEqualTimestampsAreOrderedDeterministically() throws {
    let root = makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try writeSession(root: root, projectDir: "-tmp-b", lines: [
        Fixture.askUserQuestionLine(id: "a1", toolUseID: "toolu_2", timestamp: recentTimestamp, sessionId: "sess-2"),
    ])
    try writeSession(root: root, projectDir: "-tmp-a", lines: [
        Fixture.askUserQuestionLine(id: "a2", toolUseID: "toolu_1", timestamp: recentTimestamp, sessionId: "sess-1"),
    ])

    // Consumers diff this array; `since` ties must not reorder run to run.
    let detector = AttentionDetector(root: root)
    let first = detector.pendingAttention(now: now).map(\.id)
    #expect(first == ["toolu_1", "toolu_2"])
    for _ in 0..<5 {
        #expect(detector.pendingAttention(now: now).map(\.id) == first)
    }
}

// MARK: - TurnCompleted (finished-turn nudge)

/// A quiet file whose tail ends in a plain assistant text message is a
/// finished turn: Claude stopped and is waiting for the user.
@Test func finishedTurnAtQuietTailIsDetected() throws {
    let root = makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try writeSession(root: root, projectDir: "-tmp-proj", lines: [
        Fixture.plainUserLine(id: "u1", timestamp: freshTimestamp),
        Fixture.plainAssistantLine(id: "a1", timestamp: freshTimestamp),
    ], mtime: now.addingTimeInterval(-60))

    let states = AttentionDetector(root: root).pendingAttention(now: now)
    #expect(states.count == 1)
    #expect(states.first?.toolName == AttentionDetector.turnCompletedToolName)
    #expect(states.first?.prompt == "ok, continuing")
    #expect(states.first?.id == "turn:msg_a1")
}

/// The quiet gate: an mtime younger than `turnQuietSeconds` means Claude may
/// still be mid-turn (prose written moments before the next tool call), so
/// the finish is not yet believed.
@Test func finishedTurnWithinQuietWindowIsSuppressed() throws {
    let root = makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try writeSession(root: root, projectDir: "-tmp-proj", lines: [
        Fixture.plainAssistantLine(id: "a1", timestamp: recentTimestamp),
    ], mtime: now.addingTimeInterval(-5))

    #expect(AttentionDetector(root: root).pendingAttention(now: now).isEmpty)
}

/// Any subsequent user line clears the finished turn — the user came back
/// and responded, which is the nearest observable "I saw it".
@Test func subsequentUserLineClearsFinishedTurn() throws {
    let root = makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try writeSession(root: root, projectDir: "-tmp-proj", lines: [
        Fixture.plainAssistantLine(id: "a1", timestamp: recentTimestamp),
        Fixture.plainUserLine(id: "u1", timestamp: recentTimestamp),
    ], mtime: now.addingTimeInterval(-60))

    #expect(AttentionDetector(root: root).pendingAttention(now: now).isEmpty)
}

/// A dangling ordinary tool (T11) still means "running or at a permission
/// prompt", never a finished turn — even on a long-quiet file.
@Test func danglingOrdinaryToolIsNotAFinishedTurn() throws {
    let root = makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try writeSession(root: root, projectDir: "-tmp-proj", lines: [
        Fixture.bashLine(id: "a1", toolUseID: "toolu_1", timestamp: recentTimestamp),
    ], mtime: now.addingTimeInterval(-60))

    #expect(AttentionDetector(root: root).pendingAttention(now: now).isEmpty)
}

/// Sidechain (subagent) transcripts finish constantly while the parent
/// session is still hard at work — they must never nudge.
@Test func sidechainFileNeverReportsFinishedTurn() throws {
    let root = makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let sidechainLine = """
    {"type":"assistant","uuid":"a1","timestamp":"\(recentTimestamp)","sessionId":"sess-1","isSidechain":true,"message":{"id":"msg_a1","model":"claude-sonnet-5","content":[{"type":"text","text":"subagent done"}]}}
    """
    try writeSession(root: root, projectDir: "-tmp-proj", lines: [sidechainLine], mtime: now.addingTimeInterval(-60))

    #expect(AttentionDetector(root: root).pendingAttention(now: now).isEmpty)
}

/// A waiting tool at the tail is already the stronger signal; the finished
/// turn must not double-report alongside it.
@Test func waitingToolIsNotDoubledByFinishedTurn() throws {
    let root = makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try writeSession(root: root, projectDir: "-tmp-proj", lines: [
        Fixture.askUserQuestionLine(id: "a1", toolUseID: "toolu_1", timestamp: recentTimestamp),
    ], mtime: now.addingTimeInterval(-60))

    let states = AttentionDetector(root: root).pendingAttention(now: now)
    #expect(states.map(\.toolName) == ["AskUserQuestion"])
}

/// `message.content` as a plain string (the other on-disk shape for pure
/// text) also counts as a finished turn, snippet included.
@Test func stringContentAssistantTailIsAFinishedTurn() throws {
    let root = makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let stringLine = """
    {"type":"assistant","uuid":"a1","timestamp":"\(freshTimestamp)","sessionId":"sess-1","message":{"id":"msg_a1","model":"claude-sonnet-5","content":"all done here"}}
    """
    try writeSession(root: root, projectDir: "-tmp-proj", lines: [stringLine], mtime: now.addingTimeInterval(-60))

    let states = AttentionDetector(root: root).pendingAttention(now: now)
    #expect(states.first?.toolName == AttentionDetector.turnCompletedToolName)
    #expect(states.first?.prompt == "all done here")
}

// MARK: - latestUserPrompts (current-task summary)

/// The newest genuine user prompt wins; slash-command/caveat meta lines and
/// tool_result carriers are not prompts.
@Test func latestUserPromptSkipsMetaAndToolResultLines() throws {
    let root = makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let older = ISO8601DateFormatter().string(from: now.addingTimeInterval(-10 * 60))
    let commandLine = """
    {"type":"user","uuid":"u2","timestamp":"\(recentTimestamp)","sessionId":"sess-1","message":{"content":"<command-name>/effort</command-name>"}}
    """
    try writeSession(root: root, projectDir: "-tmp-proj", lines: [
        """
        {"type":"user","uuid":"u1","timestamp":"\(older)","sessionId":"sess-1","message":{"content":"fix the login bug"}}
        """,
        Fixture.toolResultLine(id: "u3", toolUseID: "toolu_1", timestamp: recentTimestamp),
        commandLine,
    ])

    let prompts = AttentionDetector(root: root).latestUserPrompts(now: now)
    #expect(prompts == ["-tmp-proj": "fix the login bug"])
}

/// Sidechain (subagent) files carry agent briefs, not the user's task.
@Test func latestUserPromptIgnoresSidechainFiles() throws {
    let root = makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let sidechainUser = """
    {"type":"user","uuid":"u1","timestamp":"\(recentTimestamp)","sessionId":"sess-1","isSidechain":true,"message":{"content":"You are a subagent. Do X."}}
    """
    try writeSession(root: root, projectDir: "-tmp-proj", lines: [sidechainUser])

    #expect(AttentionDetector(root: root).latestUserPrompts(now: now).isEmpty)
}

/// Across a project's files, the most recent prompt (by timestamp) wins.
@Test func latestUserPromptPicksNewestAcrossSessions() throws {
    let root = makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let older = ISO8601DateFormatter().string(from: now.addingTimeInterval(-20 * 60))
    try writeSession(root: root, projectDir: "-tmp-proj", sessionFile: "old.jsonl", lines: [
        """
        {"type":"user","uuid":"u1","timestamp":"\(older)","sessionId":"sess-old","message":{"content":"the older task"}}
        """,
    ])
    try writeSession(root: root, projectDir: "-tmp-proj", sessionFile: "new.jsonl", lines: [
        """
        {"type":"user","uuid":"u2","timestamp":"\(recentTimestamp)","sessionId":"sess-new","message":{"content":"the current task"}}
        """,
    ])

    #expect(AttentionDetector(root: root).latestUserPrompts(now: now) == ["-tmp-proj": "the current task"])
}

// MARK: - sessionStatuses (D14: per-project session grouping)

/// Three files in one project map to three grouped sessions, newest first,
/// each classified by its tail: dangling ordinary tool -> working, waiting
/// tool -> waiting, quiet plain-text tail -> finished.
@Test func sessionStatusesGroupAndClassifyPerProject() throws {
    let root = makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try writeSession(root: root, projectDir: "-tmp-proj", sessionFile: "working.jsonl", lines: [
        Fixture.plainUserLine(id: "u1", timestamp: recentTimestamp, sessionId: "sess-work"),
        Fixture.bashLine(id: "a1", toolUseID: "toolu_1", timestamp: recentTimestamp, sessionId: "sess-work"),
    ], mtime: now.addingTimeInterval(-30))
    try writeSession(root: root, projectDir: "-tmp-proj", sessionFile: "waiting.jsonl", lines: [
        Fixture.askUserQuestionLine(id: "a2", toolUseID: "toolu_2", timestamp: recentTimestamp, sessionId: "sess-wait"),
    ], mtime: now.addingTimeInterval(-60))
    try writeSession(root: root, projectDir: "-tmp-proj", sessionFile: "finished.jsonl", lines: [
        Fixture.plainUserLine(id: "u2", timestamp: recentTimestamp, sessionId: "sess-done"),
        Fixture.plainAssistantLine(id: "a3", timestamp: recentTimestamp, sessionId: "sess-done"),
    ], mtime: now.addingTimeInterval(-90))

    let grouped = AttentionDetector(root: root).sessionStatuses(now: now)
    let sessions = try #require(grouped["-tmp-proj"])
    #expect(sessions.map(\.sessionId) == ["sess-work", "sess-wait", "sess-done"])
    #expect(sessions.map(\.state) == [.working, .waiting, .finished])
    #expect(sessions[0].task == "never mind, stop")
}

/// A finished-looking tail on a file still being written (younger than the
/// quiet gate) stays `working` — mid-turn prose, not a finish.
@Test func sessionStatusFreshPlainTailIsStillWorking() throws {
    let root = makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try writeSession(root: root, projectDir: "-tmp-proj", lines: [
        Fixture.plainAssistantLine(id: "a1", timestamp: recentTimestamp),
    ], mtime: now.addingTimeInterval(-3))

    let grouped = AttentionDetector(root: root).sessionStatuses(now: now)
    #expect(grouped["-tmp-proj"]?.map(\.state) == [.working])
}

/// Sidechain (subagent) files are not sessions of their own.
@Test func sessionStatusesSkipSidechainFiles() throws {
    let root = makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let sidechain = """
    {"type":"assistant","uuid":"a1","timestamp":"\(recentTimestamp)","sessionId":"sess-1","isSidechain":true,"message":{"id":"msg_a1","model":"claude-sonnet-5","content":[{"type":"text","text":"subagent"}]}}
    """
    try writeSession(root: root, projectDir: "-tmp-proj", lines: [sidechain], mtime: now.addingTimeInterval(-60))

    #expect(AttentionDetector(root: root).sessionStatuses(now: now).isEmpty)
}
