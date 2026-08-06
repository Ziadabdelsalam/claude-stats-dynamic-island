import Testing
@testable import ClaudeStatsCore

private let oneMillion = 1_000_000

@Test func knownModelChargesInputAndOutputAtListRate() {
    let table = PricingTable.default
    let tokens = TokenCounts(input: oneMillion, output: oneMillion, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0)
    let cost = table.cost(model: "claude-opus-4-8", tokens: tokens)
    // 1 MTok input @ $5.00 + 1 MTok output @ $25.00
    #expect(cost == 30.00)

    let lookup = table.lookup(model: "claude-opus-4-8")
    #expect(!lookup.isUnknown)
    #expect(!lookup.isEstimated)
}

@Test func cacheWrite5mIsChargedAtOnePointTwoFiveTimesInputRate() {
    let table = PricingTable.default
    let tokens = TokenCounts(input: 0, output: 0, cacheWrite5m: oneMillion, cacheWrite1h: 0, cacheRead: 0)
    let cost = table.cost(model: "claude-sonnet-5", tokens: tokens)
    // 1 MTok cache write (5m) @ $3.00 input rate * 1.25
    #expect(cost == 3.75)
}

@Test func cacheWrite1hIsChargedAtTwoTimesInputRate() {
    let table = PricingTable.default
    let tokens = TokenCounts(input: 0, output: 0, cacheWrite5m: 0, cacheWrite1h: oneMillion, cacheRead: 0)
    let cost = table.cost(model: "claude-sonnet-5", tokens: tokens)
    // 1 MTok cache write (1h) @ $3.00 input rate * 2.0 (NOT 1.25 like the 5m tier)
    #expect(cost == 6.00)
}

@Test func cacheReadIsChargedAtZeroPointOneTimesInputRate() {
    let table = PricingTable.default
    let tokens = TokenCounts(input: 0, output: 0, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: oneMillion)
    let cost = table.cost(model: "claude-sonnet-5", tokens: tokens)
    // 1 MTok cache read @ $3.00 input rate * 0.10
    #expect(cost == 0.30)
}

@Test func cacheHeavyMixSumsAllTiersIndependently() {
    let table = PricingTable.default
    let tokens = TokenCounts(
        input: oneMillion,
        output: oneMillion,
        cacheWrite5m: oneMillion,
        cacheWrite1h: oneMillion,
        cacheRead: oneMillion
    )
    let cost = table.cost(model: "claude-sonnet-5", tokens: tokens)
    // input 3.00 + output 15.00 + 5m-write (3.00*1.25=3.75) + 1h-write (3.00*2.0=6.00) + read (3.00*0.10=0.30)
    let expected = 3.00 + 15.00 + 3.75 + 6.00 + 0.30
    #expect(cost == expected)
}

@Test func estimatedModelIsFlaggedButPricedAtOpusTierRates() {
    let table = PricingTable.default
    let lookup = table.lookup(model: "claude-fable-5")
    #expect(!lookup.isUnknown)
    #expect(lookup.isEstimated)

    let tokens = TokenCounts(input: oneMillion, output: oneMillion, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0)
    let cost = table.cost(model: "claude-fable-5", tokens: tokens)
    #expect(cost == 30.00)
}

@Test func unknownModelCostsZeroAndIsFlaggedUnknown() {
    let table = PricingTable.default
    let tokens = TokenCounts(input: oneMillion, output: oneMillion, cacheWrite5m: oneMillion, cacheWrite1h: oneMillion, cacheRead: oneMillion)
    let cost = table.cost(model: "claude-nonexistent-9000", tokens: tokens)
    #expect(cost == 0)

    let lookup = table.lookup(model: "claude-nonexistent-9000")
    #expect(lookup.isUnknown)
    #expect(!lookup.isEstimated)
}

@Test func datedModelIdPrefixMatchesItsFamily() {
    // Both "claude-opus-4-7" and "claude-opus-4-8" exist; a dated string
    // should prefix-match its own family, not a shorter/unrelated key.
    let table = PricingTable.default
    let lookup = table.lookup(model: "claude-opus-4-7-20260101")
    #expect(lookup.matchedModelId == "claude-opus-4-7")
    #expect(!lookup.isUnknown)
}

/// The only prefix-match path the real corpus actually depends on: measured
/// 1,601 unique billable events / 59.3M tokens under this dated haiku id.
/// If prefix matching regresses, this silently becomes $0 spend.
@Test func realCorpusDatedHaikuIdIsPricedNotUnknown() {
    let table = PricingTable.default
    let lookup = table.lookup(model: "claude-haiku-4-5-20251001")
    #expect(lookup.matchedModelId == "claude-haiku-4-5")
    #expect(!lookup.isUnknown)

    let tokens = TokenCounts(input: oneMillion, output: oneMillion, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0)
    // 1 MTok input @ $1.00 + 1 MTok output @ $5.00
    #expect(table.cost(model: "claude-haiku-4-5-20251001", tokens: tokens) == 6.00)
}

/// No key in `.default` is a prefix of any other key, so the *longest*-prefix
/// selection is never exercised there — a shortest-prefix bug would pass every
/// other test in this file. This table has three keys that all prefix-match.
@Test func longestPrefixWinsOverShorterPrefixes() {
    let table = PricingTable(rates: [
        "claude": PricingRate(inputPerMTok: 99.00, outputPerMTok: 99.00, isEstimated: false),
        "claude-sonnet": PricingRate(inputPerMTok: 50.00, outputPerMTok: 50.00, isEstimated: false),
        "claude-sonnet-5": PricingRate(inputPerMTok: 3.00, outputPerMTok: 15.00, isEstimated: false),
    ])
    let lookup = table.lookup(model: "claude-sonnet-5-20260101")
    #expect(lookup.matchedModelId == "claude-sonnet-5")

    let tokens = TokenCounts(input: oneMillion, output: 0, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0)
    #expect(table.cost(model: "claude-sonnet-5-20260101", tokens: tokens) == 3.00)
}

/// Exact match must win even when a shorter key also prefix-matches.
@Test func exactMatchWinsOverShorterPrefixMatch() {
    let table = PricingTable(rates: [
        "claude-sonnet": PricingRate(inputPerMTok: 50.00, outputPerMTok: 50.00, isEstimated: true),
        "claude-sonnet-5": PricingRate(inputPerMTok: 3.00, outputPerMTok: 15.00, isEstimated: false),
    ])
    let lookup = table.lookup(model: "claude-sonnet-5")
    #expect(lookup.matchedModelId == "claude-sonnet-5")
    #expect(!lookup.isEstimated)
    #expect(lookup.rate?.inputPerMTok == 3.00)
}

/// Locks every row of D1 + D1a verbatim, including which rows ship estimated
/// (`claude-fable-5` and `claude-opus-5`, and only those). Any silent edit to
/// a rate or an estimate flag fails here.
@Test func defaultTableMatchesD1Verbatim() {
    let table = PricingTable.default
    let expected: [(String, Double, Double, Bool)] = [
        ("claude-fable-5", 5.00, 25.00, true),
        ("claude-opus-5", 5.00, 25.00, true),
        ("claude-opus-4-8", 5.00, 25.00, false),
        ("claude-opus-4-7", 5.00, 25.00, false),
        ("claude-sonnet-5", 3.00, 15.00, false),
        ("claude-sonnet-4-6", 3.00, 15.00, false),
        ("claude-haiku-4-5", 1.00, 5.00, false),
    ]
    for (model, input, output, isEstimated) in expected {
        let rate = table.lookup(model: model).rate
        #expect(rate?.inputPerMTok == input, "input rate for \(model)")
        #expect(rate?.outputPerMTok == output, "output rate for \(model)")
        #expect(rate?.isEstimated == isEstimated, "isEstimated for \(model)")
    }
}

// MARK: - D1a family fallback

/// A never-seen dated Opus id still prices at the Opus family rate, forced
/// estimated, instead of falling through to unknown/$0 (D1a).
@Test func familyFallbackPricesUnseenOpusIdAsEstimated() {
    let table = PricingTable.default
    let lookup = table.lookup(model: "claude-opus-9-20990101")
    #expect(!lookup.isUnknown)
    #expect(lookup.isEstimated)
    #expect(lookup.rate?.inputPerMTok == 5.00)
    #expect(lookup.rate?.outputPerMTok == 25.00)

    let tokens = TokenCounts(input: oneMillion, output: oneMillion, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0)
    #expect(table.cost(model: "claude-opus-9-20990101", tokens: tokens) == 30.00)
}

@Test func familyFallbackPricesUnseenSonnetIdAsEstimated() {
    let table = PricingTable.default
    let lookup = table.lookup(model: "claude-sonnet-9-20990101")
    #expect(!lookup.isUnknown)
    #expect(lookup.isEstimated)
    #expect(lookup.rate?.inputPerMTok == 3.00)
    #expect(lookup.rate?.outputPerMTok == 15.00)
}

@Test func familyFallbackPricesUnseenHaikuIdAsEstimated() {
    let table = PricingTable.default
    let lookup = table.lookup(model: "claude-haiku-9-20990101")
    #expect(!lookup.isUnknown)
    #expect(lookup.isEstimated)
    #expect(lookup.rate?.inputPerMTok == 1.00)
    #expect(lookup.rate?.outputPerMTok == 5.00)
}

/// D1a-ext: a future `claude-fable-6` (no exact/prefix row yet) must not
/// regress to unknown/$0 — it prices at the Fable family rate, estimated.
@Test func familyFallbackPricesUnseenFableIdAsEstimated() {
    let table = PricingTable.default
    let lookup = table.lookup(model: "claude-fable-6")
    #expect(!lookup.isUnknown)
    #expect(lookup.isEstimated)
    #expect(lookup.rate?.inputPerMTok == 5.00)
    #expect(lookup.rate?.outputPerMTok == 25.00)

    let tokens = TokenCounts(input: oneMillion, output: oneMillion, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0)
    #expect(table.cost(model: "claude-fable-6", tokens: tokens) == 30.00)
}

/// Exact and prefix matches must win over the family fallback even though
/// the id also contains a family marker — precedence is exact -> prefix ->
/// family -> unknown (D1a), never the reverse.
@Test func exactAndPrefixMatchesBeatFamilyFallback() {
    let table = PricingTable.default

    let exact = table.lookup(model: "claude-opus-5")
    #expect(exact.matchedModelId == "claude-opus-5")
    #expect(exact.isEstimated) // true per its own table row, not a forced family flag

    let prefixed = table.lookup(model: "claude-opus-4-8-20260101")
    #expect(prefixed.matchedModelId == "claude-opus-4-8")
    #expect(!prefixed.isEstimated) // prefix hit on a non-estimated row must NOT be forced true
    #expect(prefixed.rate?.inputPerMTok == 5.00)
}

/// An id containing more than one family marker must resolve deterministically.
/// The family chain is checked opus -> fable -> sonnet -> haiku (D1a-ext
/// inserted `-fable-` right after `-opus-`), so opus/fable ids (same 5/25
/// rate) always win over sonnet/haiku regardless of where each marker sits
/// in the string. Nothing else pins this: reordering the chain would
/// silently reprice such ids by a whole tier.
@Test func multipleFamilyMarkersResolveDeterministicallyToOpus() {
    let table = PricingTable.default
    for id in ["claude-opus-sonnet-test", "claude-sonnet-opus-test", "claude-haiku-opus-test"] {
        let lookup = table.lookup(model: id)
        #expect(lookup.rate?.inputPerMTok == 5.00, "family precedence for \(id)")
        #expect(lookup.rate?.outputPerMTok == 25.00, "family precedence for \(id)")
        #expect(lookup.isEstimated, "family matches are always estimated: \(id)")
    }
}

/// `-fable-` sits between `-opus-` and `-sonnet-`/`-haiku-` in the chain
/// (D1a-ext): it wins over the lower tiers even when they also appear in the
/// id, but does not affect (and is not affected by) `-opus-` since both
/// resolve to the same 5/25 rate.
@Test func fableMarkerBeatsSonnetAndHaikuInFamilyChain() {
    let table = PricingTable.default
    for id in ["claude-fable-sonnet-test", "claude-sonnet-fable-test", "claude-fable-haiku-test", "claude-haiku-fable-test"] {
        let lookup = table.lookup(model: id)
        #expect(lookup.rate?.inputPerMTok == 5.00, "fable precedence for \(id)")
        #expect(lookup.rate?.outputPerMTok == 25.00, "fable precedence for \(id)")
        #expect(lookup.isEstimated, "family matches are always estimated: \(id)")
    }
}

/// A model id with no known exact/prefix match and no `-opus-`/`-sonnet-`/
/// `-haiku-` family marker anywhere is still truly unknown: cost 0, no crash.
@Test func trulyAlienModelIsStillUnknownAfterFamilyFallback() {
    let table = PricingTable.default
    let tokens = TokenCounts(input: oneMillion, output: oneMillion, cacheWrite5m: oneMillion, cacheWrite1h: oneMillion, cacheRead: oneMillion)
    #expect(table.cost(model: "gpt-oss-120b", tokens: tokens) == 0)

    let lookup = table.lookup(model: "gpt-oss-120b")
    #expect(lookup.isUnknown)
    #expect(!lookup.isEstimated)
}
