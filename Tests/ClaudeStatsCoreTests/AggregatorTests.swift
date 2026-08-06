import Foundation
import Testing
@testable import ClaudeStatsCore

// MARK: - Fixture

/// A fixed, UTC Gregorian calendar so every test is deterministic regardless
/// of the machine's locale/timezone.
private let calendar: Calendar = {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    return cal
}()

private let fixtureNow: Date = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: "2026-03-15T18:00:00Z")!
}()

private let fixtureToday = calendar.startOfDay(for: fixtureNow)

/// `dayOffset` days from `fixtureToday`, at the given UTC hour/minute.
private func fixtureTime(_ dayOffset: Int, _ hour: Int, _ minute: Int = 0) -> Date {
    let day = calendar.date(byAdding: .day, value: dayOffset, to: fixtureToday)!
    return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)!
}

private func fixtureEvent(id: String, project: String, model: String, tokens: TokenCounts, at timestamp: Date) -> UsageEvent {
    UsageEvent(
        timestamp: timestamp,
        sessionId: "fixture-session",
        projectKey: project,
        projectDisplayName: project,
        model: model,
        tokens: tokens,
        messageId: id,
        requestId: nil
    )
}

private func almostEqual(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-6 }

// Today (day offset 0): a solo event well before the session, then a
// three-event burst with gaps <= the default 30 min session gap.
private let soloEarly = fixtureEvent(id: "solo-early", project: "proj-current", model: "claude-sonnet-5", tokens: TokenCounts(input: 200_000, output: 50_000, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0), at: fixtureTime(0, 9, 0))
private let sess1 = fixtureEvent(id: "sess-1", project: "proj-current", model: "claude-sonnet-5", tokens: TokenCounts(input: 100_000, output: 20_000, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0), at: fixtureTime(0, 17, 0))
private let sess2 = fixtureEvent(id: "sess-2", project: "proj-current", model: "claude-haiku-4-5", tokens: TokenCounts(input: 80_000, output: 10_000, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0), at: fixtureTime(0, 17, 20))
private let sess3 = fixtureEvent(id: "sess-3", project: "proj-current", model: "claude-sonnet-5", tokens: TokenCounts(input: 60_000, output: 5_000, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0), at: fixtureTime(0, 17, 45))

// Day offset -6: the oldest day inside the last-7-day window.
private let week1 = fixtureEvent(id: "week-1", project: "proj-week", model: "claude-opus-4-8", tokens: TokenCounts(input: 10_000, output: 2_000, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0), at: fixtureTime(-6, 12))

// Day offset -20: two cross-file dedup groups (D2). Group 1 has an exact
// timestamp tie broken by the lexicographically smallest projectKey.
private let dup1Loser1 = fixtureEvent(id: "dup-msg-1", project: "zzz-project", model: "claude-sonnet-5", tokens: TokenCounts(input: 1_000, output: 0, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0), at: fixtureTime(-20, 10, 5))
private let dup1Loser2 = fixtureEvent(id: "dup-msg-1", project: "bbb-project", model: "claude-sonnet-5", tokens: TokenCounts(input: 2_000, output: 0, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0), at: fixtureTime(-20, 10, 0))
private let dup1Winner = fixtureEvent(id: "dup-msg-1", project: "aaa-project", model: "claude-sonnet-5", tokens: TokenCounts(input: 3_000, output: 0, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0), at: fixtureTime(-20, 10, 0))
private let dup2Winner = fixtureEvent(id: "dup-msg-2", project: "proj-e", model: "claude-haiku-4-5", tokens: TokenCounts(input: 500, output: 0, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0), at: fixtureTime(-20, 9, 0))
private let dup2Loser = fixtureEvent(id: "dup-msg-2", project: "proj-f", model: "claude-haiku-4-5", tokens: TokenCounts(input: 700, output: 0, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0), at: fixtureTime(-20, 9, 30))

// Day offset -25: an unknown model and a dated, estimated-rate model.
private let unknownModelEvent = fixtureEvent(id: "unknown-1", project: "proj-misc", model: "claude-brand-new-9", tokens: TokenCounts(input: 1_000, output: 1_000, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0), at: fixtureTime(-25, 12, 0))
private let estimatedModelEvent = fixtureEvent(id: "estimated-1", project: "proj-misc", model: "claude-fable-5-20260101", tokens: TokenCounts(input: 1_000, output: 1_000, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0), at: fixtureTime(-25, 12, 30))

// Day offset -29: the oldest day still inside the dense 30-day window.
private let boundaryEvent = fixtureEvent(id: "boundary-1", project: "proj-old-window", model: "claude-haiku-4-5", tokens: TokenCounts(input: 5_000, output: 1_000, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0), at: fixtureTime(-29, 12))

// Day offset -30: one day older than the window — allTime only.
private let outsideWindowEvent = fixtureEvent(id: "outside-1", project: "proj-outside", model: "claude-sonnet-5", tokens: TokenCounts(input: 999_999, output: 1, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0), at: fixtureTime(-30, 12))

private let allFixtureEvents: [UsageEvent] = [
    soloEarly, sess1, sess2, sess3, week1,
    dup1Loser1, dup1Loser2, dup1Winner,
    dup2Winner, dup2Loser,
    unknownModelEvent, estimatedModelEvent,
    boundaryEvent, outsideWindowEvent,
]

private func fixtureSnapshot() -> RollupSnapshot {
    Aggregator.rollup(events: allFixtureEvents, now: fixtureNow, calendar: calendar, pricing: .default)
}

// MARK: - Global dedup (D2)

@Test func globalDedupPicksEarliestTimestampTieBreakingOnProjectKey() {
    let snapshot = fixtureSnapshot()

    // 3 lines -> 1 winner (2 dropped), 2 lines -> 1 winner (1 dropped).
    #expect(snapshot.crossFileDuplicatesDropped == 3)

    // dup-msg-1: "aaa-project" and "bbb-project" tie on the earliest
    // timestamp; "aaa-project" wins lexicographically. "zzz-project" is
    // strictly later and loses regardless of its projectKey.
    #expect(snapshot.byProject.first { $0.projectKey == "aaa-project" }?.tokens.input == 3_000)
    #expect(snapshot.byProject.first { $0.projectKey == "bbb-project" } == nil)
    #expect(snapshot.byProject.first { $0.projectKey == "zzz-project" } == nil)

    // dup-msg-2: no tie, earliest timestamp wins outright.
    #expect(snapshot.byProject.first { $0.projectKey == "proj-e" }?.tokens.input == 500)
    #expect(snapshot.byProject.first { $0.projectKey == "proj-f" } == nil)
}

/// The whole snapshot must be byte-identical whatever order the events arrive
/// in — the dedup step hands survivors to the sums in a fixed order, so the
/// `Double` totals cannot drift by a ULP and flip a cost-desc tie.
@Test func snapshotIsIdenticalUnderShuffledInput() {
    func fingerprint(_ s: RollupSnapshot) -> String {
        [
            "\(s.crossFileDuplicatesDropped)",
            "\(s.allTime.cost)|\(s.today.cost)|\(s.last7Days.cost)|\(s.last30Days.cost)",
            s.activeProject ?? "nil",
            s.byProject.map { "\($0.projectKey)=\($0.cost)" }.joined(separator: ","),
            s.byModel.map { "\($0.model)=\($0.cost)" }.joined(separator: ","),
            s.byDay.map { "\($0.day.timeIntervalSince1970)=\($0.cost)" }.joined(separator: ","),
            "\(s.session?.tokensPerMinute ?? -1)|\(s.session?.dollarsPerHour ?? -1)",
        ].joined(separator: "//")
    }

    let reference = fingerprint(fixtureSnapshot())
    for _ in 0..<50 {
        let shuffled = Aggregator.rollup(events: allFixtureEvents.shuffled(), now: fixtureNow, calendar: calendar, pricing: .default)
        #expect(fingerprint(shuffled) == reference)
    }
}

// MARK: - Totals

@Test func totalsRollUpTodayLast7Last30AndAllTime() {
    let snapshot = fixtureSnapshot()

    let todayEvents = [soloEarly, sess1, sess2, sess3]
    let last7Events = todayEvents + [week1]
    let last30Events = last7Events + [dup1Winner, dup2Winner, unknownModelEvent, estimatedModelEvent, boundaryEvent]
    let allTimeEvents = last30Events + [outsideWindowEvent]

    func expectedTokens(_ events: [UsageEvent]) -> TokenCounts { events.reduce(.zero) { $0 + $1.tokens } }
    func expectedCost(_ events: [UsageEvent]) -> Double { events.reduce(0.0) { $0 + PricingTable.default.cost(model: $1.model, tokens: $1.tokens) } }

    #expect(snapshot.today.eventCount == todayEvents.count)
    #expect(snapshot.today.tokens == expectedTokens(todayEvents))
    #expect(almostEqual(snapshot.today.cost, expectedCost(todayEvents)))

    #expect(snapshot.last7Days.eventCount == last7Events.count)
    #expect(snapshot.last7Days.tokens == expectedTokens(last7Events))
    #expect(almostEqual(snapshot.last7Days.cost, expectedCost(last7Events)))

    #expect(snapshot.last30Days.eventCount == last30Events.count)
    #expect(snapshot.last30Days.tokens == expectedTokens(last30Events))
    #expect(almostEqual(snapshot.last30Days.cost, expectedCost(last30Events)))

    // allTime must include outsideWindowEvent (day -30) even though it is
    // outside the dense 30-day window used by byDay/last30Days.
    #expect(snapshot.allTime.eventCount == allTimeEvents.count)
    #expect(snapshot.allTime.tokens == expectedTokens(allTimeEvents))
    #expect(almostEqual(snapshot.allTime.cost, expectedCost(allTimeEvents)))
}

/// `today` is the calendar day of `now`, not a trailing 24 hours: an event
/// 30 minutes before midnight is yesterday even though it is well inside the
/// last 24h from `now`.
@Test func todayIsTheCalendarDayOfNowNotATrailing24Hours() {
    let justAfterMidnight = fixtureEvent(id: "t-early", project: "proj-day", model: "claude-sonnet-5", tokens: TokenCounts(input: 1_000, output: 0, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0), at: fixtureTime(0, 0, 30))
    let justBeforeMidnight = fixtureEvent(id: "t-late", project: "proj-day", model: "claude-sonnet-5", tokens: TokenCounts(input: 500_000, output: 0, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0), at: fixtureTime(-1, 23, 30))

    let snapshot = Aggregator.rollup(events: [justAfterMidnight, justBeforeMidnight], now: fixtureNow, calendar: calendar, pricing: .default)

    #expect(snapshot.today.eventCount == 1)
    #expect(snapshot.today.tokens == justAfterMidnight.tokens)
    #expect(snapshot.last7Days.eventCount == 2)
    #expect(snapshot.allTime.eventCount == 2)
}

// MARK: - byDay zero-fill

@Test func byDayIsDenseThirtyEntriesOldestToNewestZeroFilled() {
    let snapshot = fixtureSnapshot()

    #expect(snapshot.byDay.count == 30)
    #expect(snapshot.byDay.first?.day == calendar.date(byAdding: .day, value: -29, to: fixtureToday)!)
    #expect(snapshot.byDay.last?.day == fixtureToday)
    for i in 1..<snapshot.byDay.count {
        #expect(snapshot.byDay[i - 1].day < snapshot.byDay[i].day)
    }

    // A gap day with no fixture events at all must still be present, zeroed.
    let gapDay = calendar.date(byAdding: .day, value: -15, to: fixtureToday)!
    let gapEntry = snapshot.byDay.first { $0.day == gapDay }
    #expect(gapEntry != nil)
    #expect(gapEntry?.tokens == .zero)
    #expect(gapEntry?.cost == 0)

    // day -20 must reflect only the two dedup winners, never their losers.
    let dedupDay = calendar.date(byAdding: .day, value: -20, to: fixtureToday)!
    let dedupEntry = snapshot.byDay.first { $0.day == dedupDay }
    #expect(dedupEntry?.tokens == dup1Winner.tokens + dup2Winner.tokens)

    // day -30 (outsideWindowEvent) is one day older than the window and must
    // not appear in the dense series at all.
    let outsideDay = calendar.date(byAdding: .day, value: -30, to: fixtureToday)!
    #expect(snapshot.byDay.first { $0.day == outsideDay } == nil)
}

// MARK: - byProject / byModel

@Test func byProjectAndByModelGroupDedupedEventsAndSortByCostDescending() {
    let snapshot = fixtureSnapshot()

    let current = snapshot.byProject.first { $0.projectKey == "proj-current" }
    #expect(current != nil)
    #expect(current?.eventCount == 4)
    #expect(current?.tokens == [soloEarly, sess1, sess2, sess3].reduce(.zero) { $0 + $1.tokens })

    for i in 1..<snapshot.byProject.count {
        #expect(snapshot.byProject[i - 1].cost >= snapshot.byProject[i].cost)
    }
    for i in 1..<snapshot.byModel.count {
        #expect(snapshot.byModel[i - 1].cost >= snapshot.byModel[i].cost)
    }

    // 5 distinct models across the 11 deduped events.
    #expect(snapshot.byModel.count == 5)
    #expect(snapshot.byModel.reduce(0) { $0 + $1.eventCount } == 11)
}

/// T3's per-file `projectDisplayName` resolution can disagree across files
/// for the same `projectKey`. `byProject` (and `activeProject`, which must
/// report the same winner) resolve to the most frequent label, tie-broken
/// lexicographically, so the result never depends on event order.
@Test func projectDisplayNameIsTheMostFrequentLabelTieBreakingLexicographically() {
    let now = fixtureTime(0, 12, 0)
    func event(id: String, displayName: String) -> UsageEvent {
        UsageEvent(
            timestamp: now,
            sessionId: "fixture-session",
            projectKey: "shared-key",
            projectDisplayName: displayName,
            model: "claude-sonnet-5",
            tokens: TokenCounts(input: 100, output: 0, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0),
            messageId: id,
            requestId: nil
        )
    }

    // "ideas" (x2) outvotes "Volumes-SSD-Workspace-ideas" (x1).
    let majorityEvents = [
        event(id: "m-1", displayName: "ideas"),
        event(id: "m-2", displayName: "ideas"),
        event(id: "m-3", displayName: "Volumes-SSD-Workspace-ideas"),
    ]
    let majoritySnapshot = Aggregator.rollup(events: majorityEvents, now: now, calendar: calendar, pricing: .default)
    #expect(majoritySnapshot.byProject.first { $0.projectKey == "shared-key" }?.displayName == "ideas")
    #expect(majoritySnapshot.activeProject == "ideas")

    // A 1-1 tie is broken by the lexicographically smallest name.
    let tiedEvents = [
        event(id: "t-1", displayName: "zzz-name"),
        event(id: "t-2", displayName: "aaa-name"),
    ]
    let tiedSnapshot = Aggregator.rollup(events: tiedEvents, now: now, calendar: calendar, pricing: .default)
    #expect(tiedSnapshot.byProject.first { $0.projectKey == "shared-key" }?.displayName == "aaa-name")
    #expect(tiedSnapshot.activeProject == "aaa-name")
}

/// T3's per-file fallback label (`projectKey` minus its leading `-`) fires
/// when a mirrored file is dominated by another project's lines, and those
/// files can outnumber the correctly labelled ones. A genuine label must win
/// over the fallback even when it has fewer votes; the fallback only wins
/// when it is the sole candidate.
@Test func fallbackLabelLosesToAnyGenuineLabelButWinsWhenItIsTheOnlyCandidate() {
    let now = fixtureTime(0, 12, 0)
    let projectKey = "-Volumes-SSD-Workspace-esca-platform"
    let fallback = "Volumes-SSD-Workspace-esca-platform"
    func event(id: String, displayName: String) -> UsageEvent {
        UsageEvent(
            timestamp: now,
            sessionId: "fixture-session",
            projectKey: projectKey,
            projectDisplayName: displayName,
            model: "claude-sonnet-5",
            tokens: TokenCounts(input: 100, output: 0, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0),
            messageId: id,
            requestId: nil
        )
    }

    // Fallback outnumbers the genuine label 3-to-1, but must still lose.
    let outnumberedEvents = [
        event(id: "f-1", displayName: fallback),
        event(id: "f-2", displayName: fallback),
        event(id: "f-3", displayName: fallback),
        event(id: "g-1", displayName: "esca-platform"),
    ]
    let outnumberedSnapshot = Aggregator.rollup(events: outnumberedEvents, now: now, calendar: calendar, pricing: .default)
    #expect(outnumberedSnapshot.byProject.first { $0.projectKey == projectKey }?.displayName == "esca-platform")

    // No genuine label exists at all -> the fallback is the only candidate.
    let fallbackOnlyEvents = [
        event(id: "o-1", displayName: fallback),
        event(id: "o-2", displayName: fallback),
    ]
    let fallbackOnlySnapshot = Aggregator.rollup(events: fallbackOnlyEvents, now: now, calendar: calendar, pricing: .default)
    #expect(fallbackOnlySnapshot.byProject.first { $0.projectKey == projectKey }?.displayName == fallback)
}

// MARK: - Session

@Test func sessionChainsConsecutiveEventsWithinTheGapAndComputesRates() throws {
    let snapshot = fixtureSnapshot()
    let session = try #require(snapshot.session)

    // soloEarly (09:00) is > 30 min before sess1 (17:00) and must be excluded.
    #expect(session.start == sess1.timestamp)
    #expect(session.end == sess3.timestamp)

    let expectedTokens = sess1.tokens + sess2.tokens + sess3.tokens
    #expect(session.tokens == expectedTokens)

    // span = 17:45 - 17:00 = 45 minutes.
    #expect(session.tokensPerMinute == Double(expectedTokens.total) / 45.0)

    let expectedCost = PricingTable.default.cost(model: sess1.model, tokens: sess1.tokens)
        + PricingTable.default.cost(model: sess2.model, tokens: sess2.tokens)
        + PricingTable.default.cost(model: sess3.model, tokens: sess3.tokens)
    #expect(almostEqual(session.dollarsPerHour, expectedCost / 0.75))
}

@Test func singleEventSessionHasZeroSpanAndGuardsDivideByZero() throws {
    let now = fixtureTime(0, 12, 0)
    let onlyEvent = fixtureEvent(id: "solo-session", project: "proj-solo", model: "claude-sonnet-5", tokens: TokenCounts(input: 1_000, output: 500, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0), at: now)

    let snapshot = Aggregator.rollup(events: [onlyEvent], now: now, calendar: calendar, pricing: .default)
    let session = try #require(snapshot.session)

    #expect(session.start == session.end)
    #expect(session.tokensPerMinute == 0)
    #expect(session.dollarsPerHour == 0)
    #expect(session.tokensPerMinute.isFinite)
    #expect(session.dollarsPerHour.isFinite)
}

@Test func sessionIsNilWhenLatestActivityIsOlderThanTheSessionGap() {
    let now = fixtureTime(0, 12, 0)
    let staleEvent = fixtureEvent(id: "stale", project: "proj-stale", model: "claude-sonnet-5", tokens: TokenCounts(input: 1_000, output: 0, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0), at: fixtureTime(-1, 12, 0))

    let snapshot = Aggregator.rollup(events: [staleEvent], now: now, calendar: calendar, pricing: .default)

    #expect(snapshot.session == nil)
    #expect(snapshot.allTime.eventCount == 1)
    #expect(snapshot.activeProject == "proj-stale")
}

// MARK: - Active project

@Test func activeProjectIsTheDisplayNameOfTheMostRecentEvent() {
    let snapshot = fixtureSnapshot()
    #expect(snapshot.activeProject == "proj-current")
}

// MARK: - Unknown / estimated models

@Test func unknownAndEstimatedModelsAreCollectedByRawModelId() {
    let snapshot = fixtureSnapshot()

    #expect(snapshot.unknownModels == ["claude-brand-new-9"])
    // Per D1b: raw model id, not the matched table key ("claude-fable-5").
    #expect(snapshot.estimatedPricingModels == ["claude-fable-5-20260101"])
}

// MARK: - Empty input

@Test func emptyInputProducesAZeroedDenseSnapshot() {
    let snapshot = Aggregator.rollup(events: [], now: fixtureNow, calendar: calendar, pricing: .default)

    #expect(snapshot.allTime.eventCount == 0)
    #expect(snapshot.allTime.tokens == .zero)
    #expect(snapshot.allTime.cost == 0)
    #expect(snapshot.byDay.count == 30)
    #expect(snapshot.byDay.allSatisfy { $0.tokens == .zero && $0.cost == 0 })
    #expect(snapshot.session == nil)
    #expect(snapshot.activeProject == nil)
    #expect(snapshot.unknownModels.isEmpty)
    #expect(snapshot.estimatedPricingModels.isEmpty)
    #expect(snapshot.crossFileDuplicatesDropped == 0)
    #expect(snapshot.generatedAt == fixtureNow)
    #expect(snapshot.scopedByProject.isEmpty)
    #expect(snapshot.activeProjectKey == nil)
}

// MARK: - Per-project scoping (D9)

@Test func scopedTotalsMatchHandComputedValuesForAProject() {
    let snapshot = fixtureSnapshot()
    let scoped = snapshot.scopedByProject["proj-current"]
    #expect(scoped != nil)

    let todayEvents = [soloEarly, sess1, sess2, sess3]
    func expectedTokens(_ events: [UsageEvent]) -> TokenCounts { events.reduce(.zero) { $0 + $1.tokens } }
    func expectedCost(_ events: [UsageEvent]) -> Double { events.reduce(0.0) { $0 + PricingTable.default.cost(model: $1.model, tokens: $1.tokens) } }

    #expect(scoped?.today.eventCount == todayEvents.count)
    #expect(scoped?.today.tokens == expectedTokens(todayEvents))
    #expect(scoped.map { almostEqual($0.today.cost, expectedCost(todayEvents)) } == true)

    // proj-current has no events outside today in the fixture, so last7/last30/allTime match today.
    #expect(scoped?.last7Days.eventCount == todayEvents.count)
    #expect(scoped?.last30Days.eventCount == todayEvents.count)
    #expect(scoped?.allTime.eventCount == todayEvents.count)
    #expect(scoped?.allTime.tokens == expectedTokens(todayEvents))
    #expect(scoped.map { almostEqual($0.allTime.cost, expectedCost(todayEvents)) } == true)

    #expect(scoped?.displayName == "proj-current")
    #expect(scoped?.projectKey == "proj-current")
}

/// A project's D6a session chain must be built purely from its own events —
/// another project's event landing *inside* the gap window must not extend
/// or otherwise affect the chain.
@Test func aProjectsSessionChainsIndependentlyOfInterleavedOtherProjectEvents() throws {
    // Close enough to both projects' latest event to stay within the default
    // 30 min session gap.
    let now = fixtureTime(0, 9, 20)
    func event(id: String, project: String, hour: Int, minute: Int) -> UsageEvent {
        fixtureEvent(id: id, project: project, model: "claude-sonnet-5", tokens: TokenCounts(input: 1_000, output: 0, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0), at: fixtureTime(0, hour, minute))
    }

    // proj-a: 09:00, 09:10 (gap 10 min, chains). proj-b's lone event at
    // 09:05 is interleaved right in the middle of that gap, but must not
    // join proj-a's chain nor be affected by it.
    let a1 = event(id: "a-1", project: "proj-a", hour: 9, minute: 0)
    let b1 = event(id: "b-1", project: "proj-b", hour: 9, minute: 5)
    let a2 = event(id: "a-2", project: "proj-a", hour: 9, minute: 10)

    let snapshot = Aggregator.rollup(events: [a1, b1, a2], now: now, calendar: calendar, pricing: .default)

    let sessionA = try #require(snapshot.scopedByProject["proj-a"]?.session)
    #expect(sessionA.start == a1.timestamp)
    #expect(sessionA.end == a2.timestamp)
    #expect(sessionA.tokens == a1.tokens + a2.tokens)

    // proj-b's scoped session is the solo b1 event — it must not have
    // absorbed either of proj-a's events despite sitting between them.
    let sessionB = try #require(snapshot.scopedByProject["proj-b"]?.session)
    #expect(sessionB.start == b1.timestamp)
    #expect(sessionB.end == b1.timestamp)
    #expect(sessionB.tokens == b1.tokens)
}

@Test func scopedByDayIsDenseThirtyEntriesZeroFilledForThatProjectOnly() {
    let snapshot = fixtureSnapshot()
    let scoped = snapshot.scopedByProject["proj-current"]
    #expect(scoped != nil)
    #expect(scoped?.byDay.count == 30)
    #expect(scoped?.byDay.first?.day == calendar.date(byAdding: .day, value: -29, to: fixtureToday)!)
    #expect(scoped?.byDay.last?.day == fixtureToday)

    // proj-current only has events on day 0 in the fixture: every other day
    // in its own dense window must be zero-filled, even a day where *other*
    // projects (e.g. proj-week at day -6) have activity.
    let weekDay = calendar.date(byAdding: .day, value: -6, to: fixtureToday)!
    let weekEntry = scoped?.byDay.first { $0.day == weekDay }
    #expect(weekEntry?.tokens == .zero)
    #expect(weekEntry?.cost == 0)

    let todayEntry = scoped?.byDay.first { $0.day == fixtureToday }
    #expect(todayEntry?.tokens == [soloEarly, sess1, sess2, sess3].reduce(.zero) { $0 + $1.tokens })
}

@Test func scopedEstimatedPricingModelsContainsOnlyThatProjectsEstimatedModels() {
    let snapshot = fixtureSnapshot()

    // proj-misc has both the unknown and the estimated model in the fixture.
    let miscScoped = snapshot.scopedByProject["proj-misc"]
    #expect(miscScoped?.estimatedPricingModels == ["claude-fable-5-20260101"])

    // proj-current never touches an estimated-rate model.
    let currentScoped = snapshot.scopedByProject["proj-current"]
    #expect(currentScoped?.estimatedPricingModels.isEmpty == true)
}

@Test func activeProjectKeyTracksTheMostRecentEventsProjectKey() {
    let snapshot = fixtureSnapshot()
    #expect(snapshot.activeProjectKey == "proj-current")
    #expect(snapshot.activeProjectKey.flatMap { snapshot.scopedByProject[$0]?.displayName } == snapshot.activeProject)
}

@Test func scopedByProjectIsIdenticalUnderShuffledInput() {
    func fingerprint(_ s: RollupSnapshot) -> String {
        s.scopedByProject
            .sorted { $0.key < $1.key }
            .map { key, scoped in
                "\(key)=\(scoped.allTime.cost)|\(scoped.today.cost)|\(scoped.byModel.map { "\($0.model)=\($0.cost)" }.joined(separator: ","))|\(scoped.session?.dollarsPerHour ?? -1)"
            }
            .joined(separator: "//")
    }

    let reference = fingerprint(fixtureSnapshot())
    for _ in 0..<50 {
        let shuffled = Aggregator.rollup(events: allFixtureEvents.shuffled(), now: fixtureNow, calendar: calendar, pricing: .default)
        #expect(fingerprint(shuffled) == reference)
    }
}

/// The scoped rollups are a *partition* of the same deduped events the global
/// figures are computed from, and they must not resolve labels on their own:
/// for every key, `scopedByProject` and `byProject` have to agree on
/// `displayName` and on the totals, and the scoped totals have to sum back to
/// the global ones. A scoped-only name resolution or a leaked duplicate would
/// break exactly here.
@Test func scopedRollupsPartitionTheGlobalTotalsAndShareByProjectsDisplayNames() throws {
    let snapshot = fixtureSnapshot()

    #expect(snapshot.scopedByProject.count == snapshot.byProject.count)
    for project in snapshot.byProject {
        let scoped = try #require(snapshot.scopedByProject[project.projectKey])
        // E12 winner rule is resolved once, globally — never per scope.
        #expect(scoped.displayName == project.displayName)
        #expect(scoped.allTime.tokens == project.tokens)
        #expect(scoped.allTime.eventCount == project.eventCount)
        #expect(almostEqual(scoped.allTime.cost, project.cost))
    }

    let scopes = snapshot.scopedByProject.values
    #expect(scopes.reduce(TokenCounts.zero) { $0 + $1.allTime.tokens } == snapshot.allTime.tokens)
    #expect(scopes.reduce(0) { $0 + $1.allTime.eventCount } == snapshot.allTime.eventCount)
    #expect(scopes.reduce(TokenCounts.zero) { $0 + $1.today.tokens } == snapshot.today.tokens)
    #expect(scopes.reduce(0) { $0 + $1.today.eventCount } == snapshot.today.eventCount)

    // The fallback label loses to a genuine one in the scoped rollup too.
    let projectKey = "-Volumes-SSD-Workspace-esca-platform"
    let fallback = "Volumes-SSD-Workspace-esca-platform"
    func labelled(_ id: String, _ displayName: String) -> UsageEvent {
        UsageEvent(
            timestamp: fixtureTime(0, 12, 0),
            sessionId: "fixture-session",
            projectKey: projectKey,
            projectDisplayName: displayName,
            model: "claude-sonnet-5",
            tokens: TokenCounts(input: 100, output: 0, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0),
            messageId: id,
            requestId: nil
        )
    }
    let mixed = Aggregator.rollup(
        events: [labelled("f-1", fallback), labelled("f-2", fallback), labelled("g-1", "esca-platform")],
        now: fixtureTime(0, 12, 0),
        calendar: calendar,
        pricing: .default
    )
    #expect(mixed.scopedByProject[projectKey]?.displayName == "esca-platform")
}
