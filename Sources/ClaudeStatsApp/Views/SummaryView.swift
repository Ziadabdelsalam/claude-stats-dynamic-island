import SwiftUI
import ClaudeStatsCore

/// The default "Summary" tab: today's headline tiles, the current-session burn rate (or an
/// idle state per D6a), and a 30-day token sparkline built from `byDay`. Takes a plain,
/// already-populated `RollupSnapshot` — `PopoverRootView` only mounts this once the snapshot
/// is non-nil and non-empty (D8), so this view never has its own loading/empty branches.
///
/// D8a/D9: scopes to `scopedByProject[effectiveKey]` (effectiveKey = `selectedProjectKey` if
/// pinned, else `snapshot.activeProjectKey`) whenever that key resolves — global figures are
/// the fallback, not the default.
struct SummaryView: View {
    let snapshot: RollupSnapshot
    /// `nil` = "Auto" (follow `snapshot.activeProjectKey`); otherwise a manually pinned project.
    let selectedProjectKey: String?

    private var effectiveProjectKey: String? { selectedProjectKey ?? snapshot.activeProjectKey }
    private var scoped: ProjectScopedRollup? {
        effectiveProjectKey.flatMap { snapshot.scopedByProject[$0] }
    }

    /// D1c: any non-empty `estimatedPricingModels` means headline cost figures include
    /// estimated-rate spend, so every cost figure in this view renders with the `≈` prefix.
    /// Scoped views read the scoped rollup's own set (E9, precise per-project) instead of the
    /// blended global one, so a project with no estimated-rate spend of its own never shows
    /// `≈` just because some *other* project does.
    private var costIsEstimated: Bool {
        !(scoped?.estimatedPricingModels ?? snapshot.estimatedPricingModels).isEmpty
    }

    private var todayTotals: RollupSnapshot.Totals { scoped?.today ?? snapshot.today }
    private var last30Totals: RollupSnapshot.Totals { scoped?.last30Days ?? snapshot.last30Days }
    private var byDay: [DayRollup] { scoped?.byDay ?? snapshot.byDay }

    /// D6a + D9: when a scope resolves, the session is that project's own — including its
    /// *absence*. `scoped?.session ?? snapshot.session` would flatten the two optionals and
    /// substitute the global session whenever the scoped project is idle, rendering another
    /// project's live burn rate under this project's name; `.map` keeps the levels distinct.
    private var session: SessionRollup? { scoped.map(\.session) ?? snapshot.session }

    /// D8a: makes the active scope visible above the headline tiles — the resolved project's
    /// name when one resolves (auto-follow or a manual pick), "All projects" only when neither
    /// does (e.g. the active project has no scoped rollup yet).
    private var scopeSubtitle: String {
        guard let scoped else { return "All projects" }
        return "\(scoped.displayName) · today"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            Text(scopeSubtitle)
                .font(Theme.Typography.footnote)
                .foregroundStyle(Theme.Color.textTertiary)

            HStack(spacing: Theme.Spacing.sm) {
                StatTile(label: "TOKENS TODAY", value: todayTotals.tokens.total.compactTokens)
                StatTile(label: "COST TODAY", value: todayTotals.cost.currency(estimated: costIsEstimated))
            }

            sessionCard

            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                SectionHeader(title: "30-day tokens", trailing: last30Totals.tokens.total.compactTokens)
                Sparkline(values: byDay.map { Double($0.tokens.total) })
                    .frame(height: 44)
            }
        }
    }

    /// D6a: `session == nil` is idle — a dimmed dot and a plain "no active session" message,
    /// never a stale session rendered as live. Scoped to the effective project when it resolves.
    @ViewBuilder
    private var sessionCard: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            SectionHeader(title: "Session")
            HStack(spacing: Theme.Spacing.sm) {
                Circle()
                    .fill(session != nil ? Theme.Color.accent : Theme.Color.textTertiary.opacity(0.4))
                    .frame(width: 8, height: 8)
                if let session {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(Int(session.tokensPerMinute).compactTokens) tok/min")
                            .font(Theme.Typography.numeric(13))
                            .foregroundStyle(Theme.Color.textPrimary)
                        Text("\(session.dollarsPerHour.currency(estimated: costIsEstimated))/hr")
                            .font(Theme.Typography.footnote)
                            .foregroundStyle(Theme.Color.textSecondary)
                    }
                } else {
                    Text("No active session")
                        .font(Theme.Typography.numeric(13))
                        .foregroundStyle(Theme.Color.textTertiary)
                }
                Spacer()
            }
        }
        .padding(Theme.Spacing.md)
        .background(Theme.Color.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous))
    }
}

#Preview("Loading") {
    SummaryView(snapshot: .sample(), selectedProjectKey: nil)
        .redacted(reason: .placeholder)
        .padding(Theme.Spacing.md)
        .frame(width: Theme.Layout.popoverWidth)
        .background(Theme.Color.background)
}

#Preview("Empty") {
    SummaryView(snapshot: .sampleEmpty(), selectedProjectKey: nil)
        .padding(Theme.Spacing.md)
        .frame(width: Theme.Layout.popoverWidth)
        .background(Theme.Color.background)
}

#Preview("Populated - Auto") {
    SummaryView(snapshot: .sample(), selectedProjectKey: nil)
        .padding(Theme.Spacing.md)
        .frame(width: Theme.Layout.popoverWidth)
        .background(Theme.Color.background)
}

#Preview("Populated - Idle") {
    SummaryView(snapshot: .sampleIdle(), selectedProjectKey: nil)
        .padding(Theme.Spacing.md)
        .frame(width: Theme.Layout.popoverWidth)
        .background(Theme.Color.background)
}

/// D8a: manually pinned to a project other than the auto-followed active one — scoped totals,
/// session and sparkline all come from `esca-platform`'s own `ProjectScopedRollup`.
#Preview("Populated - Manually Scoped") {
    SummaryView(snapshot: .sample(), selectedProjectKey: "-Volumes-SSD-Workspace-esca-platform")
        .padding(Theme.Spacing.md)
        .frame(width: Theme.Layout.popoverWidth)
        .background(Theme.Color.background)
}

/// D9/E9: pinned to the project whose own `estimatedPricingModels` is non-empty — the `≈`
/// prefix here comes from the scoped rollup, not the blended global one.
#Preview("Populated - Scoped Estimated Models") {
    SummaryView(snapshot: .sample(), selectedProjectKey: "-Volumes-SSD-Workspace-claude-stats-dynamic-island")
        .padding(Theme.Spacing.md)
        .frame(width: Theme.Layout.popoverWidth)
        .background(Theme.Color.background)
}
