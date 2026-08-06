import SwiftUI
import ClaudeStatsCore

/// The popover's root: header (project picker + live/idle dot + refresh), the
/// Summary/Projects/Models switch, and a footer (last refresh, quit, and the
/// estimated-pricing disclaimer). Built entirely from plain data — never touches
/// `UsageStore` — so `StatusItemController` (T7) can drive it from anywhere.
///
/// State handling per D8: `snapshot == nil && isLoading` -> loading;
/// `snapshot == nil || allTime.eventCount == 0` -> empty; otherwise populated.
///
/// Per-project scoping (D8a/D9): `selectedProjectKey` is the sticky manual pick, `nil` meaning
/// "Auto" (follow `snapshot.activeProjectKey`). The header's project name is a `Menu` that lets
/// the user switch; the effective key it and `SummaryView`/`ModelsView` resolve to is the pin
/// while it still exists in `snapshot.scopedByProject`, else `snapshot.activeProjectKey` —
/// the same resolution `UsageStore.effectiveProjectKey` applies to the status item and island.
public struct PopoverRootView: View {
    private let snapshot: RollupSnapshot?
    private let isLoading: Bool
    private let lastRefresh: Date?
    private let currentTask: String?
    private let selectedProjectKey: String?
    private let onSelectProject: (String?) -> Void
    private let onRefresh: () -> Void
    private let onQuit: () -> Void

    private enum Tab: String, CaseIterable, Identifiable {
        case summary = "Summary"
        case projects = "Projects"
        case models = "Models"
        var id: String { rawValue }
    }

    @State private var tab: Tab = .summary

    public init(
        snapshot: RollupSnapshot?,
        isLoading: Bool,
        lastRefresh: Date?,
        currentTask: String? = nil,
        selectedProjectKey: String?,
        onSelectProject: @escaping (String?) -> Void,
        onRefresh: @escaping () -> Void,
        onQuit: @escaping () -> Void
    ) {
        self.snapshot = snapshot
        self.isLoading = isLoading
        self.lastRefresh = lastRefresh
        self.currentTask = currentTask
        self.selectedProjectKey = selectedProjectKey
        self.onSelectProject = onSelectProject
        self.onRefresh = onRefresh
        self.onQuit = onQuit
    }

    private var isEmpty: Bool {
        snapshot == nil || snapshot?.allTime.eventCount == 0
    }

    /// D9, same resolution as `UsageStore.effectiveProjectKey`: the manual pin counts only while
    /// it still resolves against the live snapshot (a project whose transcripts were deleted
    /// leaves `scopedByProject`), otherwise the scope falls back to auto-follow. Resolving here
    /// and handing the result to the tab views keeps this popover, the status-item title and the
    /// island on one and the same scope; `nil` still means "Auto" downstream.
    private var pinnedProjectKey: String? {
        guard let selectedProjectKey, snapshot?.scopedByProject[selectedProjectKey] != nil else { return nil }
        return selectedProjectKey
    }

    private var effectiveProjectKey: String? {
        pinnedProjectKey ?? snapshot?.activeProjectKey
    }

    private var effectiveScopedRollup: ProjectScopedRollup? {
        guard let effectiveProjectKey, let snapshot else { return nil }
        return snapshot.scopedByProject[effectiveProjectKey]
    }

    /// D6a + D9: the scope's own session — including its absence. Optional-chaining
    /// (`effectiveScopedRollup?.session ?? snapshot?.session`) would flatten the two levels and
    /// light the header dot from the *global* session while a scoped, idle project is shown.
    private var effectiveSession: SessionRollup? {
        effectiveScopedRollup.map(\.session) ?? snapshot?.session
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            if let currentTask {
                currentTaskRow(currentTask)
            }
            Divider().overlay(Theme.Color.hairline)
            body(for: snapshot)
                .frame(maxHeight: .infinity)
            Divider().overlay(Theme.Color.hairline)
            footer
        }
        .frame(width: Theme.Layout.popoverWidth, height: 460)
        .background(Theme.Color.background)
    }

    @ViewBuilder
    private func body(for snapshot: RollupSnapshot?) -> some View {
        if snapshot == nil && isLoading {
            loadingState
        } else if isEmpty {
            emptyState
        } else if let snapshot {
            VStack(spacing: 0) {
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.top, Theme.Spacing.sm)

                ScrollView {
                    activeTabView(for: snapshot)
                        .padding(Theme.Spacing.md)
                }
            }
        }
    }

    @ViewBuilder
    private func activeTabView(for snapshot: RollupSnapshot) -> some View {
        switch tab {
        case .summary:
            SummaryView(snapshot: snapshot, selectedProjectKey: pinnedProjectKey)
        case .projects:
            ProjectsView(snapshot: snapshot, selectedProjectKey: pinnedProjectKey, onSelectProject: onSelectProject)
        case .models:
            ModelsView(snapshot: snapshot, selectedProjectKey: pinnedProjectKey)
        }
    }

    /// D13: the scope's current task — the newest genuine user prompt of the
    /// effective project's latest session, quoted verbatim (already truncated
    /// to 80 chars by the detector).
    private func currentTaskRow(_ task: String) -> some View {
        Text("\u{201C}\(task)\u{201D}")
            .font(.system(size: 10))
            .italic()
            .foregroundStyle(Theme.Color.textSecondary)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.bottom, 6)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Circle()
                .fill(effectiveSession != nil ? Theme.Color.accent : Theme.Color.textTertiary.opacity(0.5))
                .frame(width: 8, height: 8)
            projectPicker
            Spacer(minLength: Theme.Spacing.sm)
            Button(action: onRefresh) {
                Image(systemName: "arrow.clockwise")
                    .foregroundStyle(Theme.Color.textSecondary)
            }
            .buttonStyle(.plain)
        }
        .padding(Theme.Spacing.md)
    }

    /// D8a: the project name becomes a picker. "Auto (active)" follows `activeProjectKey`;
    /// picking any other project pins the scope until "Auto" is chosen again (sticky, never
    /// persisted across launches — that's the store's job, not this view's).
    private var projectPicker: some View {
        Menu {
            Button {
                onSelectProject(nil)
            } label: {
                pickerRow(title: "Auto (active)", isSelected: pinnedProjectKey == nil)
            }
            if let snapshot, !snapshot.byProject.isEmpty {
                Divider()
                ForEach(snapshot.byProject) { project in
                    Button {
                        onSelectProject(project.projectKey)
                    } label: {
                        pickerRow(title: project.displayName, isSelected: pinnedProjectKey == project.projectKey)
                    }
                }
            }
        } label: {
            HStack(spacing: 2) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(effectiveScopedRollup?.displayName ?? snapshot?.activeProject ?? "Claude Stats")
                        .font(Theme.Typography.label)
                        .fontWeight(.semibold)
                        .foregroundStyle(Theme.Color.textPrimary)
                        .lineLimit(1)
                    Text(headerStatusText)
                        .font(Theme.Typography.footnote)
                        .foregroundStyle(Theme.Color.textTertiary)
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Theme.Color.textTertiary)
            }
        }
        .menuStyle(.borderlessButton)
    }

    private var headerStatusText: String {
        let liveWord = effectiveSession != nil ? "active" : "idle"
        return pinnedProjectKey == nil ? "auto · \(liveWord)" : liveWord
    }

    @ViewBuilder
    private func pickerRow(title: String, isSelected: Bool) -> some View {
        if isSelected {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            if let snapshot, !snapshot.estimatedPricingModels.isEmpty {
                FootnoteLabel(text: "rates estimated for: \(snapshot.estimatedPricingModels.sorted().joined(separator: ", "))")
            }
            HStack {
                Text(lastRefreshText)
                    .font(Theme.Typography.footnote)
                    .foregroundStyle(Theme.Color.textTertiary)
                Spacer()
                Button("Quit", action: onQuit)
                    .buttonStyle(.plain)
                    .font(Theme.Typography.footnote)
                    .foregroundStyle(Theme.Color.textSecondary)
            }
        }
        .padding(Theme.Spacing.md)
    }

    private var lastRefreshText: String {
        guard let lastRefresh else { return "not refreshed yet" }
        return "updated \(Self.relativeFormatter.localizedString(for: lastRefresh, relativeTo: Date()))"
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    // MARK: - Loading / empty

    private var loadingState: some View {
        VStack(spacing: Theme.Spacing.sm) {
            Spacer()
            ProgressView()
                .controlSize(.small)
            Text("Loading usage…")
                .font(Theme.Typography.label)
                .foregroundStyle(Theme.Color.textSecondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: Theme.Spacing.sm) {
            Spacer()
            Image(systemName: "tray")
                .font(.system(size: 28))
                .foregroundStyle(Theme.Color.textTertiary)
            Text("No usage yet")
                .font(Theme.Typography.label)
                .foregroundStyle(Theme.Color.textSecondary)
            Text("Usage will appear here once Claude Code writes transcripts.")
                .font(Theme.Typography.footnote)
                .foregroundStyle(Theme.Color.textTertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Theme.Spacing.xl)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Sample data for previews

/// Sample `RollupSnapshot` values for `#Preview`s across every T8/T14 view — never used by the
/// running app. `RollupSnapshot` and its members all ship public memberwise inits (D6/D9), so
/// this is plain data construction, no app state involved.
///
/// Every factory below builds real `scopedByProject` entries + `activeProjectKey` (not the
/// defaulted empty-dictionary/nil params) so previews exercise the D8a scoped path honestly —
/// carried-forward must-fix from T10's review.
extension RollupSnapshot {
    private static let dynamicIslandKey = "-Volumes-SSD-Workspace-claude-stats-dynamic-island"
    private static let escaPlatformKey = "-Volumes-SSD-Workspace-esca-platform"
    private static let notesKey = "-Users-ziad-notes"

    static func sample(now: Date = Date()) -> RollupSnapshot {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)

        func tokens(_ total: Int) -> TokenCounts {
            TokenCounts(
                input: total * 4 / 10,
                output: total * 3 / 10,
                cacheWrite5m: total / 10,
                cacheWrite1h: total / 20,
                cacheRead: total * 15 / 100
            )
        }

        let byDay: [DayRollup] = (0..<30).map { index in
            let dayOffset = -(29 - index)
            let day = calendar.date(byAdding: .day, value: dayOffset, to: today)!
            let magnitude = max(0, 40_000 + Int(20_000 * sin(Double(index) / 3)))
            return DayRollup(day: day, tokens: tokens(magnitude), cost: Double(magnitude) / 1_000_000 * 12)
        }

        /// Scales the global 30-day series down to a project's own share of it — dense 30
        /// entries throughout, same window as `byDay` (D9's contract for `ProjectScopedRollup`).
        func scopedByDay(scale: Double) -> [DayRollup] {
            byDay.map { day in
                DayRollup(day: day.day, tokens: tokens(Int(Double(day.tokens.total) * scale)), cost: day.cost * scale)
            }
        }

        let byProject: [ProjectRollup] = [
            ProjectRollup(projectKey: dynamicIslandKey, displayName: "claude-stats-dynamic-island", tokens: tokens(820_000), cost: 24.18, eventCount: 412),
            ProjectRollup(projectKey: escaPlatformKey, displayName: "esca-platform", tokens: tokens(410_000), cost: 11.62, eventCount: 201),
            ProjectRollup(projectKey: notesKey, displayName: "notes", tokens: tokens(42_000), cost: 1.08, eventCount: 19),
        ]

        let byModel: [ModelRollup] = [
            ModelRollup(model: "claude-sonnet-5", tokens: tokens(720_000), cost: 21.40, eventCount: 380),
            ModelRollup(model: "claude-opus-4-8", tokens: tokens(410_000), cost: 12.85, eventCount: 140),
            ModelRollup(model: "claude-haiku-4-5", tokens: tokens(142_000), cost: 2.63, eventCount: 112),
            ModelRollup(model: "claude-fable-5", tokens: tokens(38_000), cost: 1.02, eventCount: 8),
        ]

        let session = SessionRollup(
            start: now.addingTimeInterval(-18 * 60),
            end: now,
            tokens: tokens(52_000),
            cost: 1.64,
            tokensPerMinute: 2_888,
            dollarsPerHour: 5.47
        )

        // D9: one `ProjectScopedRollup` per `byProject` entry — the active project
        // (`dynamicIslandKey`) carries the live session and the estimated `claude-fable-5`
        // spend, matching the global `session`/`estimatedPricingModels` above.
        let scopedByProject: [String: ProjectScopedRollup] = [
            dynamicIslandKey: ProjectScopedRollup(
                projectKey: dynamicIslandKey,
                displayName: "claude-stats-dynamic-island",
                today: .init(tokens: tokens(52_000), cost: 1.64, eventCount: 34),
                last7Days: .init(tokens: tokens(410_000), cost: 12.90, eventCount: 210),
                last30Days: .init(tokens: tokens(820_000), cost: 24.18, eventCount: 412),
                allTime: .init(tokens: tokens(820_000), cost: 24.18, eventCount: 412),
                byDay: scopedByDay(scale: 0.65),
                session: session,
                byModel: [
                    ModelRollup(model: "claude-sonnet-5", tokens: tokens(520_000), cost: 15.40, eventCount: 260),
                    ModelRollup(model: "claude-fable-5", tokens: tokens(38_000), cost: 1.02, eventCount: 8),
                ],
                estimatedPricingModels: ["claude-fable-5"]
            ),
            escaPlatformKey: ProjectScopedRollup(
                projectKey: escaPlatformKey,
                displayName: "esca-platform",
                today: .init(tokens: .zero, cost: 0, eventCount: 0),
                last7Days: .init(tokens: tokens(180_000), cost: 5.10, eventCount: 88),
                last30Days: .init(tokens: tokens(410_000), cost: 11.62, eventCount: 201),
                allTime: .init(tokens: tokens(410_000), cost: 11.62, eventCount: 201),
                byDay: scopedByDay(scale: 0.31),
                session: nil,
                byModel: [
                    ModelRollup(model: "claude-opus-4-8", tokens: tokens(410_000), cost: 11.62, eventCount: 201),
                ],
                estimatedPricingModels: []
            ),
            notesKey: ProjectScopedRollup(
                projectKey: notesKey,
                displayName: "notes",
                today: .init(tokens: .zero, cost: 0, eventCount: 0),
                last7Days: .init(tokens: tokens(8_000), cost: 0.24, eventCount: 4),
                last30Days: .init(tokens: tokens(42_000), cost: 1.08, eventCount: 19),
                allTime: .init(tokens: tokens(42_000), cost: 1.08, eventCount: 19),
                byDay: scopedByDay(scale: 0.04),
                session: nil,
                byModel: [
                    ModelRollup(model: "claude-haiku-4-5", tokens: tokens(42_000), cost: 1.08, eventCount: 19),
                ],
                estimatedPricingModels: []
            ),
        ]

        return RollupSnapshot(
            today: .init(tokens: tokens(52_000), cost: 1.64, eventCount: 34),
            last7Days: .init(tokens: tokens(410_000), cost: 12.90, eventCount: 210),
            last30Days: .init(tokens: tokens(1_100_000), cost: 36.90, eventCount: 620),
            allTime: .init(tokens: tokens(1_312_000), cost: 41.10, eventCount: 720),
            byProject: byProject,
            byModel: byModel,
            byDay: byDay,
            session: session,
            activeProject: "claude-stats-dynamic-island",
            unknownModels: [],
            estimatedPricingModels: ["claude-fable-5"],
            crossFileDuplicatesDropped: 764,
            generatedAt: now,
            scopedByProject: scopedByProject,
            activeProjectKey: dynamicIslandKey
        )
    }

    /// Same figures as `sample`, but idle (D6a: `session == nil`, never a stale session) —
    /// globally and for the active project's own scoped rollup, so the two stay consistent.
    static func sampleIdle(now: Date = Date()) -> RollupSnapshot {
        var snapshot = sample(now: now)
        snapshot.session = nil
        if let activeKey = snapshot.activeProjectKey {
            snapshot.scopedByProject[activeKey]?.session = nil
        }
        return snapshot
    }

    static func sampleEmpty(now: Date = Date()) -> RollupSnapshot {
        RollupSnapshot(
            today: .init(tokens: .zero, cost: 0, eventCount: 0),
            last7Days: .init(tokens: .zero, cost: 0, eventCount: 0),
            last30Days: .init(tokens: .zero, cost: 0, eventCount: 0),
            allTime: .init(tokens: .zero, cost: 0, eventCount: 0),
            byProject: [],
            byModel: [],
            byDay: [],
            session: nil,
            activeProject: nil,
            unknownModels: [],
            estimatedPricingModels: [],
            crossFileDuplicatesDropped: 0,
            generatedAt: now,
            scopedByProject: [:],
            activeProjectKey: nil
        )
    }

    /// Same as `sample`, but with 14 projects (E11: exercises `ProjectsView`'s top-10 cap
    /// plus the trailing "+N more" row). Cost-desc, matching the aggregator's contract (D6).
    /// Each project also gets a real `ProjectScopedRollup` (D9's dense 30-day `byDay` window
    /// reused verbatim from the global series) so this snapshot's scoped path is honest too.
    static func sampleManyProjects(now: Date = Date()) -> RollupSnapshot {
        var snapshot = sample(now: now)
        let projects: [ProjectRollup] = (0..<14).map { index in
            let cost = 24.0 - Double(index) * 1.6
            let total = Int(cost * 34_000)
            return ProjectRollup(
                projectKey: "-Users-ziad-project-\(index)",
                displayName: "project-\(index)",
                tokens: TokenCounts(input: total * 4 / 10, output: total * 3 / 10, cacheWrite5m: total / 10, cacheWrite1h: total / 20, cacheRead: total * 15 / 100),
                cost: cost,
                eventCount: 40 - index
            )
        }
        snapshot.byProject = projects
        snapshot.scopedByProject = Dictionary(uniqueKeysWithValues: projects.map { project in
            (project.projectKey, ProjectScopedRollup(
                projectKey: project.projectKey,
                displayName: project.displayName,
                today: .init(tokens: .zero, cost: 0, eventCount: 0),
                last7Days: .init(tokens: project.tokens, cost: project.cost, eventCount: project.eventCount),
                last30Days: .init(tokens: project.tokens, cost: project.cost, eventCount: project.eventCount),
                allTime: .init(tokens: project.tokens, cost: project.cost, eventCount: project.eventCount),
                byDay: snapshot.byDay,
                session: nil,
                byModel: [],
                estimatedPricingModels: []
            ))
        })
        snapshot.activeProjectKey = projects.first?.projectKey
        snapshot.activeProject = projects.first?.displayName
        return snapshot
    }
}

#Preview("Loading") {
    PopoverRootView(snapshot: nil, isLoading: true, lastRefresh: nil, selectedProjectKey: nil, onSelectProject: { _ in }, onRefresh: {}, onQuit: {})
}

#Preview("Empty") {
    PopoverRootView(snapshot: .sampleEmpty(), isLoading: false, lastRefresh: Date(), selectedProjectKey: nil, onSelectProject: { _ in }, onRefresh: {}, onQuit: {})
}

#Preview("Populated - Auto") {
    PopoverRootView(snapshot: .sample(), isLoading: false, lastRefresh: Date(), selectedProjectKey: nil, onSelectProject: { _ in }, onRefresh: {}, onQuit: {})
}

#Preview("Populated - Idle") {
    PopoverRootView(snapshot: .sampleIdle(), isLoading: false, lastRefresh: Date().addingTimeInterval(-90), selectedProjectKey: nil, onSelectProject: { _ in }, onRefresh: {}, onQuit: {})
}

/// D8a: a manual pick that isn't the auto-followed active project — the header shows
/// "esca-platform" (not "claude-stats-dynamic-island"), Summary scopes to it (no `≈`, it has
/// no estimated-rate models), and the Projects tab still marks that row selected.
#Preview("Populated - Manually Scoped") {
    PopoverRootView(snapshot: .sample(), isLoading: false, lastRefresh: Date(), selectedProjectKey: "-Volumes-SSD-Workspace-esca-platform", onSelectProject: { _ in }, onRefresh: {}, onQuit: {})
}

/// D9/E9: the pinned project's own `estimatedPricingModels` drives the `≈` here — scope-correct,
/// not the blended global marker.
#Preview("Populated - Scoped Estimated Models") {
    PopoverRootView(snapshot: .sample(), isLoading: false, lastRefresh: Date(), selectedProjectKey: "-Volumes-SSD-Workspace-claude-stats-dynamic-island", onSelectProject: { _ in }, onRefresh: {}, onQuit: {})
}
