import Foundation

/// Snapshot of every rollup the UI needs, produced in one pass by
/// `Aggregator.rollup` (D6). Consumed verbatim by the store, the popover
/// views and the CLI — every sub-type below ships a public memberwise init
/// so those other targets can also build sample values for `#Preview`s.
public struct RollupSnapshot: Sendable {
    public struct Totals: Sendable {
        public var tokens: TokenCounts
        public var cost: Double
        public var eventCount: Int

        public init(tokens: TokenCounts, cost: Double, eventCount: Int) {
            self.tokens = tokens
            self.cost = cost
            self.eventCount = eventCount
        }
    }

    public var today: Totals
    public var last7Days: Totals
    public var last30Days: Totals
    public var allTime: Totals
    /// Sorted cost desc; ties broken by `projectKey` for determinism.
    public var byProject: [ProjectRollup]
    /// Sorted cost desc; ties broken by `model` for determinism.
    public var byModel: [ModelRollup]
    /// Dense 30 entries, oldest -> newest, zero-filled for days with no activity.
    public var byDay: [DayRollup]
    /// The current burst of activity as of `now`, or `nil` when idle (no
    /// event within `sessionGapMinutes` of `now`).
    public var session: SessionRollup?
    /// `projectDisplayName` of the single most recent event, or `nil` if empty.
    public var activeProject: String?
    public var unknownModels: Set<String>
    public var estimatedPricingModels: Set<String>
    /// Count of events dropped by the global dedup step (D2), across files.
    public var crossFileDuplicatesDropped: Int
    public var generatedAt: Date
    /// Per-project figures (D9), one entry per distinct `projectKey` seen in
    /// the deduped events. Selection is a dictionary lookup — never a recompute.
    public var scopedByProject: [String: ProjectScopedRollup]
    /// `projectKey` of the single most recent event, or `nil` if empty.
    /// `activeProject`'s display name always corresponds to this key.
    public var activeProjectKey: String?

    public init(
        today: Totals,
        last7Days: Totals,
        last30Days: Totals,
        allTime: Totals,
        byProject: [ProjectRollup],
        byModel: [ModelRollup],
        byDay: [DayRollup],
        session: SessionRollup?,
        activeProject: String?,
        unknownModels: Set<String>,
        estimatedPricingModels: Set<String>,
        crossFileDuplicatesDropped: Int,
        generatedAt: Date,
        scopedByProject: [String: ProjectScopedRollup] = [:],
        activeProjectKey: String? = nil
    ) {
        self.today = today
        self.last7Days = last7Days
        self.last30Days = last30Days
        self.allTime = allTime
        self.byProject = byProject
        self.byModel = byModel
        self.byDay = byDay
        self.session = session
        self.activeProject = activeProject
        self.unknownModels = unknownModels
        self.estimatedPricingModels = estimatedPricingModels
        self.crossFileDuplicatesDropped = crossFileDuplicatesDropped
        self.generatedAt = generatedAt
        self.scopedByProject = scopedByProject
        self.activeProjectKey = activeProjectKey
    }
}

/// A single project's figures, scoped the same way the global `RollupSnapshot`
/// is (D9): same 30-day dense window, same D6a session chaining but limited
/// to that project's own events, same cost-desc `byModel` ordering.
public struct ProjectScopedRollup: Sendable {
    public var projectKey: String
    public var displayName: String
    public var today: RollupSnapshot.Totals
    public var last7Days: RollupSnapshot.Totals
    public var last30Days: RollupSnapshot.Totals
    public var allTime: RollupSnapshot.Totals
    /// Dense 30 entries, oldest -> newest, zero-filled — same window as `RollupSnapshot.byDay`.
    public var byDay: [DayRollup]
    /// The current burst of activity as of `now`, chained over this
    /// project's events only (D6a) — `nil` when idle.
    public var session: SessionRollup?
    /// Sorted cost desc; ties broken by `model`, scoped to this project.
    public var byModel: [ModelRollup]
    /// Scope-correct ≈ (E9): only models estimated among this project's own events.
    public var estimatedPricingModels: Set<String>

    public init(
        projectKey: String,
        displayName: String,
        today: RollupSnapshot.Totals,
        last7Days: RollupSnapshot.Totals,
        last30Days: RollupSnapshot.Totals,
        allTime: RollupSnapshot.Totals,
        byDay: [DayRollup],
        session: SessionRollup?,
        byModel: [ModelRollup],
        estimatedPricingModels: Set<String>
    ) {
        self.projectKey = projectKey
        self.displayName = displayName
        self.today = today
        self.last7Days = last7Days
        self.last30Days = last30Days
        self.allTime = allTime
        self.byDay = byDay
        self.session = session
        self.byModel = byModel
        self.estimatedPricingModels = estimatedPricingModels
    }
}

public struct ProjectRollup: Sendable, Identifiable, Equatable {
    public var projectKey: String
    public var displayName: String
    public var tokens: TokenCounts
    public var cost: Double
    public var eventCount: Int
    public var id: String { projectKey }

    public init(projectKey: String, displayName: String, tokens: TokenCounts, cost: Double, eventCount: Int) {
        self.projectKey = projectKey
        self.displayName = displayName
        self.tokens = tokens
        self.cost = cost
        self.eventCount = eventCount
    }
}

public struct ModelRollup: Sendable, Identifiable, Equatable {
    public var model: String
    public var tokens: TokenCounts
    public var cost: Double
    public var eventCount: Int
    public var id: String { model }

    public init(model: String, tokens: TokenCounts, cost: Double, eventCount: Int) {
        self.model = model
        self.tokens = tokens
        self.cost = cost
        self.eventCount = eventCount
    }
}

public struct DayRollup: Sendable, Equatable {
    /// Start of day per the `Calendar` passed to `rollup`.
    public var day: Date
    public var tokens: TokenCounts
    public var cost: Double

    public init(day: Date, tokens: TokenCounts, cost: Double) {
        self.day = day
        self.tokens = tokens
        self.cost = cost
    }
}

public struct SessionRollup: Sendable, Equatable {
    public var start: Date
    public var end: Date
    public var tokens: TokenCounts
    public var cost: Double
    public var tokensPerMinute: Double
    public var dollarsPerHour: Double

    public init(start: Date, end: Date, tokens: TokenCounts, cost: Double, tokensPerMinute: Double, dollarsPerHour: Double) {
        self.start = start
        self.end = end
        self.tokens = tokens
        self.cost = cost
        self.tokensPerMinute = tokensPerMinute
        self.dollarsPerHour = dollarsPerHour
    }
}

/// Turns a flat, possibly cross-file-duplicated list of `UsageEvent`s into
/// the `RollupSnapshot` the rest of the app reads. Pure and deterministic:
/// no I/O, no `Date()`, no mutation of the injected `PricingTable` — `now`
/// and `calendar` are always supplied by the caller (D6).
public enum Aggregator {
    /// Dense 30-day window used for `byDay` and the `last7Days`/`last30Days`
    /// totals (today included, so 29 days back through today).
    private static let dayWindowCount = 30

    public static func rollup(
        events: [UsageEvent],
        now: Date,
        calendar: Calendar = .current,
        pricing: PricingTable = .default,
        sessionGapMinutes: Int = 30
    ) -> RollupSnapshot {
        // Step one (D2, mandatory): global dedup by `dedupKey` across every
        // file, before anything else is computed.
        let (deduped, crossFileDuplicatesDropped) = globalDedup(events)

        let today = calendar.startOfDay(for: now)
        let dayKeys: [Date] = (-(dayWindowCount - 1)...0).compactMap {
            calendar.date(byAdding: .day, value: $0, to: today)
        }

        var eventsByDay: [Date: [UsageEvent]] = [:]
        for event in deduped {
            let day = calendar.startOfDay(for: event.timestamp)
            eventsByDay[day, default: []].append(event)
        }

        let byDay: [DayRollup] = dayKeys.map { day in
            dayRollup(day: day, events: eventsByDay[day] ?? [], pricing: pricing)
        }

        let todayEvents = eventsByDay[today] ?? []
        let last7Events = dayKeys.suffix(7).flatMap { eventsByDay[$0] ?? [] }
        let last30Events = dayKeys.flatMap { eventsByDay[$0] ?? [] }

        let displayNames = resolveDisplayNames(deduped)
        let activeProjectKey = mostRecentProjectKey(deduped)

        return RollupSnapshot(
            today: totals(for: todayEvents, pricing: pricing),
            last7Days: totals(for: last7Events, pricing: pricing),
            last30Days: totals(for: last30Events, pricing: pricing),
            allTime: totals(for: deduped, pricing: pricing),
            byProject: groupByProject(deduped, displayNames: displayNames, pricing: pricing),
            byModel: groupByModel(deduped, pricing: pricing),
            byDay: byDay,
            session: buildSession(deduped, now: now, sessionGapMinutes: sessionGapMinutes, pricing: pricing),
            activeProject: activeProjectKey.flatMap { displayNames[$0] },
            unknownModels: modelIds(deduped, pricing: pricing, where: \.isUnknown),
            estimatedPricingModels: modelIds(deduped, pricing: pricing, where: \.isEstimated),
            crossFileDuplicatesDropped: crossFileDuplicatesDropped,
            generatedAt: now,
            scopedByProject: buildScopedRollups(
                deduped,
                dayKeys: dayKeys,
                today: today,
                calendar: calendar,
                now: now,
                sessionGapMinutes: sessionGapMinutes,
                pricing: pricing,
                displayNames: displayNames
            ),
            activeProjectKey: activeProjectKey
        )
    }

    // MARK: - Per-project scoping (D9)

    /// One `ProjectScopedRollup` per distinct `projectKey` among `deduped`,
    /// each computed the same way the global snapshot is but restricted to
    /// that project's own events — same dense 30-day window (`dayKeys`), same
    /// D6a session chaining, same cost-desc `byModel` ordering.
    private static func buildScopedRollups(
        _ deduped: [UsageEvent],
        dayKeys: [Date],
        today: Date,
        calendar: Calendar,
        now: Date,
        sessionGapMinutes: Int,
        pricing: PricingTable,
        displayNames: [String: String]
    ) -> [String: ProjectScopedRollup] {
        var eventsByProject: [String: [UsageEvent]] = [:]
        for event in deduped {
            eventsByProject[event.projectKey, default: []].append(event)
        }

        var result: [String: ProjectScopedRollup] = [:]
        result.reserveCapacity(eventsByProject.count)
        for (projectKey, projectEvents) in eventsByProject {
            var eventsByDay: [Date: [UsageEvent]] = [:]
            for event in projectEvents {
                let day = calendar.startOfDay(for: event.timestamp)
                eventsByDay[day, default: []].append(event)
            }

            let byDay: [DayRollup] = dayKeys.map { day in
                dayRollup(day: day, events: eventsByDay[day] ?? [], pricing: pricing)
            }
            let todayEvents = eventsByDay[today] ?? []
            let last7Events = dayKeys.suffix(7).flatMap { eventsByDay[$0] ?? [] }
            let last30Events = dayKeys.flatMap { eventsByDay[$0] ?? [] }

            result[projectKey] = ProjectScopedRollup(
                projectKey: projectKey,
                displayName: displayNames[projectKey] ?? projectKey,
                today: totals(for: todayEvents, pricing: pricing),
                last7Days: totals(for: last7Events, pricing: pricing),
                last30Days: totals(for: last30Events, pricing: pricing),
                allTime: totals(for: projectEvents, pricing: pricing),
                byDay: byDay,
                session: buildSession(projectEvents, now: now, sessionGapMinutes: sessionGapMinutes, pricing: pricing),
                byModel: groupByModel(projectEvents, pricing: pricing),
                estimatedPricingModels: modelIds(projectEvents, pricing: pricing, where: \.isEstimated)
            )
        }
        return result
    }

    // MARK: - Global dedup (D2)

    /// Winner among events sharing a `dedupKey`: earliest `timestamp`, tie
    /// broken by the lexicographically smallest `projectKey`. Every
    /// non-winning occurrence counts into `duplicatesDropped`, regardless of
    /// the order events happen to arrive in.
    ///
    /// The survivors come back sorted by `(timestamp, dedupKey)`. Dictionary
    /// iteration order is seeded per process, so returning `winners.values`
    /// raw would make every downstream `Double` sum order-dependent — costs
    /// then differ in the last ULP between runs on identical input, which in
    /// turn lets two equal-cost rows swap places in `byProject`/`byModel`
    /// instead of falling through to their deterministic key tie-break.
    private static func globalDedup(_ events: [UsageEvent]) -> (events: [UsageEvent], duplicatesDropped: Int) {
        var winners: [String: UsageEvent] = [:]
        winners.reserveCapacity(events.count)
        var duplicatesDropped = 0

        for event in events {
            guard let existing = winners[event.dedupKey] else {
                winners[event.dedupKey] = event
                continue
            }
            duplicatesDropped += 1
            let isEarlier = event.timestamp < existing.timestamp
            let isTieBreakWinner = event.timestamp == existing.timestamp && event.projectKey < existing.projectKey
            if isEarlier || isTieBreakWinner {
                winners[event.dedupKey] = event
            }
        }
        let ordered = winners.values.sorted {
            $0.timestamp != $1.timestamp ? $0.timestamp < $1.timestamp : $0.dedupKey < $1.dedupKey
        }
        return (ordered, duplicatesDropped)
    }

    // MARK: - Totals

    private static func totals(for events: [UsageEvent], pricing: PricingTable) -> RollupSnapshot.Totals {
        var tokens = TokenCounts.zero
        var cost = 0.0
        for event in events {
            tokens += event.tokens
            cost += pricing.cost(model: event.model, tokens: event.tokens)
        }
        return RollupSnapshot.Totals(tokens: tokens, cost: cost, eventCount: events.count)
    }

    private static func dayRollup(day: Date, events: [UsageEvent], pricing: PricingTable) -> DayRollup {
        var tokens = TokenCounts.zero
        var cost = 0.0
        for event in events {
            tokens += event.tokens
            cost += pricing.cost(model: event.model, tokens: event.tokens)
        }
        return DayRollup(day: day, tokens: tokens, cost: cost)
    }

    // MARK: - By project / by model

    private struct ProjectBucket {
        var tokens = TokenCounts.zero
        var cost = 0.0
        var eventCount = 0
    }

    private static func groupByProject(_ events: [UsageEvent], displayNames: [String: String], pricing: PricingTable) -> [ProjectRollup] {
        var buckets: [String: ProjectBucket] = [:]
        for event in events {
            var bucket = buckets[event.projectKey] ?? ProjectBucket()
            bucket.tokens += event.tokens
            bucket.cost += pricing.cost(model: event.model, tokens: event.tokens)
            bucket.eventCount += 1
            buckets[event.projectKey] = bucket
        }
        return buckets
            .map { key, bucket in
                // displayNames is populated from the very same key set, see resolveDisplayNames.
                ProjectRollup(projectKey: key, displayName: displayNames[key] ?? key, tokens: bucket.tokens, cost: bucket.cost, eventCount: bucket.eventCount)
            }
            .sorted { lhs, rhs in
                lhs.cost != rhs.cost ? lhs.cost > rhs.cost : lhs.projectKey < rhs.projectKey
            }
    }

    /// Per-file transcript parsing can disagree on `projectDisplayName` for
    /// the same `projectKey` (T3's resolution isn't globally consistent, and
    /// incremental re-parses can flip which file's label arrives first). To
    /// keep the label single-valued and deterministic regardless of event
    /// order, the winner per `projectKey` is the **most frequent**
    /// `projectDisplayName` among its events, tie broken by the
    /// lexicographically smallest name.
    ///
    /// One name is never a genuine human label: T3's per-file fallback
    /// (`projectKey` with its leading `-` stripped, e.g.
    /// `Volumes-SSD-Workspace-esca-platform`) fires whenever a mirrored file
    /// is dominated by another project's lines, and such files can outnumber
    /// the correctly labelled ones. That fallback string is only picked when
    /// it is the *only* candidate for the key — any other candidate beats it
    /// on frequency/tie-break regardless of raw vote count.
    private static func resolveDisplayNames(_ events: [UsageEvent]) -> [String: String] {
        var counts: [String: [String: Int]] = [:]
        for event in events {
            counts[event.projectKey, default: [:]][event.projectDisplayName, default: 0] += 1
        }
        var winners: [String: String] = [:]
        for (key, nameCounts) in counts {
            let fallback = key.hasPrefix("-") ? String(key.dropFirst()) : key
            let genuine = nameCounts.filter { $0.key != fallback }
            let pool = genuine.isEmpty ? nameCounts : genuine
            winners[key] = pool.min { lhs, rhs in
                lhs.value != rhs.value ? lhs.value > rhs.value : lhs.key < rhs.key
            }?.key
        }
        return winners
    }

    private struct ModelBucket {
        var tokens = TokenCounts.zero
        var cost = 0.0
        var eventCount = 0
    }

    private static func groupByModel(_ events: [UsageEvent], pricing: PricingTable) -> [ModelRollup] {
        var buckets: [String: ModelBucket] = [:]
        for event in events {
            var bucket = buckets[event.model] ?? ModelBucket()
            bucket.tokens += event.tokens
            bucket.cost += pricing.cost(model: event.model, tokens: event.tokens)
            bucket.eventCount += 1
            buckets[event.model] = bucket
        }
        return buckets
            .map { model, bucket in
                ModelRollup(model: model, tokens: bucket.tokens, cost: bucket.cost, eventCount: bucket.eventCount)
            }
            .sorted { lhs, rhs in
                lhs.cost != rhs.cost ? lhs.cost > rhs.cost : lhs.model < rhs.model
            }
    }

    // MARK: - Session

    /// The contiguous run of events ending at the most recent one, where
    /// every consecutive gap is <= `sessionGapMinutes`. `nil` when there are
    /// no events, or the most recent event is already further than
    /// `sessionGapMinutes` in the past relative to `now` (idle).
    private static func buildSession(
        _ events: [UsageEvent],
        now: Date,
        sessionGapMinutes: Int,
        pricing: PricingTable
    ) -> SessionRollup? {
        guard !events.isEmpty else { return nil }
        let sorted = events.sorted { $0.timestamp < $1.timestamp }
        let latest = sorted[sorted.count - 1]
        let gapSeconds = TimeInterval(sessionGapMinutes) * 60

        guard now.timeIntervalSince(latest.timestamp) <= gapSeconds else { return nil }

        var startIndex = sorted.count - 1
        while startIndex > 0 {
            let gap = sorted[startIndex].timestamp.timeIntervalSince(sorted[startIndex - 1].timestamp)
            guard gap <= gapSeconds else { break }
            startIndex -= 1
        }
        let chain = sorted[startIndex...]

        var tokens = TokenCounts.zero
        var cost = 0.0
        for event in chain {
            tokens += event.tokens
            cost += pricing.cost(model: event.model, tokens: event.tokens)
        }

        let start = chain.first!.timestamp
        let end = latest.timestamp
        let spanSeconds = end.timeIntervalSince(start)
        // Guard against divide-by-zero when the session is a single event
        // (span 0) — never NaN/Inf.
        let tokensPerMinute = spanSeconds > 0 ? Double(tokens.total) / (spanSeconds / 60) : 0
        let dollarsPerHour = spanSeconds > 0 ? cost / (spanSeconds / 3600) : 0

        return SessionRollup(start: start, end: end, tokens: tokens, cost: cost, tokensPerMinute: tokensPerMinute, dollarsPerHour: dollarsPerHour)
    }

    // MARK: - Active project

    /// `projectKey` of the single most recent event, tie broken by the
    /// lexicographically smallest key — `nil` when `events` is empty.
    /// `activeProject`'s display name is always `displayNames[activeProjectKey]`.
    private static func mostRecentProjectKey(_ events: [UsageEvent]) -> String? {
        guard let maxTimestamp = events.map(\.timestamp).max() else { return nil }
        return events.filter { $0.timestamp == maxTimestamp }.min { $0.projectKey < $1.projectKey }?.projectKey
    }

    // MARK: - Unknown / estimated models

    /// Collected straight from `PricingTable.lookup(model:)` — no shared
    /// mutable state, just a pure fold over each event's own lookup result.
    ///
    /// Per D1b, these sets hold the raw model id as observed in transcripts
    /// (e.g. `claude-haiku-4-5-20251001`), not the matched table key
    /// (`claude-haiku-4-5`).
    private static func modelIds(_ events: [UsageEvent], pricing: PricingTable, where predicate: (PricingTable.Lookup) -> Bool) -> Set<String> {
        var result: Set<String> = []
        for event in events {
            let lookup = pricing.lookup(model: event.model)
            if predicate(lookup) {
                result.insert(event.model) // raw model id, see doc comment above
            }
        }
        return result
    }
}
