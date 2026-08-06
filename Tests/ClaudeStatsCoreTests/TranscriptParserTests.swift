import Foundation
import Testing
@testable import ClaudeStatsCore

/// `Fixtures/sample.jsonl` (hand-written, see the file itself) covers:
///  - 3 assistant lines sharing one `message.id` (`msg_AAA1`) -> 1 kept event, 2 dropped duplicates
///  - a distinct second response (`msg_BBB2`) whose `cache_creation` object is absent, so its
///    `cache_creation_input_tokens` falls back into `cacheWrite5m`
///  - a `<synthetic>` line that DOES carry a usage object -> must be skipped by model id, not usage
///  - an assistant line with real usage but `"requestId": null` (`msg_CCC3`) -> still kept
///  - a `user` line -> filtered by the byte-prefilter before any JSON decode
///  - a malformed/truncated JSON line -> counted, never fatal
///  - an assistant line with no `usage` at all (`msg_DDD4`) -> silently skipped
private func loadFixtureURL() throws -> URL {
    let url = try #require(
        Bundle.module.url(forResource: "sample", withExtension: "jsonl", subdirectory: "Fixtures")
    )
    return url
}

@Test func perFileDedupDropsRepeatedMessageIdAndKeepsFirstOccurrence() throws {
    let parser = TranscriptParser(root: URL(fileURLWithPath: "/dev/null"))
    let result = try parser.parseFile(at: loadFixtureURL(), from: 0)

    let event = try #require(result.events.first { $0.messageId == "msg_AAA1" })
    #expect(result.events.filter { $0.messageId == "msg_AAA1" }.count == 1)
    #expect(event.tokens.input == 100)
    #expect(event.tokens.output == 50)
    #expect(event.tokens.cacheWrite5m == 200)
    #expect(event.tokens.cacheWrite1h == 0)
    #expect(event.tokens.cacheRead == 10)
    #expect(event.model == "claude-sonnet-5")
    #expect(event.requestId == "req_AAA1")
    #expect(event.sessionId == "session-A")
    // D2b: `cwd` is only trusted as a display-name source when it round-trips
    // against the file's own encoded directory name. This fixture is loaded
    // directly from the test bundle (parent dir "Fixtures", not an encoded
    // `-Volumes-...` directory), so none of its `cwd` values round-trip and
    // displayName falls back to the (fallback) directory name verbatim. The
    // round-trip accept/reject paths themselves are covered by
    // `roundTrippingCwdBecomesDisplayName` and
    // `nonRoundTrippingCwdFallsBackToEncodedDirectoryName` below.
    #expect(event.projectDisplayName == "Fixtures")
}

@Test func absentCacheCreationObjectFallsBackToCacheWrite5m() throws {
    let parser = TranscriptParser(root: URL(fileURLWithPath: "/dev/null"))
    let result = try parser.parseFile(at: loadFixtureURL(), from: 0)

    let event = try #require(result.events.first { $0.messageId == "msg_BBB2" })
    #expect(event.tokens.input == 300)
    #expect(event.tokens.output == 150)
    #expect(event.tokens.cacheWrite5m == 400, "cache_creation_input_tokens must fall back into cacheWrite5m when cache_creation is absent")
    #expect(event.tokens.cacheWrite1h == 0)
    #expect(event.tokens.cacheRead == 20)
}

@Test func nullRequestIdWithRealUsageIsStillKept() throws {
    let parser = TranscriptParser(root: URL(fileURLWithPath: "/dev/null"))
    let result = try parser.parseFile(at: loadFixtureURL(), from: 0)

    let event = try #require(result.events.first { $0.messageId == "msg_CCC3" })
    #expect(event.requestId == nil)
    #expect(event.tokens.input == 50)
    #expect(event.tokens.output == 25)
    #expect(event.tokens.cacheWrite1h == 75)
    #expect(event.tokens.cacheRead == 5)
}

@Test func syntheticModelLineWithUsageIsFilteredByModelIdNotUsagePresence() throws {
    let parser = TranscriptParser(root: URL(fileURLWithPath: "/dev/null"))
    let result = try parser.parseFile(at: loadFixtureURL(), from: 0)

    #expect(!result.events.contains { $0.messageId == "msg_SYN1" })
    #expect(!result.events.contains { $0.model == "<synthetic>" })
}

@Test func assistantLineWithNoUsageIsSkippedSilently() throws {
    let parser = TranscriptParser(root: URL(fileURLWithPath: "/dev/null"))
    let result = try parser.parseFile(at: loadFixtureURL(), from: 0)

    #expect(!result.events.contains { $0.messageId == "msg_DDD4" })
}

@Test func exactDeduplicatedTokenTotalsAndCounters() throws {
    let parser = TranscriptParser(root: URL(fileURLWithPath: "/dev/null"))
    let result = try parser.parseFile(at: loadFixtureURL(), from: 0)

    // 3 kept events: msg_AAA1, msg_BBB2, msg_CCC3.
    #expect(result.events.count == 3)

    let totals = result.events.reduce(TokenCounts.zero) { $0 + $1.tokens }
    #expect(totals.input == 450)       // 100 + 300 + 50
    #expect(totals.output == 225)      // 50 + 150 + 25
    #expect(totals.cacheWrite5m == 600) // 200 + 400 + 0
    #expect(totals.cacheWrite1h == 75)  // 0 + 0 + 75
    #expect(totals.cacheRead == 35)     // 10 + 20 + 5
    #expect(totals.total == 1385)

    #expect(result.counters.filesScanned == 1)
    #expect(result.counters.linesRead == 9)
    #expect(result.counters.eventsKept == 3)
    #expect(result.counters.duplicatesDropped == 2)
    #expect(result.counters.malformedLines == 1)
}

@Test func userLineNeverReachesTheDecoder() throws {
    let parser = TranscriptParser(root: URL(fileURLWithPath: "/dev/null"))
    let result = try parser.parseFile(at: loadFixtureURL(), from: 0)

    // The user line is filtered out by the byte-prefilter before any JSON
    // decode is attempted, so it must not inflate `malformedLines` — only
    // the genuinely truncated assistant line does.
    #expect(result.counters.malformedLines == 1)
}

// MARK: - endOffset semantics

@Test func endOffsetNeverAdvancesPastAnUnterminatedTrailingLine() throws {
    let completeLine = """
    {"type":"assistant","uuid":"aaaa","timestamp":"2026-08-01T11:00:00.000Z","sessionId":"session-B","cwd":"/tmp/proj-x","requestId":"req_X1","message":{"id":"msg_X1","model":"claude-sonnet-5","usage":{"input_tokens":10,"output_tokens":5,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}
    """
    let fullSecondLine = """
    {"type":"assistant","uuid":"bbbb","timestamp":"2026-08-01T11:01:00.000Z","sessionId":"session-B","cwd":"/tmp/proj-x","requestId":"req_X2","message":{"id":"msg_X2","model":"claude-sonnet-5","usage":{"input_tokens":20,"output_tokens":10,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}
    """
    // Simulate Claude Code having only flushed part of the second line to disk.
    let partialSecondLine = String(fullSecondLine.dropLast(20))
    let remainderOfSecondLine = String(fullSecondLine.suffix(20))

    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("TranscriptParserTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    let fileURL = tempDir.appendingPathComponent("session.jsonl")
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let initialContent = completeLine + "\n" + partialSecondLine
    try initialContent.data(using: .utf8)!.write(to: fileURL)

    let parser = TranscriptParser(root: URL(fileURLWithPath: "/dev/null"))
    let firstRead = try parser.parseFile(at: fileURL, from: 0)

    // Only the complete first line was consumed; the unterminated trailing
    // line must not be parsed or advanced past.
    #expect(firstRead.events.count == 1)
    #expect(firstRead.events.first?.messageId == "msg_X1")
    #expect(firstRead.counters.linesRead == 1)
    let expectedFirstEndOffset = UInt64((completeLine + "\n").utf8.count)
    #expect(firstRead.endOffset == expectedFirstEndOffset)

    let fullFileSizeSoFar = UInt64(initialContent.utf8.count)
    #expect(firstRead.endOffset < fullFileSizeSoFar, "endOffset must stop before the partial trailing line")

    // Claude Code finishes writing the rest of the second line.
    let handle = try FileHandle(forWritingTo: fileURL)
    defer { try? handle.close() }
    try handle.seekToEnd()
    handle.write((remainderOfSecondLine + "\n").data(using: .utf8)!)

    // Resuming from the previous endOffset must pick up the now-complete
    // second line whole, never re-reading or losing bytes.
    let secondRead = try parser.parseFile(at: fileURL, from: firstRead.endOffset)
    #expect(secondRead.events.count == 1)
    #expect(secondRead.events.first?.messageId == "msg_X2")
    #expect(secondRead.counters.linesRead == 1)

    let finalSize = try FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? UInt64
    #expect(secondRead.endOffset == finalSize)
}

// MARK: - parseAll

/// `parseAll` is the surface T5 (incremental refresh) and T9 (real-data gate) code against, and
/// the parser/aggregator dedup split runs through it: dedup here is per-file ONLY, so a
/// `message.id` appearing in two different files must survive as two events for
/// `Aggregator.rollup` to resolve globally (D2). Counters must sum across files.
@Test func parseAllAggregatesCountersAndDedupsPerFileOnly() async throws {
    func assistantLine(id: String, input: Int, output: Int) -> String {
        """
        {"type":"assistant","uuid":"u-\(id)","timestamp":"2026-08-01T12:00:00.000Z","sessionId":"session-P","cwd":"/tmp/whatever","requestId":"req-\(id)","message":{"id":"\(id)","model":"claude-sonnet-5","usage":{"input_tokens":\(input),"output_tokens":\(output),"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}
        """
    }

    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("TranscriptParserTests-root-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let alpha = root.appendingPathComponent("-tmp-alpha", isDirectory: true)
    let beta = root.appendingPathComponent("-tmp-beta", isDirectory: true)
    try FileManager.default.createDirectory(at: alpha, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: beta, withIntermediateDirectories: true)

    // alpha: msg_P1 twice (one in-file duplicate) plus msg_P2.
    let alphaContent = assistantLine(id: "msg_P1", input: 10, output: 1) + "\n"
        + assistantLine(id: "msg_P1", input: 10, output: 1) + "\n"
        + assistantLine(id: "msg_P2", input: 20, output: 2) + "\n"
    try Data(alphaContent.utf8).write(to: alpha.appendingPathComponent("s1.jsonl"))

    // beta: msg_P1 again (a CROSS-file duplicate — must NOT be dropped here) plus msg_P3.
    let betaContent = assistantLine(id: "msg_P1", input: 10, output: 1) + "\n"
        + assistantLine(id: "msg_P3", input: 30, output: 3) + "\n"
    try Data(betaContent.utf8).write(to: beta.appendingPathComponent("s2.jsonl"))

    let (events, counters) = try await TranscriptParser(root: root).parseAll()

    #expect(counters.filesScanned == 2)
    #expect(counters.linesRead == 5)
    #expect(counters.eventsKept == 4)
    #expect(counters.duplicatesDropped == 1, "only the in-file repeat of msg_P1 is dropped")
    #expect(counters.malformedLines == 0)

    // parseAll completion order is nondeterministic, so compare sorted.
    #expect(events.map(\.messageId).sorted() == ["msg_P1", "msg_P1", "msg_P2", "msg_P3"],
            "the cross-file msg_P1 duplicate must survive — global dedup is Aggregator's job (D2)")
    #expect(Set(events.map(\.projectKey)) == ["-tmp-alpha", "-tmp-beta"],
            "projectKey comes from the encoded directory name, never from the line's cwd")
}

@Test func fullyTerminatedFileAdvancesEndOffsetToFileSize() throws {
    let fixtureURL = try loadFixtureURL()
    let parser = TranscriptParser(root: URL(fileURLWithPath: "/dev/null"))
    let result = try parser.parseFile(at: fixtureURL, from: 0)

    let fileSize = try FileManager.default.attributesOfItem(atPath: fixtureURL.path)[.size] as? UInt64
    #expect(result.endOffset == fileSize)
}

// MARK: - D2a: recursive enumeration + projectKey attribution

/// D2a: real transcripts live several levels deeper than
/// `<root>/<encoded-dir>/<file>.jsonl` — e.g. subagent runs under
/// `<encoded-dir>/<sessionId>/subagents/agent-*.jsonl`. `parseAll` must find
/// them, and `projectKey` must still be the *first* path component under
/// `root`, regardless of nesting depth.
@Test func parseAllRecursesIntoNestedSubagentDirectoriesAndAttributesToTopLevelProject() async throws {
    func assistantLine(id: String) -> String {
        """
        {"type":"assistant","uuid":"u-\(id)","timestamp":"2026-08-01T13:00:00.000Z","sessionId":"session-nested","cwd":"/tmp/proj-nested","requestId":"req-\(id)","message":{"id":"\(id)","model":"claude-sonnet-5","usage":{"input_tokens":1,"output_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}
        """
    }

    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("TranscriptParserTests-nested-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let projectDir = root.appendingPathComponent("-tmp-proj-nested", isDirectory: true)
    let subagentsDir = projectDir
        .appendingPathComponent("session-nested", isDirectory: true)
        .appendingPathComponent("subagents", isDirectory: true)
    try FileManager.default.createDirectory(at: subagentsDir, withIntermediateDirectories: true)

    // Top-level session transcript, one level under the project dir.
    try Data((assistantLine(id: "msg_TOP1") + "\n").utf8)
        .write(to: projectDir.appendingPathComponent("session-nested.jsonl"))
    // A subagent transcript, three levels deeper.
    try Data((assistantLine(id: "msg_SUB1") + "\n").utf8)
        .write(to: subagentsDir.appendingPathComponent("agent-a.jsonl"))

    let (events, counters) = try await TranscriptParser(root: root).parseAll()

    #expect(counters.filesScanned == 2, "the recursive enumerator must find the nested subagent file too")
    #expect(Set(events.map(\.messageId)) == ["msg_TOP1", "msg_SUB1"])
    #expect(Set(events.map(\.projectKey)) == ["-tmp-proj-nested"],
            "projectKey is the first path component under root regardless of nesting depth")
}

// MARK: - D2b: displayName round-trip rule

@Test func roundTrippingCwdBecomesDisplayName() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("TranscriptParserTests-roundtrip-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    // "/tmp/work/my-proj" -> replace "/" with "-" -> "-tmp-work-my-proj",
    // exactly the encoded directory name below.
    let projectDir = root.appendingPathComponent("-tmp-work-my-proj", isDirectory: true)
    try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)

    let line = """
    {"type":"assistant","uuid":"u1","timestamp":"2026-08-01T14:00:00.000Z","sessionId":"session-rt","cwd":"/tmp/work/my-proj","requestId":"req-rt1","message":{"id":"msg_RT1","model":"claude-sonnet-5","usage":{"input_tokens":1,"output_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}
    """
    let fileURL = projectDir.appendingPathComponent("session-rt.jsonl")
    try Data((line + "\n").utf8).write(to: fileURL)

    let result = try TranscriptParser(root: root).parseFile(at: fileURL, from: 0)
    let event = try #require(result.events.first)
    #expect(event.projectKey == "-tmp-work-my-proj")
    #expect(event.projectDisplayName == "my-proj", "a round-tripping cwd's basename becomes the display name")
}

@Test func nonRoundTrippingCwdFallsBackToEncodedDirectoryNameVerbatim() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("TranscriptParserTests-noroundtrip-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let projectDir = root.appendingPathComponent("-tmp-work-my-proj", isDirectory: true)
    try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)

    // This cwd re-encodes to "-tmp-somewhere-else", which does NOT match the
    // encoded directory name -- it must never be guessed/used.
    let line = """
    {"type":"assistant","uuid":"u1","timestamp":"2026-08-01T14:05:00.000Z","sessionId":"session-rt2","cwd":"/tmp/somewhere-else","requestId":"req-rt2","message":{"id":"msg_RT2","model":"claude-sonnet-5","usage":{"input_tokens":1,"output_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}
    """
    let fileURL = projectDir.appendingPathComponent("session-rt2.jsonl")
    try Data((line + "\n").utf8).write(to: fileURL)

    let result = try TranscriptParser(root: root).parseFile(at: fileURL, from: 0)
    let event = try #require(result.events.first)
    #expect(event.projectKey == "-tmp-work-my-proj")
    #expect(
        event.projectDisplayName == "tmp-work-my-proj",
        "no cwd round-trips, so displayName falls back to the encoded dir name with only the leading '-' stripped, verbatim"
    )
}

/// Claude Code encodes spaces in a path the same way it encodes `/` and `.`: the real transcript
/// directory `-Volumes-SSD-Workspace-my-website` holds lines whose `cwd` is
/// `/Volumes/SSD/Workspace/my website`, with no space-named sibling directory. Without the space in
/// the re-encoding class those 2,126 real events fell back to "Volumes-SSD-Workspace-my-website".
@Test func spaceInCwdReEncodesToDashAndRoundTrips() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("TranscriptParserTests-space-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let projectDir = root.appendingPathComponent("-tmp-work-my-website", isDirectory: true)
    try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)

    let line = """
    {"type":"assistant","uuid":"u1","timestamp":"2026-08-01T14:10:00.000Z","sessionId":"session-sp","cwd":"/tmp/work/my website","requestId":"req-sp","message":{"id":"msg_SP1","model":"claude-sonnet-5","usage":{"input_tokens":1,"output_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}
    """
    let fileURL = projectDir.appendingPathComponent("session-sp.jsonl")
    try Data((line + "\n").utf8).write(to: fileURL)

    let result = try TranscriptParser(root: root).parseFile(at: fileURL, from: 0)
    let event = try #require(result.events.first)
    #expect(event.projectKey == "-tmp-work-my-website")
    #expect(event.projectDisplayName == "my website",
            "'/tmp/work/my website' re-encodes to '-tmp-work-my-website' once spaces map to '-'")
}

/// The ancestor walk must only accept an ancestor whose *entire* encoding equals the directory
/// name. A shared parent like `/tmp/work` is an ancestor of many projects and must never win.
@Test func ancestorWalkAcceptsOnlyExactWholeStringMatches() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("TranscriptParserTests-anc-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let projectDir = root.appendingPathComponent("-tmp-work-ideas", isDirectory: true)
    try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)

    func line(id: String, cwd: String) -> String {
        """
        {"type":"assistant","uuid":"u-\(id)","timestamp":"2026-08-01T14:20:00.000Z","sessionId":"session-anc","cwd":"\(cwd)","requestId":null,"message":{"id":"\(id)","model":"claude-sonnet-5","usage":{"input_tokens":1,"output_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}
        """
    }

    // A strict ancestor of the project (`/tmp/work` -> "-tmp-work") does NOT equal "-tmp-work-ideas",
    // and neither does the filesystem root, so neither may contribute a candidate.
    let onlyBadCwds = line(id: "msg_A1", cwd: "/tmp/work") + "\n" + line(id: "msg_A2", cwd: "/") + "\n"
    let badURL = projectDir.appendingPathComponent("bad.jsonl")
    try Data(onlyBadCwds.utf8).write(to: badURL)
    let bad = try TranscriptParser(root: root).parseFile(at: badURL, from: 0)
    #expect(Set(bad.events.map(\.projectDisplayName)) == ["tmp-work-ideas"],
            "a shared parent directory must never validate as this project's display name")

    // A deep descendant still resolves, because walking up reaches an exact whole-string match.
    let deep = line(id: "msg_A3", cwd: "/tmp/work/ideas/packages/api/src") + "\n"
    let deepURL = projectDir.appendingPathComponent("deep.jsonl")
    try Data(deep.utf8).write(to: deepURL)
    let deepResult = try TranscriptParser(root: root).parseFile(at: deepURL, from: 0)
    #expect(deepResult.events.first?.projectDisplayName == "ideas")
}

@Test func mostFrequentRoundTrippingBasenameWins() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("TranscriptParserTests-freq-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let projectDir = root.appendingPathComponent("-tmp-work-my-proj", isDirectory: true)
    try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)

    func line(cwd: String, id: String) -> String {
        """
        {"type":"assistant","uuid":"u-\(id)","timestamp":"2026-08-01T14:10:00.000Z","sessionId":"session-freq","cwd":"\(cwd)","requestId":"req-\(id)","message":{"id":"\(id)","model":"claude-sonnet-5","usage":{"input_tokens":1,"output_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}
        """
    }

    // Both "-" and "." collapse to "-" under the encoding, so
    // "/tmp/work/my-proj" and "/tmp/work/my.proj" both round-trip to the
    // same "-tmp-work-my-proj" directory name. "my-proj" appears twice,
    // "my.proj" once -> "my-proj" wins on frequency.
    let content = [
        line(cwd: "/tmp/work/my-proj", id: "msg_F1"),
        line(cwd: "/tmp/work/my-proj", id: "msg_F2"),
        line(cwd: "/tmp/work/my.proj", id: "msg_F3"),
    ].joined(separator: "\n") + "\n"
    let fileURL = projectDir.appendingPathComponent("session-freq.jsonl")
    try Data(content.utf8).write(to: fileURL)

    let result = try TranscriptParser(root: root).parseFile(at: fileURL, from: 0)
    #expect(result.events.count == 3)
    #expect(result.events.allSatisfy { $0.projectDisplayName == "my-proj" })
}

@Test func tiedRoundTrippingBasenamesTieBreakLexicographically() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("TranscriptParserTests-tie-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let projectDir = root.appendingPathComponent("-tmp-work-my-proj", isDirectory: true)
    try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)

    func line(cwd: String, id: String) -> String {
        """
        {"type":"assistant","uuid":"u-\(id)","timestamp":"2026-08-01T14:15:00.000Z","sessionId":"session-tie","cwd":"\(cwd)","requestId":"req-\(id)","message":{"id":"\(id)","model":"claude-sonnet-5","usage":{"input_tokens":1,"output_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}
        """
    }

    // Exactly one occurrence each of two basenames that both round-trip to
    // the same encoded directory name; lexicographically "my-proj" < "my.proj"
    // ('-' < '.' in ASCII), so it wins the tie.
    let content = [
        line(cwd: "/tmp/work/my.proj", id: "msg_T1"),
        line(cwd: "/tmp/work/my-proj", id: "msg_T2"),
    ].joined(separator: "\n") + "\n"
    let fileURL = projectDir.appendingPathComponent("session-tie.jsonl")
    try Data(content.utf8).write(to: fileURL)

    let result = try TranscriptParser(root: root).parseFile(at: fileURL, from: 0)
    #expect(result.events.count == 2)
    #expect(result.events.allSatisfy { $0.projectDisplayName == "my-proj" })
}

// MARK: - D2b/E12: longest-ancestor + case-insensitive round-trip

/// E12: a line's `cwd` can be a *subdirectory* of the actual project root
/// (e.g. a nested worktree or subproject), so the full `cwd` alone doesn't
/// round-trip. The longest ancestor that does must be accepted instead —
/// mirrors the real corpus case `-Volumes-SSD-Workspace-ideas` -> "ideas"
/// from a line whose `cwd` is `.../ideas/stitchlist`.
@Test func longestRoundTrippingAncestorIsAcceptedWhenFullCwdDoesNot() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("TranscriptParserTests-ancestor-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let projectDir = root.appendingPathComponent("-Volumes-SSD-Workspace-ideas", isDirectory: true)
    try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)

    // The full cwd re-encodes to "-Volumes-SSD-Workspace-ideas-stitchlist",
    // which does NOT match the encoded dir name; only its ancestor
    // "/Volumes/SSD/Workspace/ideas" round-trips.
    let line = """
    {"type":"assistant","uuid":"u1","timestamp":"2026-08-01T15:00:00.000Z","sessionId":"session-anc","cwd":"/Volumes/SSD/Workspace/ideas/stitchlist","requestId":"req-anc1","message":{"id":"msg_ANC1","model":"claude-sonnet-5","usage":{"input_tokens":1,"output_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}
    """
    let fileURL = projectDir.appendingPathComponent("session-anc.jsonl")
    try Data((line + "\n").utf8).write(to: fileURL)

    let result = try TranscriptParser(root: root).parseFile(at: fileURL, from: 0)
    let event = try #require(result.events.first)
    #expect(event.projectKey == "-Volumes-SSD-Workspace-ideas")
    #expect(event.projectDisplayName == "ideas")
}

/// E12: the round-trip comparison is case-insensitive (fixes lines like
/// `/volumes/ssd/workspace/...`), but the returned display name preserves
/// `cwd`'s own casing, never the encoded directory's.
@Test func caseInsensitiveRoundTripKeepsCwdsOwnCasing() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("TranscriptParserTests-case-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    // Encoded directory name uses upper-case "ESCA-PLATFORM"...
    let projectDir = root.appendingPathComponent("-Volumes-SSD-Workspace-ESCA-PLATFORM", isDirectory: true)
    try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)

    // ...but this line's cwd is entirely lower-case. It must still validate
    // (case-insensitive), and the accepted basename must keep its own
    // (lower-case) casing rather than the directory's upper-case form.
    let line = """
    {"type":"assistant","uuid":"u1","timestamp":"2026-08-01T15:05:00.000Z","sessionId":"session-case","cwd":"/volumes/ssd/workspace/esca-platform","requestId":"req-case1","message":{"id":"msg_CASE1","model":"claude-sonnet-5","usage":{"input_tokens":1,"output_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}
    """
    let fileURL = projectDir.appendingPathComponent("session-case.jsonl")
    try Data((line + "\n").utf8).write(to: fileURL)

    let result = try TranscriptParser(root: root).parseFile(at: fileURL, from: 0)
    let event = try #require(result.events.first)
    #expect(event.projectKey == "-Volumes-SSD-Workspace-ESCA-PLATFORM")
    #expect(event.projectDisplayName == "esca-platform", "casing must come from cwd, not the encoded directory name")
}

// MARK: - parseAll tolerates unreadable files

/// A dangling symlink (real corpus: `subagents/agent-*.jsonl` pointing into a
/// deleted session dir) must not abort the whole run — it's skipped and
/// counted, per the advisor-approved tolerance already in `UsageStore`
/// ("per-file open failure -> skip this round") and D10 ("IO errors skip the
/// file"). `parseFile` itself still throws for this file if called directly;
/// only `parseAll` is tolerant.
@Test func parseAllSkipsADanglingSymlinkAndCountsIt() async throws {
    func assistantLine(id: String) -> String {
        """
        {"type":"assistant","uuid":"u-\(id)","timestamp":"2026-08-01T16:00:00.000Z","sessionId":"session-good","cwd":"/tmp/proj-broken","requestId":"req-\(id)","message":{"id":"\(id)","model":"claude-sonnet-5","usage":{"input_tokens":1,"output_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}
        """
    }

    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("TranscriptParserTests-dangling-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let projectDir = root.appendingPathComponent("-tmp-proj-broken", isDirectory: true)
    try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)

    // A good file that must still be parsed despite its sibling's failure.
    try Data((assistantLine(id: "msg_GOOD1") + "\n").utf8)
        .write(to: projectDir.appendingPathComponent("good.jsonl"))

    // A symlink whose target directory gets removed out from under it,
    // mirroring the real corpus's dangling `subagents/agent-*.jsonl` link
    // into a deleted session dir.
    let vanishingTargetDir = root.appendingPathComponent("vanishing-session", isDirectory: true)
    try FileManager.default.createDirectory(at: vanishingTargetDir, withIntermediateDirectories: true)
    let vanishingTarget = vanishingTargetDir.appendingPathComponent("agent-x.jsonl")
    try Data("placeholder".utf8).write(to: vanishingTarget)
    let danglingLink = projectDir.appendingPathComponent("dangling.jsonl")
    try FileManager.default.createSymbolicLink(at: danglingLink, withDestinationURL: vanishingTarget)
    try FileManager.default.removeItem(at: vanishingTargetDir) // now dangling

    let (events, counters) = try await TranscriptParser(root: root).parseAll()

    #expect(counters.filesScanned == 2, "both the good file and the dangling symlink were attempted")
    #expect(counters.unreadableFiles == 1)
    #expect(
        events.map(\.messageId) == ["msg_GOOD1"],
        "the good file's events must survive its sibling's failure, and parseAll must not throw"
    )
}

/// Same class of failure as a dangling symlink (an `open`/`read` that fails),
/// so it must be tolerated the same way.
@Test func parseAllSkipsAPermissionDeniedFileAndCountsIt() async throws {
    func assistantLine(id: String) -> String {
        """
        {"type":"assistant","uuid":"u-\(id)","timestamp":"2026-08-01T16:05:00.000Z","sessionId":"session-good2","cwd":"/tmp/proj-noperm","requestId":"req-\(id)","message":{"id":"\(id)","model":"claude-sonnet-5","usage":{"input_tokens":1,"output_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}
        """
    }

    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("TranscriptParserTests-noperm-\(UUID().uuidString)", isDirectory: true)
    let projectDir = root.appendingPathComponent("-tmp-proj-noperm", isDirectory: true)
    try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)

    try Data((assistantLine(id: "msg_GOOD2") + "\n").utf8)
        .write(to: projectDir.appendingPathComponent("good.jsonl"))

    let noPermURL = projectDir.appendingPathComponent("noperm.jsonl")
    try Data((assistantLine(id: "msg_NOPERM1") + "\n").utf8).write(to: noPermURL)
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: noPermURL.path)
    defer {
        // Restore perms before cleanup — removing a tree containing a
        // chmod-000 file from underneath its own owner still works on
        // macOS, but this keeps the teardown robust regardless.
        try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: noPermURL.path)
        try? FileManager.default.removeItem(at: root)
    }

    let (events, counters) = try await TranscriptParser(root: root).parseAll()

    #expect(counters.filesScanned == 2)
    #expect(counters.unreadableFiles == 1)
    #expect(events.map(\.messageId) == ["msg_GOOD2"])
}
