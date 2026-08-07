import Foundation

/// One plan usage limit as reported by Anthropic's OAuth usage endpoint —
/// the same rows the Claude Desktop menu bar app shows under "Plan usage limits".
public struct PlanLimit: Sendable, Equatable, Identifiable {
    public let kind: String
    public let label: String
    public let percent: Double
    public let severity: String
    public let resetsAt: Date?
    public let isActive: Bool

    /// `weekly_scoped` can appear once per model, so the scope name is part of the identity.
    public var id: String { "\(kind)|\(label)" }

    public init(kind: String, label: String, percent: Double, severity: String, resetsAt: Date?, isActive: Bool) {
        self.kind = kind
        self.label = label
        self.percent = percent
        self.severity = severity
        self.resetsAt = resetsAt
        self.isActive = isActive
    }
}

public extension PlanLimit {
    /// "resets 2h"-style countdown matching the desktop app: minutes under an hour, hours
    /// under a day, else days — always ceilinged so a limit about to reset never reads "0m".
    static func resetText(until resetsAt: Date?, now: Date) -> String? {
        guard let resetsAt else { return nil }
        let seconds = resetsAt.timeIntervalSince(now)
        guard seconds > 0 else { return "resets now" }
        if seconds < 3600 {
            return "resets \(Int((seconds / 60).rounded(.up)))m"
        }
        if seconds < 86400 {
            return "resets \(Int((seconds / 3600).rounded(.up)))h"
        }
        return "resets \(Int((seconds / 86400).rounded(.up)))d"
    }
}

/// Decodes the `limits` array of `GET https://api.anthropic.com/api/oauth/usage`.
/// Only `limits` is read; every other top-level key is ignored so new fields
/// on the endpoint can never break us.
public enum PlanLimitsDecoder {
    public static func decode(_ data: Data) throws -> [PlanLimit] {
        let response = try JSONDecoder().decode(WireResponse.self, from: data)
        return response.limits.map { wire in
            PlanLimit(
                kind: wire.kind,
                label: label(for: wire),
                percent: wire.percent ?? 0,
                severity: wire.severity ?? "normal",
                resetsAt: wire.resetsAt.flatMap(parseTimestamp),
                isActive: wire.isActive ?? false
            )
        }
    }

    private static func label(for wire: WireLimit) -> String {
        switch wire.kind {
        case "session": return "5-hour limit"
        case "weekly_all": return "Weekly · all models"
        case "weekly_scoped":
            if let model = wire.scope?.model?.displayName { return "Weekly · \(model)" }
            return "Weekly"
        default:
            return wire.kind
        }
    }

    /// The endpoint emits fractional-second ISO8601 ("…T07:00:00.158341+00:00");
    /// tolerate the plain variant too.
    private static func parseTimestamp(_ raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) { return date }
        return ISO8601DateFormatter().date(from: raw)
    }

    private struct WireResponse: Decodable {
        let limits: [WireLimit]
    }

    private struct WireLimit: Decodable {
        let kind: String
        let percent: Double?
        let severity: String?
        let resetsAt: String?
        let scope: WireScope?
        let isActive: Bool?

        enum CodingKeys: String, CodingKey {
            case kind, percent, severity, scope
            case resetsAt = "resets_at"
            case isActive = "is_active"
        }
    }

    private struct WireScope: Decodable {
        let model: WireModel?
    }

    private struct WireModel: Decodable {
        let displayName: String?

        enum CodingKeys: String, CodingKey {
            case displayName = "display_name"
        }
    }
}
