import SwiftUI
import ClaudeStatsCore

/// The "Projects" tab: top projects, already sorted cost-desc by the aggregator (D6), rendered
/// as `BarRow`s scaled against the leading project's cost.
///
/// D8a: this tab's list always stays global (unlike Summary/Models); a row click instead pins
/// the app-wide scope to that project via `onSelectProject`, and the row matching the currently
/// effective project is highlighted.
struct ProjectsView: View {
    let snapshot: RollupSnapshot
    /// `nil` = "Auto" (follow `snapshot.activeProjectKey`) — used only to mark the effective row.
    let selectedProjectKey: String?
    /// D8a: `nil` re-selects "Auto"; this view only ever calls it with a concrete project key.
    let onSelectProject: (String?) -> Void

    private var effectiveProjectKey: String? { selectedProjectKey ?? snapshot.activeProjectKey }

    /// D1c: any non-empty `estimatedPricingModels` means headline cost figures include
    /// estimated-rate spend, so every cost figure in this view renders with the `≈` prefix.
    private var costIsEstimated: Bool { !snapshot.estimatedPricingModels.isEmpty }

    /// E11: only the top 10 projects get their own row; the rest collapse into a trailing
    /// "+N more" row so the list can't blow the popover's fixed height.
    private static let visibleLimit = 10

    private var visibleProjects: ArraySlice<ProjectRollup> {
        snapshot.byProject.prefix(Self.visibleLimit)
    }

    private var overflowProjects: ArraySlice<ProjectRollup> {
        snapshot.byProject.dropFirst(Self.visibleLimit)
    }

    /// The whole tail's cost, aggregated into the "+N more" row (0 when nothing overflows).
    private var overflowCost: Double {
        overflowProjects.reduce(0.0) { $0 + $1.cost }
    }

    /// E10: bars plot **cost** so bar length stays monotonic with the cost-desc sort (D6) —
    /// scaling against tokens would let a cache-read-heavy, cheaply-billed project outrank a
    /// pricier one on bar length despite ranking below it on cost. The "+N more" row sums the
    /// entire tail, so its cost can exceed *any* single project's; the denominator has to
    /// include it, or a long tail clamps that row to a full-width bar sitting next to an
    /// equally full leader and reads as "the rest ties the top project".
    private var maxCost: Double {
        max(snapshot.byProject.map(\.cost).max() ?? 0, overflowCost)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            SectionHeader(title: "Top projects", trailing: "\(snapshot.byProject.count)")
            if snapshot.byProject.isEmpty {
                Text("No project activity yet.")
                    .font(Theme.Typography.label)
                    .foregroundStyle(Theme.Color.textTertiary)
            } else {
                VStack(spacing: Theme.Spacing.md) {
                    ForEach(visibleProjects) { project in
                        projectRow(project)
                    }
                    if !overflowProjects.isEmpty {
                        overflowRow
                    }
                }
            }
        }
    }

    /// D8a: clicking a row pins the scope to that project; the row matching the currently
    /// effective project (manual pick, or the auto-followed active project when none is pinned)
    /// gets a highlighted background.
    private func projectRow(_ project: ProjectRollup) -> some View {
        Button {
            onSelectProject(project.projectKey)
        } label: {
            BarRow(
                label: project.displayName,
                value: project.cost,
                maxValue: maxCost,
                displayValue: "\(project.tokens.total.compactTokens) · \(project.cost.currency(estimated: costIsEstimated))"
            )
            .padding(Theme.Spacing.xs)
            .background(
                project.projectKey == effectiveProjectKey ? Theme.Color.surfaceElevated : Color.clear,
                in: RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
            )
        }
        .buttonStyle(.plain)
    }

    /// E11: aggregates the overflow projects' cost and tokens into a single trailing row. Not
    /// a real project, so it's never selectable.
    private var overflowRow: some View {
        let overflowTokens = overflowProjects.reduce(0) { $0 + $1.tokens.total }
        return BarRow(
            label: "+\(overflowProjects.count) more",
            value: overflowCost,
            maxValue: maxCost,
            displayValue: "\(overflowTokens.compactTokens) · \(overflowCost.currency(estimated: costIsEstimated))",
            color: Theme.Color.textTertiary
        )
        .padding(Theme.Spacing.xs)
    }
}

#Preview("Loading") {
    ProjectsView(snapshot: .sample(), selectedProjectKey: nil, onSelectProject: { _ in })
        .redacted(reason: .placeholder)
        .padding(Theme.Spacing.md)
        .frame(width: Theme.Layout.popoverWidth)
        .background(Theme.Color.background)
}

#Preview("Empty") {
    ProjectsView(snapshot: .sampleEmpty(), selectedProjectKey: nil, onSelectProject: { _ in })
        .padding(Theme.Spacing.md)
        .frame(width: Theme.Layout.popoverWidth)
        .background(Theme.Color.background)
}

#Preview("Populated - Auto") {
    ProjectsView(snapshot: .sample(), selectedProjectKey: nil, onSelectProject: { _ in })
        .padding(Theme.Spacing.md)
        .frame(width: Theme.Layout.popoverWidth)
        .background(Theme.Color.background)
}

/// D8a: a manual pick highlights that row instead of the auto-followed active project's row.
#Preview("Populated - Manually Scoped") {
    ProjectsView(snapshot: .sample(), selectedProjectKey: "-Volumes-SSD-Workspace-esca-platform", onSelectProject: { _ in })
        .padding(Theme.Spacing.md)
        .frame(width: Theme.Layout.popoverWidth)
        .background(Theme.Color.background)
}

// E11: 14 projects — top 10 get their own row, the remaining 4 collapse into "+4 more".
#Preview("Populated - Many Projects") {
    ProjectsView(snapshot: .sampleManyProjects(), selectedProjectKey: nil, onSelectProject: { _ in })
        .padding(Theme.Spacing.md)
        .frame(width: Theme.Layout.popoverWidth)
        .background(Theme.Color.background)
}
