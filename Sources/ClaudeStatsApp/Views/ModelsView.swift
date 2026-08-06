import SwiftUI
import ClaudeStatsCore

/// The "Models" tab: per-model split, sorted cost-desc (D6), rendered as `BarRow`s using the
/// theme's fixed per-model color map so a given model reads the same color everywhere in the UI.
///
/// D8a/D9: when `scopedByProject[effectiveKey]` resolves (effectiveKey = `selectedProjectKey`
/// if pinned, else `snapshot.activeProjectKey`), shows that project's own `byModel` split;
/// global otherwise.
struct ModelsView: View {
    let snapshot: RollupSnapshot
    /// `nil` = "Auto" (follow `snapshot.activeProjectKey`); otherwise a manually pinned project.
    let selectedProjectKey: String?

    private var effectiveProjectKey: String? { selectedProjectKey ?? snapshot.activeProjectKey }
    private var scoped: ProjectScopedRollup? {
        effectiveProjectKey.flatMap { snapshot.scopedByProject[$0] }
    }

    private var byModel: [ModelRollup] { scoped?.byModel ?? snapshot.byModel }
    private var estimatedPricingModels: Set<String> { scoped?.estimatedPricingModels ?? snapshot.estimatedPricingModels }

    /// E9: per-row marker, not the blended global one — a row's `≈` reflects only whether
    /// *that* model's own raw id (D1b) is in the (scoped or global) `estimatedPricingModels`,
    /// an exact match.
    private func isEstimated(_ model: ModelRollup) -> Bool {
        estimatedPricingModels.contains(model.model)
    }

    /// E10: bars plot **cost** so bar length stays monotonic with the cost-desc sort (D6) —
    /// scaling against tokens would let a cache-read-heavy, cheaply-billed model outrank a
    /// pricier one on bar length despite ranking below it on cost.
    private var maxCost: Double {
        byModel.map(\.cost).max() ?? 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            SectionHeader(title: "By model", trailing: "\(byModel.count)")
            if byModel.isEmpty {
                Text("No model activity yet.")
                    .font(Theme.Typography.label)
                    .foregroundStyle(Theme.Color.textTertiary)
            } else {
                VStack(spacing: Theme.Spacing.md) {
                    ForEach(byModel) { model in
                        BarRow(
                            label: model.model,
                            value: model.cost,
                            maxValue: maxCost,
                            displayValue: "\(model.tokens.total.compactTokens) · \(model.cost.currency(estimated: isEstimated(model)))",
                            color: Theme.Color.forModel(model.model)
                        )
                    }
                }
            }
        }
    }
}

#Preview("Loading") {
    ModelsView(snapshot: .sample(), selectedProjectKey: nil)
        .redacted(reason: .placeholder)
        .padding(Theme.Spacing.md)
        .frame(width: Theme.Layout.popoverWidth)
        .background(Theme.Color.background)
}

#Preview("Empty") {
    ModelsView(snapshot: .sampleEmpty(), selectedProjectKey: nil)
        .padding(Theme.Spacing.md)
        .frame(width: Theme.Layout.popoverWidth)
        .background(Theme.Color.background)
}

// `.sample()`'s global `byModel` mixes a `claude-fable-5` row (estimated) with three
// confirmed-rate rows (E9: per-row `≈`, not a blended marker) — this single preview (auto,
// following the active project) exercises both.
#Preview("Populated - Auto (Mixed Pricing)") {
    ModelsView(snapshot: .sample(), selectedProjectKey: nil)
        .padding(Theme.Spacing.md)
        .frame(width: Theme.Layout.popoverWidth)
        .background(Theme.Color.background)
}

/// D8a: manually pinned to a project other than the auto-followed active one — `byModel` here
/// is `esca-platform`'s own scoped split (a single confirmed-rate model, no `≈`).
#Preview("Populated - Manually Scoped") {
    ModelsView(snapshot: .sample(), selectedProjectKey: "-Volumes-SSD-Workspace-esca-platform")
        .padding(Theme.Spacing.md)
        .frame(width: Theme.Layout.popoverWidth)
        .background(Theme.Color.background)
}

/// D9/E9: pinned to the project whose own `estimatedPricingModels` is non-empty — the scoped
/// `claude-fable-5` row here comes from that project's rollup, not the blended global one.
#Preview("Populated - Scoped Estimated Models") {
    ModelsView(snapshot: .sample(), selectedProjectKey: "-Volumes-SSD-Workspace-claude-stats-dynamic-island")
        .padding(Theme.Spacing.md)
        .frame(width: Theme.Layout.popoverWidth)
        .background(Theme.Color.background)
}
