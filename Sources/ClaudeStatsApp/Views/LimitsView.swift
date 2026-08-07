import SwiftUI
import ClaudeStatsCore

/// Plain-data snapshot of `PlanLimitsStore` for `PopoverRootView` (same D8 seam as
/// `RollupSnapshot`): the container views map store → this, the view never sees the store.
public struct PlanLimitsState {
    public let limits: [PlanLimit]?
    public let errorText: String?
    public let lastFetched: Date?

    public init(limits: [PlanLimit]? = nil, errorText: String? = nil, lastFetched: Date? = nil) {
        self.limits = limits
        self.errorText = errorText
        self.lastFetched = lastFetched
    }
}

/// The Limits tab: one `BarRow` per plan usage limit (5-hour session, weekly all-models,
/// weekly per-model), mirroring the Claude Desktop menu bar app's "Plan usage limits" list.
/// A 30 s `TimelineView` keeps the "resets 2h" countdowns and "updated Xs ago" footer moving
/// between the store's 60 s polls.
struct LimitsView: View {
    let state: PlanLimitsState

    /// The desktop app renders these bars blue, and the popover's clay accent is reserved
    /// for "live" signals — so normal fills are blue, escalating to accent/negative as a
    /// limit fills up or the API flags it.
    private static let normalFill = Color(hex: 0x4C8DF6)

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            content(now: context.date)
        }
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            SectionHeader(title: "Plan usage limits", trailing: updatedText(now: now))
            if let limits = state.limits, !limits.isEmpty {
                VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                    ForEach(limits) { limit in
                        BarRow(
                            label: limit.label,
                            value: limit.percent,
                            maxValue: 100,
                            displayValue: displayValue(for: limit, now: now),
                            color: fill(for: limit)
                        )
                    }
                }
                if let errorText = state.errorText {
                    FootnoteLabel(text: "\(errorText) Showing last fetch.", showsEstimateMarker: false)
                }
            } else if let errorText = state.errorText {
                emptyMessage(errorText)
            } else {
                emptyMessage("Fetching plan limits…")
            }
        }
    }

    private func displayValue(for limit: PlanLimit, now: Date) -> String {
        let percent = "\(Int(limit.percent.rounded()))%"
        guard let reset = PlanLimit.resetText(until: limit.resetsAt, now: now) else { return percent }
        return "\(percent) · \(reset)"
    }

    /// Severity from the API wins; percent thresholds catch a filling bar the server still
    /// calls "normal" so the color turns before the hard cutoff, not at it.
    private func fill(for limit: PlanLimit) -> Color {
        if limit.severity != "normal" {
            return ["exceeded", "critical", "at_limit"].contains(limit.severity)
                ? Theme.Color.negative
                : Theme.Color.accent
        }
        if limit.percent >= 90 { return Theme.Color.negative }
        if limit.percent >= 75 { return Theme.Color.accent }
        return Self.normalFill
    }

    private func updatedText(now: Date) -> String? {
        guard let lastFetched = state.lastFetched else { return nil }
        let seconds = max(0, now.timeIntervalSince(lastFetched))
        if seconds < 90 { return "updated just now" }
        if seconds < 3600 { return "updated \(Int(seconds / 60))m ago" }
        return "updated \(Int(seconds / 3600))h ago"
    }

    private func emptyMessage(_ text: String) -> some View {
        VStack(spacing: Theme.Spacing.sm) {
            Text(text)
                .font(Theme.Typography.label)
                .foregroundStyle(Theme.Color.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Spacing.xl)
    }
}

#Preview("LimitsView — populated") {
    LimitsView(state: PlanLimitsState(
        limits: [
            PlanLimit(kind: "session", label: "5-hour limit", percent: 52, severity: "normal",
                      resetsAt: Date().addingTimeInterval(2 * 3600), isActive: true),
            PlanLimit(kind: "weekly_all", label: "Weekly · all models", percent: 42, severity: "normal",
                      resetsAt: Date().addingTimeInterval(40 * 3600), isActive: false),
            PlanLimit(kind: "weekly_scoped", label: "Weekly · Fable", percent: 93, severity: "normal",
                      resetsAt: Date().addingTimeInterval(40 * 3600), isActive: false),
        ],
        lastFetched: Date().addingTimeInterval(-30)
    ))
    .padding()
    .frame(width: Theme.Layout.popoverWidth)
    .background(Theme.Color.background)
}

#Preview("LimitsView — no login") {
    LimitsView(state: PlanLimitsState(errorText: "No Claude Code login found — sign in to Claude Code first."))
        .padding()
        .frame(width: Theme.Layout.popoverWidth)
        .background(Theme.Color.background)
}
