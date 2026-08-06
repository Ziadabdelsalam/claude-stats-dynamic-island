import ClaudeStatsCore
import Foundation

// `ClaudeStatsCLI` — the ground-truth checker: parses the real transcripts
// with `TranscriptParser`, rolls them up with `Aggregator` (D6/D7 APIs
// consumed verbatim, no core-type changes), and prints the numbers the rest
// of the app is trusted to match. No third-party arg parsing — the flag set
// is tiny enough to hand-roll.

// MARK: - Flag parsing

struct CLIOptions {
    var summary = false
    var projects: Int? = nil
    var showProjects = false
    var models = false
    var stats = false
    var json = false
    var root: URL? = nil
}

func parseOptions(_ arguments: [String]) -> CLIOptions {
    var options = CLIOptions()
    var iterator = arguments.makeIterator()
    while let arg = iterator.next() {
        switch arg {
        case "--summary":
            options.summary = true
        case "--projects":
            options.showProjects = true
            // Optional trailing integer count; only consume it if it parses
            // as one, so a following flag isn't accidentally swallowed.
            if let next = peekNextArgument(&iterator), let n = Int(next) {
                // `Array.prefix(_:)` traps on a negative length, so a stray
                // `--projects -1` must be rejected here rather than crash.
                guard n >= 0 else {
                    fail("--projects count must be zero or greater, got \(n)")
                }
                options.projects = n
                _ = iterator.next()
            }
        case "--models":
            options.models = true
        case "--stats":
            options.stats = true
        case "--json":
            options.json = true
        case "--root":
            guard let path = iterator.next() else {
                fail("--root requires a path argument")
            }
            let expanded = (path as NSString).expandingTildeInPath
            // A mistyped `--root` would otherwise enumerate nothing and print
            // a confident all-zero report; say so instead.
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                fail("--root is not an existing directory: \(expanded)")
            }
            options.root = URL(fileURLWithPath: expanded)
        default:
            fail("unrecognized argument: \(arg)")
        }
    }
    return options
}

// `IteratorProtocol.next()` is mutating and consuming; to "peek" we pull the
// next element and hand it back via this tiny lookahead wrapper — used only
// for `--projects [n]`'s optional trailing count.
func peekNextArgument(_ iterator: inout Array<String>.Iterator) -> String? {
    var copy = iterator
    return copy.next()
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

// MARK: - Formatting (CLI-local; the App target's helpers aren't linked here)

/// `$1,234.56` always, thousands separators + two decimals, per D1c.
///
/// NumberFormatter's `.currency` style under `en_US_POSIX` inserts a stray
/// space after the symbol and drops grouping (POSIX has no real currency
/// convention to draw from — the same locale-quirk class T6 hit). Building
/// the string from `.decimal` style with explicit separators sidesteps that
/// entirely and is unaffected by the process locale.
private let decimalFormatter: NumberFormatter = {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.usesGroupingSeparator = true
    formatter.groupingSeparator = ","
    formatter.decimalSeparator = "."
    formatter.minimumFractionDigits = 2
    formatter.maximumFractionDigits = 2
    return formatter
}()

func formatCurrency(_ value: Double) -> String {
    "$" + (decimalFormatter.string(from: NSNumber(value: value)) ?? String(format: "%.2f", value))
}

/// D1c: any cost figure that includes estimated-rate spend gets the `≈`
/// prefix; `estimated` is true whenever the underlying rollup touched an
/// `estimatedPricingModels` entry.
func formatCost(_ value: Double, estimated: Bool) -> String {
    let prefix = estimated ? "\u{2248}" : ""
    return prefix + formatCurrency(value)
}

/// Same POSIX quirk as above: `.decimal` under `en_US_POSIX` comes back with
/// `usesGroupingSeparator == false`, so without these two lines this formatter
/// would emit exactly `String(value)` and the counts would print ungrouped.
private let integerFormatter: NumberFormatter = {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.usesGroupingSeparator = true
    formatter.groupingSeparator = ","
    return formatter
}()

func formatInt(_ value: Int) -> String {
    integerFormatter.string(from: NSNumber(value: value)) ?? String(value)
}

// MARK: - JSON DTO (D6b: RollupSnapshot stays non-Codable; this CLI owns its
// own private Codable mirror of exactly what --json needs).

private struct TokenCountsDTO: Codable {
    var input: Int, output: Int, cacheWrite5m: Int, cacheWrite1h: Int, cacheRead: Int, total: Int

    init(_ tokens: TokenCounts) {
        input = tokens.input
        output = tokens.output
        cacheWrite5m = tokens.cacheWrite5m
        cacheWrite1h = tokens.cacheWrite1h
        cacheRead = tokens.cacheRead
        total = tokens.total
    }
}

private struct TotalsDTO: Codable {
    var tokens: TokenCountsDTO
    var cost: Double
    var eventCount: Int

    init(_ totals: RollupSnapshot.Totals) {
        tokens = TokenCountsDTO(totals.tokens)
        cost = totals.cost
        eventCount = totals.eventCount
    }
}

private struct ProjectRollupDTO: Codable {
    var projectKey: String, displayName: String, tokens: TokenCountsDTO, cost: Double, eventCount: Int

    init(_ rollup: ProjectRollup) {
        projectKey = rollup.projectKey
        displayName = rollup.displayName
        tokens = TokenCountsDTO(rollup.tokens)
        cost = rollup.cost
        eventCount = rollup.eventCount
    }
}

private struct ModelRollupDTO: Codable {
    var model: String, tokens: TokenCountsDTO, cost: Double, eventCount: Int

    init(_ rollup: ModelRollup) {
        model = rollup.model
        tokens = TokenCountsDTO(rollup.tokens)
        cost = rollup.cost
        eventCount = rollup.eventCount
    }
}

private struct ParseCountersDTO: Codable {
    var filesScanned: Int, linesRead: Int, eventsKept: Int, duplicatesDropped: Int, malformedLines: Int
    var crossFileDuplicatesDropped: Int

    init(_ counters: ParseCounters, crossFileDuplicatesDropped: Int) {
        filesScanned = counters.filesScanned
        linesRead = counters.linesRead
        eventsKept = counters.eventsKept
        duplicatesDropped = counters.duplicatesDropped
        malformedLines = counters.malformedLines
        self.crossFileDuplicatesDropped = crossFileDuplicatesDropped
    }
}

private struct SnapshotDTO: Codable {
    var today: TotalsDTO
    var last7Days: TotalsDTO
    var last30Days: TotalsDTO
    var allTime: TotalsDTO
    var byProject: [ProjectRollupDTO]
    var byModel: [ModelRollupDTO]
    var unknownModels: [String]
    var estimatedPricingModels: [String]
    var counters: ParseCountersDTO
    var generatedAt: Date

    init(snapshot: RollupSnapshot, counters: ParseCounters) {
        today = TotalsDTO(snapshot.today)
        last7Days = TotalsDTO(snapshot.last7Days)
        last30Days = TotalsDTO(snapshot.last30Days)
        allTime = TotalsDTO(snapshot.allTime)
        byProject = snapshot.byProject.map(ProjectRollupDTO.init)
        byModel = snapshot.byModel.map(ModelRollupDTO.init)
        unknownModels = snapshot.unknownModels.sorted()
        estimatedPricingModels = snapshot.estimatedPricingModels.sorted()
        self.counters = ParseCountersDTO(counters, crossFileDuplicatesDropped: snapshot.crossFileDuplicatesDropped)
        generatedAt = snapshot.generatedAt
    }
}

// MARK: - Text output

func printSummary(_ snapshot: RollupSnapshot) {
    let estimated = !snapshot.estimatedPricingModels.isEmpty
    print("Summary")
    print("  Today:    \(formatInt(snapshot.today.tokens.total)) tokens, \(formatCost(snapshot.today.cost, estimated: estimated)), \(formatInt(snapshot.today.eventCount)) events")
    print("  All-time: \(formatInt(snapshot.allTime.tokens.total)) tokens, \(formatCost(snapshot.allTime.cost, estimated: estimated)), \(formatInt(snapshot.allTime.eventCount)) events")
}

func printProjects(_ snapshot: RollupSnapshot, limit: Int?) {
    let estimated = !snapshot.estimatedPricingModels.isEmpty
    let rows = limit.map { Array(snapshot.byProject.prefix($0)) } ?? snapshot.byProject
    print("Projects (\(rows.count) of \(snapshot.byProject.count))")
    for row in rows {
        print("  \(row.displayName): \(formatInt(row.tokens.total)) tokens, \(formatCost(row.cost, estimated: estimated)), \(formatInt(row.eventCount)) events")
    }
}

func printModels(_ snapshot: RollupSnapshot) {
    print("Models")
    for row in snapshot.byModel {
        let isEstimated = snapshot.estimatedPricingModels.contains(row.model)
        print("  \(row.model): \(formatInt(row.tokens.total)) tokens, \(formatCost(row.cost, estimated: isEstimated)), \(formatInt(row.eventCount)) events")
    }
}

func printStats(_ snapshot: RollupSnapshot, counters: ParseCounters) {
    print("Stats")
    print("  filesScanned:              \(formatInt(counters.filesScanned))")
    print("  linesRead:                 \(formatInt(counters.linesRead))")
    print("  eventsKept:                \(formatInt(counters.eventsKept))")
    print("  duplicatesDropped:         \(formatInt(counters.duplicatesDropped))")
    print("  malformedLines:            \(formatInt(counters.malformedLines))")
    print("  crossFileDuplicatesDropped: \(formatInt(snapshot.crossFileDuplicatesDropped))")
    print("  unknownModels:             \(snapshot.unknownModels.sorted().joined(separator: ", "))")
    print("  estimatedPricingModels:    \(snapshot.estimatedPricingModels.sorted().joined(separator: ", "))")
}

// MARK: - Entry point
//
// This file is literally named `main.swift`, so it is its own implicit
// entry point — top-level code, not `@main` (the two are mutually
// exclusive). Top-level `await` is legal here per SE-0296.

let options = parseOptions(Array(CommandLine.arguments.dropFirst()))

let parser = options.root.map(TranscriptParser.init(root:)) ?? TranscriptParser()
let parsed: (events: [UsageEvent], counters: ParseCounters)
do {
    parsed = try await parser.parseAll()
} catch {
    fail("failed to parse transcripts: \(error)")
}

let snapshot = Aggregator.rollup(events: parsed.events, now: Date())

if options.json {
    let dto = SnapshotDTO(snapshot: snapshot, counters: parsed.counters)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    guard let data = try? encoder.encode(dto), let text = String(data: data, encoding: .utf8) else {
        fail("failed to encode JSON output")
    }
    print(text)
} else {
    var printedAnySection = false
    if options.summary {
        printSummary(snapshot)
        printedAnySection = true
    }
    if options.showProjects {
        if printedAnySection { print("") }
        printProjects(snapshot, limit: options.projects)
        printedAnySection = true
    }
    if options.models {
        if printedAnySection { print("") }
        printModels(snapshot)
        printedAnySection = true
    }
    if options.stats {
        if printedAnySection { print("") }
        printStats(snapshot, counters: parsed.counters)
        printedAnySection = true
    }
    if !printedAnySection {
        printSummary(snapshot)
    }
}
