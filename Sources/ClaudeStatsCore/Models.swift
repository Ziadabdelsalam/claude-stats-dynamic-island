import Foundation

/// Raw token counts for a single billable usage event, split by cache tier so
/// pricing multipliers can be applied per-tier (see D1 in the team plan).
public struct TokenCounts: Sendable, Codable, Equatable {
    public var input: Int
    public var output: Int
    public var cacheWrite5m: Int
    public var cacheWrite1h: Int
    public var cacheRead: Int

    public init(input: Int, output: Int, cacheWrite5m: Int, cacheWrite1h: Int, cacheRead: Int) {
        self.input = input
        self.output = output
        self.cacheWrite5m = cacheWrite5m
        self.cacheWrite1h = cacheWrite1h
        self.cacheRead = cacheRead
    }

    public var cacheWrite: Int { cacheWrite5m + cacheWrite1h }
    public var total: Int { input + output + cacheWrite + cacheRead }

    public static let zero = TokenCounts(input: 0, output: 0, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0)

    public static func + (l: Self, r: Self) -> Self {
        TokenCounts(
            input: l.input + r.input,
            output: l.output + r.output,
            cacheWrite5m: l.cacheWrite5m + r.cacheWrite5m,
            cacheWrite1h: l.cacheWrite1h + r.cacheWrite1h,
            cacheRead: l.cacheRead + r.cacheRead
        )
    }

    public static func += (l: inout Self, r: Self) {
        l = l + r
    }
}

/// A single deduplicated, billable assistant response parsed from a transcript line.
public struct UsageEvent: Sendable, Codable, Equatable {
    public var timestamp: Date
    public var sessionId: String
    public var projectKey: String
    public var projectDisplayName: String
    public var model: String
    public var tokens: TokenCounts
    public var messageId: String
    public var requestId: String?

    public init(
        timestamp: Date,
        sessionId: String,
        projectKey: String,
        projectDisplayName: String,
        model: String,
        tokens: TokenCounts,
        messageId: String,
        requestId: String?
    ) {
        self.timestamp = timestamp
        self.sessionId = sessionId
        self.projectKey = projectKey
        self.projectDisplayName = projectDisplayName
        self.model = model
        self.tokens = tokens
        self.messageId = messageId
        self.requestId = requestId
    }

    /// Dedup key per D2: `message.id` alone (`requestId` is nullable in real data).
    public var dedupKey: String { messageId }
}
