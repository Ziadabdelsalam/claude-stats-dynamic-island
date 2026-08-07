import Darwin
import Foundation
import Observation

/// Publishes a live `RollupSnapshot` built from `~/.claude/projects`,
/// keeping it fresh via `TranscriptWatcher` (D4). Parsing/aggregation run off
/// the main thread; only the final published state hops back to `@MainActor`.
///
/// **Incremental contract (D7, binding; extended by E14).** Per-file state
/// is `(identity, size, mtime, offset)`, where `identity` is the file's
/// `(device, inode)` pair — the moral equivalent of
/// `URLResourceValues.fileResourceIdentifier`, cheaper to compare. On every
/// refresh, per file on disk:
/// - not seen before -> parse from offset 0 ("new file");
/// - `identity` changed from what was last stored -> the path now refers to
///   a *different* file (E14: atomic-rename replacement, e.g. a fresh file
///   swapped in under the same name) even if `size`/`mtime` happen to
///   coincide with the old file's — discard its events and re-parse from 0,
///   unconditionally, before even looking at size/mtime;
/// - `identity` unchanged and `size`/`mtime` both unchanged -> nothing to do;
/// - `identity` unchanged, `size` grew and `mtime` did not regress -> a
///   plain append; `parseFile(at:from: storedOffset)` picks up only the
///   new, complete lines;
/// - anything else -> the file shrank (which covers D7's `size < storedOffset`
///   truncation, since `offset <= size` always), its `mtime` regressed, or it
///   was rewritten in place at the same length. In every one of those cases the
///   bytes before `storedOffset` may no longer be the bytes we parsed, so the
///   file's events are discarded and it is re-parsed from 0.
/// Files present in the store but no longer on disk are dropped entirely.
/// A per-file open failure (transient race with Claude Code rewriting a
/// file) skips that file for this round only — its previous events and
/// state are left untouched, never blanked — and is recorded in `lastError`
/// for that round.
///
/// The store holds `[filePath: [UsageEvent]]` and re-runs `Aggregator.rollup`
/// over the full concatenation on every change. It deliberately does NOT
/// maintain an incremental global-dedup set: removing entries from a shared
/// dedup set on re-parse is unsound, and re-aggregating ~25k events is
/// milliseconds, so there is nothing to optimize.
///
/// **Selection + attention (D9/D10, T12).** `selectedProjectKey` is a
/// transient, settable, observable pin (never persisted); `effectiveProjectKey`
/// resolves it against the live snapshot, falling back to auto-follow
/// (`activeProjectKey`) whenever the pin doesn't resolve — see its doc
/// comment. `pendingAttention` is recomputed on every refresh inside the
/// same detached task that reparses transcripts (the detector's own mtime
/// pre-filter keeps it cheap — measured 0.09s corpus-wide, T11), plus a
/// one-shot expiry timer that re-runs detection only (no parse) so a nudge
/// still clears on schedule even without a further filesystem event.
@MainActor
@Observable
public final class UsageStore {
    public private(set) var snapshot: RollupSnapshot?
    public private(set) var isLoading = false
    public private(set) var lastRefresh: Date?
    public private(set) var lastError: Error?
    /// Sessions currently waiting on user input, most recent first (D10).
    /// Refreshed alongside `snapshot` on every parse, and again by the
    /// one-shot expiry timer described on the type.
    public private(set) var pendingAttention: [AttentionState] = []
    /// Latest genuine user prompt per project (D13): "what is this project
    /// currently working on", from `AttentionDetector.latestUserPrompts`.
    public private(set) var currentTaskByProject: [String: String] = [:]
    /// Recent sessions grouped per project (D14), newest first within each —
    /// a project can run several sessions at once and the picker shows them.
    public private(set) var sessionStatusesByProject: [String: [SessionStatus]] = [:]
    /// Projects with at least one session actively working in the last few
    /// minutes — the picker's "active now" dot.
    public private(set) var activeProjectKeys: Set<String> = []
    /// Manual project pin (D9): `nil` means "follow `activeProjectKey`".
    /// Transient — never persisted across launches. Set directly by UI
    /// callers (e.g. the header picker / attention-nudge tap); read
    /// `effectiveProjectKey`/`effectiveScopedRollup` for the resolved value.
    public var selectedProjectKey: String?

    private let root: URL
    private let parser: TranscriptParser
    private let pricing: PricingTable
    private let sessionGapMinutes: Int
    private let calendar: Calendar
    private let now: @Sendable () -> Date
    private let attentionDetector: AttentionDetector

    private var fileStates: [String: FileState] = [:]
    private var eventsByFile: [String: [UsageEvent]] = [:]

    private var watcher: TranscriptWatcher?
    private var refreshInFlight = false
    private var refreshQueued = false
    /// D10's one-shot expiry timer; re-armed from scratch on every refresh
    /// (full or expiry-triggered) — see `rearmAttentionExpiryTimer`.
    private var attentionExpiryTask: Task<Void, Never>?

    public init(
        root: URL = TranscriptParser.defaultRoot,
        pricing: PricingTable = .default,
        sessionGapMinutes: Int = 30,
        calendar: Calendar = .current,
        now: @escaping @Sendable () -> Date = { Date() },
        attentionDetector: AttentionDetector? = nil
    ) {
        self.root = root
        self.parser = TranscriptParser(root: root)
        self.pricing = pricing
        self.sessionGapMinutes = sessionGapMinutes
        self.calendar = calendar
        self.now = now
        self.attentionDetector = attentionDetector ?? AttentionDetector(root: root)
    }

    // No explicit deinit: releasing `watcher` here (implicitly, when the
    // store deallocates) drops the last strong reference to it, which runs
    // `TranscriptWatcher.deinit` -> `stopStream()` and tears the FSEvents
    // stream down cleanly. The expiry timer (`attentionExpiryTask`) is a
    // plain `Task` captured with `[weak self]`; dropping the store's last
    // reference doesn't cancel it, but a `deinit` can't touch a
    // main-actor-isolated stored property either — it is left to simply
    // wake up on schedule and no-op against its now-nil `weak self`, exactly
    // the same tolerance `rearmAttentionExpiryTimer` already relies on.

    /// Effective project scope (D9): the manual pin if it still resolves
    /// against the live snapshot, otherwise auto-follow `activeProjectKey`.
    /// A pin stops resolving only when its project has *genuinely* left the
    /// snapshot — per the incremental contract above, a project's events
    /// are dropped only when every one of its files is actually deleted
    /// from disk; a transient per-file read failure leaves previous events
    /// (and therefore the project) untouched. So falling back here is
    /// always the graceful "auto" behavior D9 asks for, and `selectedProjectKey`
    /// itself is deliberately never cleared by the store — if the same
    /// `projectKey` starts producing events again, the user's pin resumes
    /// working with no action needed.
    public var effectiveProjectKey: String? {
        if let selectedProjectKey, snapshot?.scopedByProject[selectedProjectKey] != nil {
            return selectedProjectKey
        }
        return snapshot?.activeProjectKey
    }

    /// The scoped rollup for `effectiveProjectKey`, or `nil` when nothing
    /// resolves (no snapshot yet, or no events at all) — callers fall back
    /// to the global `snapshot` totals in that case, per D9.
    public var effectiveScopedRollup: ProjectScopedRollup? {
        guard let key = effectiveProjectKey else { return nil }
        return snapshot?.scopedByProject[key]
    }

    /// The current task of the effective scope (D13): the latest genuine
    /// user prompt in the effective project's newest session, if any.
    public var effectiveCurrentTask: String? {
        guard let key = effectiveProjectKey else { return nil }
        return currentTaskByProject[key]
    }

    /// Starts the FSEvents watcher and performs the first load. Safe to call
    /// more than once; subsequent calls are no-ops while a watcher exists.
    public func start() {
        guard watcher == nil else { return }
        watcher = TranscriptWatcher(root: root) { [weak self] in
            // FSEvents callback arrives on the watcher's own queue; marshal
            // explicitly onto the main actor before touching store state.
            Task { @MainActor in
                self?.requestRefresh()
            }
        }
        refresh()
    }

    /// Manual refresh. Bypasses the watcher's 1.0s debounce (it doesn't go
    /// through the watcher at all) but still respects the single-flight
    /// invariant below, same as a watcher-triggered refresh.
    public func refresh() {
        requestRefresh()
    }

    /// At most one refresh in flight at a time; any refresh requested while
    /// one is running is coalesced into exactly one queued follow-up (D4).
    private func requestRefresh() {
        if refreshInFlight {
            refreshQueued = true
            return
        }
        refreshInFlight = true
        Task { await performRefresh() }
    }

    private func performRefresh() async {
        if snapshot == nil {
            isLoading = true
        }

        let previousStates = fileStates
        let previousEvents = eventsByFile
        let parser = self.parser
        let root = self.root
        let attentionDetector = self.attentionDetector
        // Captured once and reused for both the attention detector and
        // `Aggregator.rollup` below, so the whole round judges "now"
        // consistently instead of drifting by however long the parse took.
        let referenceNow = now()

        let result = await Task.detached(priority: .utility) {
            let parsed = await Self.parseIncremental(parser: parser, root: root, previousStates: previousStates, previousEvents: previousEvents)
            // T12/D10: detection rides along in the same detached task —
            // the detector's mtime pre-filter keeps this cheap (0.09s
            // corpus-wide, T11), so it never meaningfully slows a refresh.
            let attention = attentionDetector.pendingAttention(now: referenceNow)
            let tasks = attentionDetector.latestUserPrompts(now: referenceNow)
            let sessions = attentionDetector.sessionStatuses(now: referenceNow)
            return RefreshResult(parsed: parsed, pendingAttention: attention, currentTasks: tasks, sessionStatuses: sessions)
        }.value

        for path in result.parsed.removedPaths {
            fileStates.removeValue(forKey: path)
            eventsByFile.removeValue(forKey: path)
        }
        for (path, state) in result.parsed.updatedStates {
            fileStates[path] = state
        }
        for (path, events) in result.parsed.updatedEvents {
            eventsByFile[path] = events
        }
        // Reflects this round only: a file that failed to open last time and
        // parsed fine now must not leave a stale error showing in the UI.
        lastError = result.parsed.lastError

        pendingAttention = result.pendingAttention
        currentTaskByProject = result.currentTasks
        sessionStatusesByProject = result.sessionStatuses
        // "Active now" = actively working within the last 5 minutes; a session
        // merely sitting finished/waiting keeps its row but not the dot.
        activeProjectKeys = Set(result.sessionStatuses.compactMap { key, statuses in
            statuses.contains { $0.state == .working && referenceNow.timeIntervalSince($0.lastActivity) <= 300 }
                ? key : nil
        })
        // `allowSettleRescan`: a turn that just finished is quiet-gated by the
        // detector (`turnQuietSeconds`) and there may never be another
        // filesystem event to re-run detection — so every event-driven refresh
        // schedules one follow-up detection right after the quiet window.
        rearmAttentionExpiryTimer(referenceNow: referenceNow, allowSettleRescan: true)

        snapshot = Aggregator.rollup(
            events: eventsByFile.values.flatMap { $0 },
            now: referenceNow,
            calendar: calendar,
            pricing: pricing,
            sessionGapMinutes: sessionGapMinutes
        )
        lastRefresh = referenceNow
        isLoading = false

        refreshInFlight = false
        if refreshQueued {
            refreshQueued = false
            requestRefresh()
        }
    }

    // MARK: - Attention expiry timer (D10, nonisolated re-detection only)

    /// Cancels any outstanding timer and, iff `pendingAttention` is
    /// non-empty, arms a single new one at `min(pendingAttention.map(\.since))
    /// + staleAfterMinutes` — the instant the *earliest* pending item would
    /// naturally fall outside the detector's own staleness window. When it
    /// fires it re-runs detection only (no `TranscriptParser`, no
    /// `Aggregator.rollup`) so a nudge disappears on schedule even if no
    /// further filesystem event ever triggers a full refresh. Called at the
    /// end of every refresh, full or expiry-triggered, so the timer always
    /// reflects the current `pendingAttention`.
    private func rearmAttentionExpiryTimer(referenceNow: Date, allowSettleRescan: Bool = false) {
        attentionExpiryTask?.cancel()
        attentionExpiryTask = nil

        var candidateDelays: [TimeInterval] = []
        // Per-state windows: TurnCompleted expires on the short turn window,
        // everything else on the general staleness window.
        for state in pendingAttention {
            let minutes = state.toolName == AttentionDetector.turnCompletedToolName
                ? attentionDetector.turnStaleAfterMinutes
                : attentionDetector.staleAfterMinutes
            let expiry = state.since.addingTimeInterval(TimeInterval(minutes * 60))
            candidateDelays.append(expiry.timeIntervalSince(referenceNow))
        }
        if allowSettleRescan {
            // One follow-up pass just past the detector's quiet window, to pick
            // up a freshly finished turn. Only event-driven refreshes arm this
            // (the expiry path doesn't), so it can never self-perpetuate.
            candidateDelays.append(TimeInterval(attentionDetector.turnQuietSeconds) + 1)
        }
        guard let delay = candidateDelays.min() else { return }
        let detector = attentionDetector

        attentionExpiryTask = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            guard !Task.isCancelled, let self else { return }
            await self.reevaluateAttentionOnExpiry(detector: detector)
        }
    }

    /// Runs off-main, publishes on main — the expiry-timer counterpart to
    /// the detached detection above, but detection only: never touches
    /// `snapshot`, `lastRefresh`, or file/parse state.
    private func reevaluateAttentionOnExpiry(detector: AttentionDetector) async {
        let referenceNow = now()
        let updated = await Task.detached(priority: .utility) {
            detector.pendingAttention(now: referenceNow)
        }.value
        pendingAttention = updated
        rearmAttentionExpiryTimer(referenceNow: referenceNow)
    }

    // MARK: - Incremental parse (nonisolated: runs off the main actor)

    /// `(device, inode)` — E14's "equivalent identifier" to
    /// `fileResourceIdentifierKey`, cheap to fetch (same `stat(2)` call as
    /// size/mtime) and to compare.
    struct FileIdentity: Sendable, Equatable {
        var device: Int32
        var inode: UInt64
    }

    struct FileState: Sendable, Equatable {
        var identity: FileIdentity
        var size: UInt64
        var mtime: Date
        var offset: UInt64
    }

    private struct IncrementalResult: Sendable {
        var updatedStates: [String: FileState] = [:]
        var updatedEvents: [String: [UsageEvent]] = [:]
        var removedPaths: [String] = []
        var lastError: Error?
    }

    /// One refresh round's combined detached work: the incremental parse
    /// plus the T12/D10 attention detection that rides along with it.
    private struct RefreshResult: Sendable {
        var parsed: IncrementalResult
        var pendingAttention: [AttentionState]
        var currentTasks: [String: String]
        var sessionStatuses: [String: [SessionStatus]]
    }

    /// One file's decided work for this round: stat + the incremental-contract
    /// decision are made serially (cheap), the actual parse is not.
    private struct ParseJob: Sendable {
        let url: URL
        let path: String
        let identity: FileIdentity
        let size: UInt64
        let mtime: Date
        let startOffset: UInt64
        let isFullReparse: Bool
    }

    private enum ParseOutcome: Sendable {
        case parsed(path: String, state: FileState, events: [UsageEvent])
        case failed(Error)
    }

    /// Pure w.r.t. actor state: reads only its arguments, touches no store
    /// property. Safe to run detached from the main actor.
    nonisolated private static func parseIncremental(
        parser: TranscriptParser,
        root: URL,
        previousStates: [String: FileState],
        previousEvents: [String: [UsageEvent]]
    ) async -> IncrementalResult {
        var result = IncrementalResult()

        let currentFiles = TranscriptParser.enumerateTranscriptFiles(under: root)
        let currentPaths = Set(currentFiles.map(\.path))

        // Deleted files: no longer on disk -> drop their events entirely.
        for path in previousStates.keys where !currentPaths.contains(path) {
            result.removedPaths.append(path)
        }

        var jobs: [ParseJob] = []

        for url in currentFiles {
            let path = url.path
            guard let (identity, size, mtime) = statFile(at: path) else {
                // Transient race (file vanished/unreadable between the
                // enumerate and the stat) — skip this file this round,
                // previous state and events are left exactly as they were.
                result.lastError = TranscriptWatcherError.statFailed(path: path)
                continue
            }

            let previous = previousStates[path]
            let startOffset: UInt64
            let isFullReparse: Bool

            if let previous {
                if identity != previous.identity {
                    // E14: the path now refers to a different file (atomic
                    // rename replaced it) — size/mtime are not trustworthy
                    // signals here even if they happen to coincide with the
                    // old file's. Always re-parse from scratch.
                    startOffset = 0
                    isFullReparse = true
                } else if size == previous.size && mtime == previous.mtime {
                    // Unchanged since last refresh; nothing to do.
                    continue
                } else if size > previous.size && mtime >= previous.mtime {
                    // Grew, with mtime moving forward: a plain append. The
                    // bytes before `previous.offset` are unchanged, so resume
                    // from the last complete line.
                    startOffset = previous.offset
                    isFullReparse = false
                } else {
                    // Everything else means the bytes we already parsed are
                    // not necessarily the bytes on disk any more: the file
                    // shrank (D7's `size < offset` truncation is a strict
                    // subset of this, since `offset <= size` always), mtime
                    // regressed, or it was rewritten in place at exactly the
                    // same length. Discard this file's events and re-parse
                    // from scratch.
                    startOffset = 0
                    isFullReparse = true
                }
            } else {
                startOffset = 0
                isFullReparse = true
            }

            jobs.append(ParseJob(
                url: url,
                path: path,
                identity: identity,
                size: size,
                mtime: mtime,
                startOffset: startOffset,
                isFullReparse: isFullReparse
            ))
        }

        // Parse the decided jobs concurrently, bounded exactly like a cold
        // `parseAll` (D3). Each job is independent — its own file, its own
        // offset — and every result is keyed by path, so completion order
        // does not affect the outcome.
        let maxConcurrency = max(1, min(8, ProcessInfo.processInfo.activeProcessorCount))

        await withTaskGroup(of: ParseOutcome.self) { group in
            var iterator = jobs.makeIterator()
            var inFlight = 0

            func submitNext() {
                guard let job = iterator.next() else { return }
                inFlight += 1
                group.addTask {
                    do {
                        let parsed = try parser.parseFile(at: job.url, from: job.startOffset)
                        let events = job.isFullReparse
                            ? parsed.events
                            : (previousEvents[job.path] ?? []) + parsed.events
                        return .parsed(
                            path: job.path,
                            state: FileState(identity: job.identity, size: job.size, mtime: job.mtime, offset: parsed.endOffset),
                            events: events
                        )
                    } catch {
                        // Per-file open failure (e.g. Claude Code mid-rewrite
                        // of the file): skip this file this round, keep its
                        // previous events and state untouched — a transient
                        // race must never blank the stats.
                        return .failed(error)
                    }
                }
            }

            for _ in 0..<maxConcurrency {
                submitNext()
            }

            while inFlight > 0 {
                guard let outcome = await group.next() else { break }
                inFlight -= 1
                switch outcome {
                case let .parsed(path, state, events):
                    result.updatedStates[path] = state
                    result.updatedEvents[path] = events
                case let .failed(error):
                    result.lastError = error
                }
                submitNext()
            }
        }

        return result
    }

    /// A single `stat(2)` call gets us identity (E14), size, and mtime
    /// together — cheaper and simpler than `FileManager.attributesOfItem`
    /// plus a separate `URLResourceValues` fetch for the identifier.
    nonisolated private static func statFile(at path: String) -> (identity: FileIdentity, size: UInt64, mtime: Date)? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        let identity = FileIdentity(device: info.st_dev, inode: UInt64(info.st_ino))
        let seconds = TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000
        let mtime = Date(timeIntervalSince1970: seconds)
        return (identity, UInt64(info.st_size), mtime)
    }
}

enum TranscriptWatcherError: Error, Sendable {
    case statFailed(path: String)
}
