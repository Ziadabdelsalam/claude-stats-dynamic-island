import Foundation

/// Per-MTok USD rates for a single model, plus whether the rate is a stand-in
/// for a model with no publicly known list price (D1).
public struct PricingRate: Sendable, Equatable {
    public var inputPerMTok: Double
    public var outputPerMTok: Double
    public var isEstimated: Bool

    public init(inputPerMTok: Double, outputPerMTok: Double, isEstimated: Bool) {
        self.inputPerMTok = inputPerMTok
        self.outputPerMTok = outputPerMTok
        self.isEstimated = isEstimated
    }
}

/// Model-id -> `PricingRate` lookup table with exact-then-longest-prefix
/// matching, plus `cost(model:tokens:)`. Pure value type — safe to pass into
/// `Aggregator.rollup` without any shared mutable state.
public struct PricingTable: Sendable {
    /// Result of resolving a model id against the table. Callers (notably
    /// `Aggregator`) use this to learn whether a model was unknown or its
    /// rate was estimated, without the table mutating anything itself.
    public struct Lookup: Sendable, Equatable {
        public var rate: PricingRate?
        public var matchedModelId: String?

        public var isUnknown: Bool { rate == nil }
        public var isEstimated: Bool { rate?.isEstimated ?? false }
    }

    private var rates: [String: PricingRate]

    public init(rates: [String: PricingRate]) {
        self.rates = rates
    }

    /// D1/D1a rates. `claude-fable-5` and `claude-opus-5` have no public list
    /// price, shipped at Opus-tier rates and flagged `isEstimated: true`.
    public static let `default` = PricingTable(rates: [
        "claude-fable-5": PricingRate(inputPerMTok: 5.00, outputPerMTok: 25.00, isEstimated: true),
        "claude-opus-5": PricingRate(inputPerMTok: 5.00, outputPerMTok: 25.00, isEstimated: true),
        "claude-opus-4-8": PricingRate(inputPerMTok: 5.00, outputPerMTok: 25.00, isEstimated: false),
        "claude-opus-4-7": PricingRate(inputPerMTok: 5.00, outputPerMTok: 25.00, isEstimated: false),
        "claude-sonnet-5": PricingRate(inputPerMTok: 3.00, outputPerMTok: 15.00, isEstimated: false),
        "claude-sonnet-4-6": PricingRate(inputPerMTok: 3.00, outputPerMTok: 15.00, isEstimated: false),
        "claude-haiku-4-5": PricingRate(inputPerMTok: 1.00, outputPerMTok: 5.00, isEstimated: false),
    ])

    /// Exact id match first, then the longest table key that is a prefix of
    /// `model` (e.g. a dated model string `claude-sonnet-5-20260101` matches
    /// the `claude-sonnet-5` entry), then a family fallback (D1a/D1a-ext) so
    /// an unrecognized-but-clearly-Opus/Fable/Sonnet/Haiku id still prices
    /// instead of silently costing $0: an id containing
    /// `-opus-`/`-fable-`/`-sonnet-`/`-haiku-` gets that family's rate,
    /// always forced `isEstimated: true`. Only a model matching none of
    /// these is truly unknown -> `Lookup` with a nil rate.
    public func lookup(model: String) -> Lookup {
        if let exact = rates[model] {
            return Lookup(rate: exact, matchedModelId: model)
        }
        let prefixMatches = rates.keys.filter { model.hasPrefix($0) }
        if let longest = prefixMatches.max(by: { $0.count < $1.count }) {
            return Lookup(rate: rates[longest], matchedModelId: longest)
        }
        if let familyRate = Self.familyFallbackRate(for: model) {
            return Lookup(rate: familyRate, matchedModelId: nil)
        }
        return Lookup(rate: nil, matchedModelId: nil)
    }

    /// D1a/D1a-ext family fallback: matched purely by substring, independent
    /// of the `rates` table, always estimated since it is a guess at the
    /// family's list price rather than a known one. Checked in a fixed order
    /// — opus -> fable -> sonnet -> haiku — so an id containing more than one
    /// marker still resolves deterministically.
    private static func familyFallbackRate(for model: String) -> PricingRate? {
        if model.contains("-opus-") {
            return PricingRate(inputPerMTok: 5.00, outputPerMTok: 25.00, isEstimated: true)
        }
        if model.contains("-fable-") {
            return PricingRate(inputPerMTok: 5.00, outputPerMTok: 25.00, isEstimated: true)
        }
        if model.contains("-sonnet-") {
            return PricingRate(inputPerMTok: 3.00, outputPerMTok: 15.00, isEstimated: true)
        }
        if model.contains("-haiku-") {
            return PricingRate(inputPerMTok: 1.00, outputPerMTok: 5.00, isEstimated: true)
        }
        return nil
    }

    /// Cost in USD for `tokens` under `model`'s rate. Cache multipliers are
    /// applied to the model's *input* rate (D1): 5m write x1.25, 1h write
    /// x2.0, cache read x0.10. Unknown models cost 0 and never crash.
    public func cost(model: String, tokens: TokenCounts) -> Double {
        guard let rate = lookup(model: model).rate else { return 0 }
        let perToken = 1.0 / 1_000_000.0
        let inputCost = Double(tokens.input) * rate.inputPerMTok * perToken
        let outputCost = Double(tokens.output) * rate.outputPerMTok * perToken
        let cacheWrite5mCost = Double(tokens.cacheWrite5m) * rate.inputPerMTok * 1.25 * perToken
        let cacheWrite1hCost = Double(tokens.cacheWrite1h) * rate.inputPerMTok * 2.0 * perToken
        let cacheReadCost = Double(tokens.cacheRead) * rate.inputPerMTok * 0.10 * perToken
        return inputCost + outputCost + cacheWrite5mCost + cacheWrite1hCost + cacheReadCost
    }
}
