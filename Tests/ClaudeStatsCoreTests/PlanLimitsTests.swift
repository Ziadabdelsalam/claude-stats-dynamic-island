import Foundation
import Testing
@testable import ClaudeStatsCore

private func fixtureData() throws -> Data {
    let url = try #require(Bundle.module.url(
        forResource: "plan_limits", withExtension: "json", subdirectory: "Fixtures"
    ))
    return try Data(contentsOf: url)
}

// MARK: - Decoding

@Test func decodesAllThreeLimitsFromLiveShapedFixture() throws {
    let limits = try PlanLimitsDecoder.decode(try fixtureData())
    #expect(limits.count == 3)
    #expect(limits.map(\.label) == ["5-hour limit", "Weekly · all models", "Weekly · Fable"])
    #expect(limits.map(\.percent) == [53, 42, 35])
    #expect(limits.map(\.severity) == ["normal", "normal", "normal"])
    #expect(limits[0].isActive)
    #expect(!limits[1].isActive)
}

@Test func parsesFractionalSecondResetTimestamps() throws {
    let limits = try PlanLimitsDecoder.decode(try fixtureData())
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    #expect(limits[0].resetsAt == iso.date(from: "2026-08-07T07:00:00.158341+00:00"))
}

@Test func unknownKindFallsBackToRawKindLabelAndUniqueIds() throws {
    let json = """
    {"limits": [
      {"kind": "mystery_new_limit", "percent": 10, "severity": "normal", "resets_at": null, "scope": null, "is_active": false},
      {"kind": "weekly_scoped", "percent": 20, "severity": "normal", "resets_at": null,
       "scope": {"model": {"id": null, "display_name": "Sonnet"}, "surface": null}, "is_active": false}
    ]}
    """.data(using: .utf8)!
    let limits = try PlanLimitsDecoder.decode(json)
    #expect(limits[0].label == "mystery_new_limit")
    #expect(limits[1].label == "Weekly · Sonnet")
    #expect(Set(limits.map(\.id)).count == 2)
}

@Test func missingLimitsKeyThrows() {
    let json = "{\"five_hour\": null}".data(using: .utf8)!
    #expect(throws: (any Error).self) {
        _ = try PlanLimitsDecoder.decode(json)
    }
}

// MARK: - Reset countdown text

@Test func resetTextUsesMinutesUnderAnHourCeilinged() {
    let now = Date(timeIntervalSince1970: 1_000_000)
    #expect(PlanLimit.resetText(until: now.addingTimeInterval(45 * 60), now: now) == "resets 45m")
    #expect(PlanLimit.resetText(until: now.addingTimeInterval(50), now: now) == "resets 1m")
}

@Test func resetTextUsesHoursUnderADayCeilinged() {
    let now = Date(timeIntervalSince1970: 1_000_000)
    #expect(PlanLimit.resetText(until: now.addingTimeInterval(90 * 60), now: now) == "resets 2h")
    #expect(PlanLimit.resetText(until: now.addingTimeInterval(2 * 3600), now: now) == "resets 2h")
}

@Test func resetTextUsesDaysBeyondADayCeilinged() {
    let now = Date(timeIntervalSince1970: 1_000_000)
    #expect(PlanLimit.resetText(until: now.addingTimeInterval(30 * 3600), now: now) == "resets 2d")
}

@Test func resetTextHandlesNilAndPastDates() {
    let now = Date(timeIntervalSince1970: 1_000_000)
    #expect(PlanLimit.resetText(until: nil, now: now) == nil)
    #expect(PlanLimit.resetText(until: now.addingTimeInterval(-5), now: now) == "resets now")
}

// MARK: - Credentials parsing (Task 2)

@Test func parsesCredentialsJsonWithEpochMillisExpiry() throws {
    let json = """
    {"claudeAiOauth": {"accessToken": "sk-ant-oat01-abc", "refreshToken": "sk-ant-ort01-x",
     "expiresAt": 1786088350104, "scopes": ["user:inference"], "subscriptionType": "max"},
     "mcpOAuth": {}}
    """.data(using: .utf8)!
    let creds = try ClaudeCredentialsReader.parse(json)
    #expect(creds.accessToken == "sk-ant-oat01-abc")
    #expect(creds.expiresAt == Date(timeIntervalSince1970: 1786088350.104))
}

@Test func missingClaudeAiOauthKeyThrows() {
    let json = "{\"mcpOAuth\": {}}".data(using: .utf8)!
    #expect(throws: (any Error).self) {
        _ = try ClaudeCredentialsReader.parse(json)
    }
}

@Test func expiryComparesAgainstNow() throws {
    let past = """
    {"claudeAiOauth": {"accessToken": "t", "expiresAt": 1000}}
    """.data(using: .utf8)!
    let creds = try ClaudeCredentialsReader.parse(past)
    #expect(creds.isExpired)
}
