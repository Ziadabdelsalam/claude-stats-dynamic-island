import AppKit
import SwiftUI
import ClaudeStatsCore

/// Owns the D11 "Dynamic Island" panel: a borderless, non-activating `NSPanel` that renders
/// around the camera notch on the built-in display, collapsed to a pill hugging the notch and
/// expanding on click into the full `PopoverRootView` (D8a).
///
/// The `NSStatusItem` (`StatusItemController`) is the permanent surface — it exists on every
/// display, notched or not. This controller is additive: on a screen with no notch (the
/// external, notchless display in the round-2 environment facts) `targetScreen`/`geometry`
/// resolve to `nil` and the panel simply stays ordered out, leaving the status item as the
/// only surface there.
@MainActor
final class IslandController: NSObject {
    private let store: UsageStore
    private let panel: IslandPanel
    private let hostingView: NSHostingView<IslandView>

    private var isExpanded = false
    private var targetScreen: NSScreen?
    private var geometry: Geometry?
    private var outsideClickMonitor: Any?
    private var screenObserver: Any?

    /// The two derived measurements D11 requires: never a hardcoded notch width.
    /// `notchWidth` = the screen's full width minus both auxiliary safe areas either side of the
    /// camera housing; `menuBarHeight` = the screen's own top safe-area inset.
    struct Geometry {
        var notchWidth: CGFloat
        var menuBarHeight: CGFloat
    }

    init(store: UsageStore) {
        self.store = store
        self.panel = IslandPanel()
        // A throwaway first `rootView` — real content is built by `updateContent()` right after
        // `super.init()`, once `self` is fully usable inside the closures below.
        self.hostingView = FirstMouseHostingView(rootView: IslandView(
            store: store, notchWidth: 0, menuBarHeight: 0, isExpanded: false,
            onExpand: {}, onCollapse: {}, onCharacterTapWhileNudging: { _ in }, onQuit: {}
        ))
        super.init()

        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]

        hostingView.autoresizingMask = [.width, .height]
        panel.contentView = hostingView

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.relayout() }
        }

        updateContent()
        relayout()
    }

    // No deinit: Swift 6 forbids touching the @MainActor-isolated, non-Sendable observers from a
    // nonisolated deinit. This controller lives for the whole process, so `screenObserver` and
    // `outsideClickMonitor` are left for process teardown — the same tolerance
    // `StatusItemController` and `UsageStore`'s watcher already rely on.

    // MARK: - Screen targeting + geometry (D11)

    /// "Target screen = first with `safeAreaInsets.top > 0`" — verbatim.
    private static func notchedScreen() -> NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 }
    }

    /// Geometry is DERIVED from the screen every time, never a stored/hardcoded constant.
    /// A screen reporting `safeAreaInsets.top > 0` but no auxiliary areas (shouldn't happen in
    /// practice, but AppKit gives these back as optionals) is treated the same as "no notch".
    private static func geometry(for screen: NSScreen) -> Geometry? {
        guard let auxLeft = screen.auxiliaryTopLeftArea, let auxRight = screen.auxiliaryTopRightArea else {
            return nil
        }
        let notchWidth = screen.frame.width - auxLeft.width - auxRight.width
        let menuBarHeight = screen.safeAreaInsets.top
        return Geometry(notchWidth: notchWidth, menuBarHeight: menuBarHeight)
    }

    /// One constant frame covering the island's full footprint (the larger of the pill and the
    /// expanded panel), centered on the notch. The window NEVER moves or resizes after this —
    /// every past variant that resized the window on expand/collapse hit the same bug: whenever
    /// the SwiftUI root's size disagreed with the window's for even a frame, AppKit's placement
    /// of the mismatch nudged the content sideways off the notch. All expand/collapse motion is
    /// SwiftUI-internal; the uncovered regions are transparent and pass clicks through.
    private static func islandFrame(screen: NSScreen, geometry: Geometry) -> NSRect {
        let width = max(geometry.notchWidth + 2 * IslandView.wingWidth, Theme.Layout.popoverWidth)
        let height = geometry.menuBarHeight + 460
        let x = screen.frame.midX - width / 2
        let y = screen.frame.maxY - height
        return NSRect(x: x, y: y, width: width, height: height)
    }

    /// Re-resolves the target screen and geometry (called on init and on
    /// `didChangeScreenParametersNotification`, per D11) and re-applies the current frame.
    /// Collapses first so an in-progress expansion never gets stranded on a screen change.
    private func relayout() {
        collapse()

        guard let screen = Self.notchedScreen(), let geometry = Self.geometry(for: screen) else {
            targetScreen = nil
            self.geometry = nil
            panel.orderOut(nil)
            return
        }
        targetScreen = screen
        self.geometry = geometry
        updateContent()
        panel.setFrame(Self.islandFrame(screen: screen, geometry: geometry), display: true)
        panel.orderFrontRegardless()
    }

    // MARK: - Expand / collapse

    private func expand() {
        guard !isExpanded else { return }
        isExpanded = true
        updateContent()
        armOutsideClickMonitor()
        panel.makeKey()
    }

    private func collapse() {
        guard isExpanded else { return }
        isExpanded = false
        updateContent()
        disarmOutsideClickMonitor()
    }

    /// Character-click-while-nudging (D12): pins the scope to the waiting project and expands
    /// onto it, regardless of the current expand/collapse state.
    private func jumpToAttentionProject(_ projectKey: String) {
        store.selectedProjectKey = projectKey
        guard !isExpanded else { return }
        isExpanded = true
        updateContent()
        armOutsideClickMonitor()
        panel.makeKey()
    }

    /// Outside-click collapse — same global-monitor pattern `StatusItemController` uses for the
    /// popover (D11: "event-monitor pattern from v1").
    private func armOutsideClickMonitor() {
        guard outsideClickMonitor == nil else { return }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.collapse() }
        }
    }

    private func disarmOutsideClickMonitor() {
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
        }
        outsideClickMonitor = nil
    }

    // MARK: - Content

    private func updateContent() {
        hostingView.rootView = IslandView(
            store: store,
            notchWidth: geometry?.notchWidth ?? 0,
            menuBarHeight: geometry?.menuBarHeight ?? 0,
            isExpanded: isExpanded,
            onExpand: { [weak self] in self?.expand() },
            onCollapse: { [weak self] in self?.collapse() },
            onCharacterTapWhileNudging: { [weak self] projectKey in self?.jumpToAttentionProject(projectKey) },
            onQuit: { NSApp.terminate(nil) }
        )
    }
}

/// Borderless + non-activating per D11, but must still be able to receive mouse/key events for
/// the expanded popover's controls (the picker menu, refresh, quit) without ever stealing app
/// activation on click — `NSWindow.canBecomeKey` defaults to `false` for a borderless window, so
/// it's overridden explicitly here.
/// The pill lives in a non-key, non-activating panel, and AppKit treats the first click into a
/// non-key window as "first mouse" — by default it only brings the window forward and never
/// reaches the view, which is why opening the island used to take two clicks. Accepting first
/// mouse delivers that initial click straight to the SwiftUI gestures.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class IslandPanel: NSPanel {
    convenience init() {
        self.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
    }

    override var canBecomeKey: Bool { true }
}
