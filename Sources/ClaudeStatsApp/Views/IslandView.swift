import SwiftUI
import ClaudeStatsCore

/// The D11 island's content: the collapsed pill wrapping the camera notch, and the expanded
/// panel hosting `PopoverRootView` (D8a). `IslandController` owns the window/panel and swaps
/// this view's `notchWidth`/`menuBarHeight`/`isExpanded` on every geometry or expand/collapse
/// change; live figures are read straight off `store` (an `@Observable` reference type), the
/// same "container view reads the store directly" seam `StatusItemController`'s `RootView` uses.
struct IslandView: View {
    let store: UsageStore
    let notchWidth: CGFloat
    let menuBarHeight: CGFloat
    let isExpanded: Bool
    let onExpand: () -> Void
    let onCollapse: () -> Void
    let onCharacterTapWhileNudging: (String) -> Void
    let onQuit: () -> Void

    var body: some View {
        // Both states stay mounted and cross-fade/scale under a spring, top-anchored at the
        // notch — a jump-cut `if/else` swap reads as a glitch next to the other notch apps'
        // morphing panels. The AppKit panel frame animates in `IslandController` on a matching
        // curve; whichever state is inactive is inert to clicks.
        ZStack(alignment: .top) {
            collapsedContent
                .opacity(isExpanded ? 0 : 1)
                .allowsHitTesting(!isExpanded)
            expandedContent
                .opacity(isExpanded ? 1 : 0)
                .scaleEffect(isExpanded ? 1 : 0.96, anchor: .top)
                .allowsHitTesting(isExpanded)
        }
        // Fill the window exactly, always: the panel keeps one constant frame
        // (`IslandController.islandFrame`) and this root stretches to it, so the hosting view
        // never has to place a mismatched-size root — the exact ambiguity that used to nudge
        // the island sideways off the notch on expand/collapse. `.top` keeps both states
        // hanging from the notch, centered.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.spring(response: 0.32, dampingFraction: 0.85), value: isExpanded)
    }

    // MARK: - Collapsed (D11 collapsed spec + D12/E18 character)

    private var effectiveScopedRollup: ProjectScopedRollup? {
        store.effectiveScopedRollup
    }

    private var effectiveTodayTokens: Int {
        (effectiveScopedRollup?.today ?? store.snapshot?.today)?.tokens.total ?? 0
    }

    private var effectiveTodayCost: Double {
        (effectiveScopedRollup?.today ?? store.snapshot?.today)?.cost ?? 0
    }

    private var effectiveIsEstimated: Bool {
        !(effectiveScopedRollup?.estimatedPricingModels ?? store.snapshot?.estimatedPricingModels ?? []).isEmpty
    }

    private var characterState: CharacterState {
        store.pendingAttention.isEmpty ? .idle : .nudging
    }

    @State private var isHoveringCollapsed = false
    /// Monotonic tokens invalidating any in-flight hover dwell / exit-grace sleep the moment the
    /// pointer state changes again — the Task-based equivalent of cancelling a timer.
    @State private var hoverDwellToken = 0
    @State private var exitGraceToken = 0
    /// When `characterState` last flipped to or from `.nudging` — the start time of the
    /// character's walk out to (or back from) the middle of the notch.
    @State private var nudgeChangedAt: Date?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Width of each wing flanking the notch. Kept tight so the pill's corners sit right at the
    /// notch corners rather than sprawling across the menu bar. `IslandController` derives the
    /// panel frame from this same constant so the window and the SwiftUI layout never disagree.
    static let wingWidth: CGFloat = 72

    private var collapsedWidth: CGFloat { notchWidth + 2 * Self.wingWidth }

    private var collapsedContent: some View {
        // The character lives OUTSIDE the pill's clip: while nudging it hangs below the
        // menu bar off the notch's bottom edge, and clipping to the pill would decapitate that.
        ZStack(alignment: .top) {
            pillRow
            wanderingCharacter
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: collapsedWidth, alignment: .top)
    }

    private var pillRow: some View {
        HStack(spacing: 0) {
            leftWing
                .frame(width: Self.wingWidth, height: menuBarHeight)
            // Exactly `notchWidth` (D11) — the camera housing itself sits here; the black fill
            // either side of it visually continues underneath.
            Color.clear
                .frame(width: notchWidth, height: menuBarHeight)
            rightWing
                .frame(width: Self.wingWidth, height: menuBarHeight)
        }
        .frame(width: collapsedWidth, height: menuBarHeight)
        .background(
            Color.black.overlay(isHoveringCollapsed ? Color.white.opacity(0.06) : .clear)
        )
        .clipShape(collapsedShape)
        // Hover-to-open, the established notch-app interaction: a short dwell filters out the
        // pointer merely passing across the top of the screen. A click still opens immediately.
        .onHover { hovering in
            isHoveringCollapsed = hovering
            hoverDwellToken += 1
            guard hovering else { return }
            let token = hoverDwellToken
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 120_000_000)
                guard token == hoverDwellToken, isHoveringCollapsed else { return }
                // While the character is parked on its tab asking for attention, hovering in
                // opens the island already scoped to the waiting project (D12) — the user is
                // reaching for the beacon, not the generic pill.
                if let attention = store.pendingAttention.first {
                    onCharacterTapWhileNudging(attention.projectKey)
                } else {
                    onExpand()
                }
            }
        }
        .contentShape(collapsedShape)
        .onTapGesture(perform: onExpand)
        .animation(.easeInOut(duration: 0.12), value: isHoveringCollapsed)
    }


    private var collapsedShape: some Shape {
        UnevenRoundedRectangle(cornerRadii: RectangleCornerRadii(
            topLeading: 0, bottomLeading: 10, bottomTrailing: 10, topTrailing: 0
        ))
    }

    /// Tighter than `Theme.Spacing.sm`: the wing is only `wingWidth` points wide, and every
    /// point given up on the left is a point of the token figure sliding under the notch.
    private static let characterInset: CGFloat = 4

    private var leftWing: some View {
        HStack(spacing: 4) {
            characterSlot
            Text(effectiveTodayTokens.compactTokens)
                .font(Theme.Typography.numeric(11))
                .foregroundStyle(Theme.Color.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Spacer(minLength: 0)
        }
        .padding(.leading, Self.characterInset)
    }

    /// E18: the character's 24×24 home slot in the left wing. The slot itself is an invisible
    /// tap target — the visible character is drawn by `wanderingCharacter` so it can hop away
    /// from home without disturbing the wing's layout. The tap here takes priority over the
    /// whole-pill toggle-expand gesture (D12: a nudging tap pins the scope to the waiting
    /// project and expands onto it, rather than merely expanding).
    private var characterSlot: some View {
        Color.clear
            .frame(width: 24, height: 24)
            .contentShape(Rectangle())
            .highPriorityGesture(
                TapGesture().onEnded {
                    guard let attention = store.pendingAttention.first else { return }
                    onCharacterTapWhileNudging(attention.projectKey)
                }
            )
    }

    /// The visible character, overlaid on the whole pill so it can roam. Idle: rest in the
    /// slot, with a periodic hop across the notch and back (`roamOffset`). Nudging (a session
    /// finished or is asking something): hop out and STOP at the middle of the notch, bouncing
    /// and glowing there with expanding ripple rings until the attention is handled — the
    /// character itself is the notification. When the nudge clears it hops home. All pure clock
    /// math off `TimelineView`; only the nudge walk needs a start time (`nudgeChangedAt`).
    /// While nudging the character is tappable (D12) — the tap pins the waiting project.
    private var wanderingCharacter: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let motion = characterMotion(now: context.date, t: t)
            ZStack {
                if motion.ripple {
                    // Two staggered rings expanding out of the character and fading — the
                    // "notice me" beacon once it has parked mid-notch.
                    ForEach(0..<2, id: \.self) { ring in
                        let phase = reduceMotion
                            ? 0.45
                            : ((t / 1.6) + Double(ring) * 0.5).truncatingRemainder(dividingBy: 1)
                        Circle()
                            .stroke(Theme.Color.accent.opacity((1 - phase) * 0.55), lineWidth: 1.5)
                            .frame(width: 24, height: 24)
                            .scaleEffect(0.6 + 0.85 * phase)
                    }
                }
                ClaudeCharacterView(state: characterState)
                    .frame(width: 24, height: 24)
                    // Upside down while parked under the notch: feet planted on the notch's
                    // bottom edge, standing on it like a ceiling. The flip runs through the
                    // descent, so it somersaults into place (and back on the way home).
                    .scaleEffect(x: 1, y: motion.flip)
            }
            .offset(x: motion.offset.width, y: motion.offset.height)
            .contentShape(Rectangle())
            .onTapGesture {
                guard let attention = store.pendingAttention.first else { return }
                onCharacterTapWhileNudging(attention.projectKey)
            }
        }
        // Home position: leading edge inset by `characterInset`, vertically centered in the
        // menu bar — the same spot `characterSlot` reserves in the left wing.
        .padding(.leading, Self.characterInset)
        .padding(.top, (menuBarHeight - 24) / 2)
        // Hit-testable only while nudging, so the parked character is clickable on its tab;
        // idle, pill taps fall through to `characterSlot`/the pill as before.
        .allowsHitTesting(characterState == .nudging)
        .onChange(of: characterState == .nudging) { _, _ in nudgeChangedAt = Date() }
    }

    /// Where the character is right now, whether the ripple beacon should show, and its
    /// vertical flip (1 upright ... -1 upside down, standing on the notch's bottom edge).
    private func characterMotion(now: Date, t: Double) -> (offset: CGSize, ripple: Bool, flip: CGFloat) {
        // Home: character's leading edge sits at `characterInset`, centered in the bar.
        // Parked: centered under the notch, upside down with its feet ON the notch's bottom
        // edge — the notch interior itself is the camera cutout, physically invisible, so the
        // character hangs just below it, against transparent screen.
        let centerDX = Self.wingWidth + notchWidth / 2 - 12 - Self.characterInset
        let parkedDY = menuBarHeight / 2 + 12  // home center (mb/2) -> feet at mb, center mb+12
        let legDuration = 1.4
        let isNudging = characterState == .nudging

        if reduceMotion {
            return (
                CGSize(width: isNudging ? centerDX : 0, height: isNudging ? parkedDY : 0),
                isNudging,
                isNudging ? -1 : 1
            )
        }
        if isNudging {
            // Walk out: three hops toward the notch, sinking below it as it arrives — the
            // descent and the somersault are both weighted to the end (`p²`) so it drops out
            // of the notch's bottom edge and lands feet-up.
            guard let nudgeChangedAt else { return (CGSize(width: centerDX, height: parkedDY), true, -1) }
            let p = min(1, now.timeIntervalSince(nudgeChangedAt) / legDuration)
            let (x, y) = Self.leg(p, hopCount: 3)
            return (CGSize(width: centerDX * x, height: y + parkedDY * p * p), p >= 1, Self.flip(p * p))
        }
        if let nudgeChangedAt {
            // Nudge just cleared: same three hops, homeward, righting itself on the climb.
            let elapsed = now.timeIntervalSince(nudgeChangedAt)
            if elapsed < legDuration {
                let p = elapsed / legDuration
                let (x, y) = Self.leg(p, hopCount: 3)
                let back = (1 - p) * (1 - p)
                return (CGSize(width: centerDX * (1 - x), height: y + parkedDY * back), false, Self.flip(back))
            }
        }
        let roam = Self.roamOffset(
            t: t,
            travel: notchWidth + 2 * Self.wingWidth - 2 * Self.characterInset - 24,
            dipStart: Self.wingWidth - 34,
            dipDepth: parkedDY
        )
        return (roam.offset, false, roam.flip)
    }

    /// Maps flip progress 0...1 onto a y-scale of 1...-1, clamped away from the exactly-flat
    /// zero crossing (a singular transform SwiftUI won't render).
    private static func flip(_ progress: Double) -> CGFloat {
        let scale = 1 - 2 * min(max(progress, 0), 1)
        return abs(scale) < 0.02 ? (scale < 0 ? -0.02 : 0.02) : scale
    }

    /// One leg of travel as `hopCount` parabolic arcs: returns linear x-progress and the hop's
    /// upward y-offset. The peak stays within the pill's ~6pt of headroom above the character.
    private static func leg(_ progress: Double, hopCount: Int) -> (x: Double, y: Double) {
        let clamped = min(max(progress, 0), 1)
        let hopPhase = (clamped * Double(hopCount)).truncatingRemainder(dividingBy: 1)
        return (clamped, -6.0 * 4 * hopPhase * (1 - hopPhase))
    }

    /// The idle roam cycle, as a pure function of the shared clock: rest at home (far left,
    /// beside the token figure — the character's only indoor spot) for most of the 16s
    /// period, then hop the FULL length of the bar from the outside: across the left wing,
    /// dip and flip feet-up at the notch's left corner, then stay on the underside the rest
    /// of the way — under the housing AND under the money section, never inside it — to the
    /// bar's far end, a beat there, then the same trip home.
    private static func roamOffset(
        t: Double, travel: CGFloat, dipStart: CGFloat, dipDepth: CGFloat
    ) -> (offset: CGSize, flip: CGFloat) {
        let period = 16.0
        let phase = t.truncatingRemainder(dividingBy: period)

        let progressAndHop: (x: Double, y: Double)
        switch phase {
        case ..<9.0:
            progressAndHop = (0, 0)
        case ..<11.4:  // out: the full bar, around the notch's underside on the way
            progressAndHop = leg((phase - 9.0) / 2.4, hopCount: 4)
        case ..<12.6:  // a beat hanging off the bar's far end
            progressAndHop = (1, 0)
        case ..<15.0:  // home: the same trip back to the token figure
            let (x, y) = leg((phase - 12.6) / 2.4, hopCount: 4)
            progressAndHop = (1 - x, y)
        default:
            progressAndHop = (0, 0)
        }

        let dx = travel * progressAndHop.x
        // 0 in the home wing -> 1 from the notch's left corner onward: once it leaves home
        // it stays on the underside for the whole rest of the bar (the money side is walked
        // outside only).
        let dip = min(max((dx - dipStart) / 18, 0), 1)
        // Hops flip with the character: upside down on the notch's underside, a hop moves
        // AWAY from the edge it stands on, not into the housing.
        let dy = dipDepth * dip + progressAndHop.y * (1 - 2 * dip)
        return (CGSize(width: dx, height: dy), flip(dip))
    }

    private var rightWing: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            Text(effectiveTodayCost.currency(estimated: effectiveIsEstimated))
                .font(Theme.Typography.numeric(11))
                .foregroundStyle(Theme.Color.textPrimary)
                .lineLimit(1)
        }
        .padding(.trailing, Theme.Spacing.sm)
    }

    // MARK: - Expanded (D11: 420 × menuBarHeight+460, bottom radius 24, hosts PopoverRootView)

    private var expandedContent: some View {
        VStack(spacing: 0) {
            // The menu-bar-height strip is only as wide as the notch and stays clear: it sits
            // entirely behind the physical camera cutout, where nothing can render anyway. A
            // full-width black band here would paint over the menu bar either side of the notch.
            Color.clear
                .frame(width: notchWidth, height: menuBarHeight)
            PopoverRootView(
                snapshot: store.snapshot,
                isLoading: store.isLoading,
                lastRefresh: store.lastRefresh,
                currentTask: store.effectiveCurrentTask,
            sessionStatuses: store.sessionStatusesByProject,
            activeProjectKeys: store.activeProjectKeys,
                selectedProjectKey: store.selectedProjectKey,
                onSelectProject: { store.selectedProjectKey = $0 },
                onRefresh: { store.refresh() },
                onQuit: onQuit
            )
            // Exactly `PopoverRootView`'s own width — any wider and the popover floats
            // between black margins inside the panel.
            .frame(width: Theme.Layout.popoverWidth, height: 460)
            .background(Color.black)
            .clipShape(
                UnevenRoundedRectangle(cornerRadii: RectangleCornerRadii(
                    topLeading: 12, bottomLeading: 24, bottomTrailing: 24, topTrailing: 12
                ))
            )
        }
        .frame(width: Theme.Layout.popoverWidth, height: menuBarHeight + 460, alignment: .top)
        // The hover-out counterpart to the pill's hover-to-open: leaving the whole expanded
        // rect starts a grace period, so grazing the panel's edge doesn't slam it shut; the
        // outside-click monitor in `IslandController` still closes it instantly on click.
        .onHover { hovering in
            exitGraceToken += 1
            guard !hovering, isExpanded else { return }
            let token = exitGraceToken
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 350_000_000)
                if token == exitGraceToken { onCollapse() }
            }
        }
    }
}
