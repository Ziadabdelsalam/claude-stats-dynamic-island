import AppKit
import SwiftUI
import Observation
import ClaudeStatsCore

/// Owns the `NSStatusItem`, the `NSPopover` it toggles, and the thin container view
/// (`RootView`, below) that bridges the `@Observable` `UsageStore` to `PopoverRootView`'s
/// plain-data initializer (D8) — the only place store and views meet.
///
/// Interaction: left-click toggles the popover (status item stays highlighted while it's
/// open); right-click shows a Refresh/Quit menu. The title is the live compact figure —
/// the *effective* project's today tokens and cost (D9: `store.effectiveScopedRollup`,
/// falling back to the global snapshot when nothing resolves), in D1c form — kept in sync
/// via `withObservationTracking`, re-armed on every fire, since `@Observable`'s change
/// notifications are one-shot. A static (non-animated) accent dot prefixes the title
/// whenever `store.pendingAttention` is non-empty (D11) — the island's animated character
/// is the notch-only surface for that same signal; this is the status item's equivalent for
/// the notchless/external display where the island never renders.
@MainActor
final class StatusItemController: NSObject {
    private let store: UsageStore
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private var outsideClickMonitor: Any?

    private static let titleFont = NSFont.monospacedDigitSystemFont(
        ofSize: NSFont.systemFontSize, weight: .regular
    )

    init(store: UsageStore) {
        self.store = store
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.popover = NSPopover()
        super.init()

        popover.behavior = .transient
        popover.contentSize = NSSize(width: 360, height: 460)
        popover.delegate = self
        popover.contentViewController = NSHostingController(
            rootView: RootView(store: store, onQuit: { NSApp.terminate(nil) })
        )

        if let button = statusItem.button {
            button.title = "Claude Stats"
            button.font = Self.titleFont
            button.action = #selector(statusItemClicked(_:))
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        armObservation()
    }

    // MARK: - Title observation

    /// `withObservationTracking`'s change handler fires exactly once per registration, so it
    /// must be re-armed after every fire to keep tracking. The handler only reads/writes
    /// `store` state that's already `@MainActor`-isolated; hopping through a `Task` defers
    /// the re-registration out of the observation transaction itself, which the framework
    /// asks callers not to mutate state from directly.
    private func armObservation() {
        withObservationTracking {
            _ = store.snapshot
            _ = store.isLoading
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.updateTitle()
                self?.armObservation()
            }
        }
        updateTitle()
    }

    private func updateTitle() {
        guard let button = statusItem.button else { return }
        let text: String
        if let snapshot = store.snapshot {
            let estimated = !snapshot.estimatedPricingModels.isEmpty
            text = "\(snapshot.today.tokens.total.compactTokens) · \(snapshot.today.cost.currency(estimated: estimated))"
        } else if store.isLoading {
            text = "Loading…"
        } else {
            text = "Claude Stats"
        }
        button.attributedTitle = NSAttributedString(string: text, attributes: [.font: Self.titleFont])
    }

    // MARK: - Click handling

    @objc private func statusItemClicked(_ sender: Any?) {
        guard let event = NSApp.currentEvent, event.type == .rightMouseUp else {
            togglePopover()
            return
        }
        // Classic status-item trick: attaching a menu makes `performClick` show it instead of
        // firing our action; detach it right after so the next left click goes back through
        // `statusItemClicked`. `performClick` blocks (synchronous menu tracking) until the
        // menu is dismissed, so it's safe to clear `statusItem.menu` immediately after.
        statusItem.menu = makeMenu()
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        let refresh = menu.addItem(withTitle: "Refresh", action: #selector(refreshTapped), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(.separator())
        let quit = menu.addItem(withTitle: "Quit", action: #selector(quitTapped), keyEquivalent: "q")
        quit.target = self
        return menu
    }

    @objc private func refreshTapped() {
        store.refresh()
    }

    @objc private func quitTapped() {
        NSApp.terminate(nil)
    }

    // MARK: - Popover

    private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.popover.performClose(nil)
        }
    }
}

// MARK: - NSPopoverDelegate

extension StatusItemController: NSPopoverDelegate {
    /// Highlighting has to happen here, not in `showPopover`: the click action runs *inside*
    /// the button's mouse tracking, which clears `isHighlighted` again as soon as it returns.
    func popoverDidShow(_ notification: Notification) {
        statusItem.button?.highlight(true)
    }

    /// Fires on every close path — our outside-click monitor, `.transient`'s own auto-dismiss
    /// (e.g. Escape), and manual `performClose` — so un-highlighting and tearing down the
    /// monitor live in exactly one place.
    func popoverDidClose(_ notification: Notification) {
        statusItem.button?.highlight(false)
        if let monitor = outsideClickMonitor {
            NSEvent.removeMonitor(monitor)
            outsideClickMonitor = nil
        }
    }
}

// MARK: - Container view (D8 seam)

/// The one place `UsageStore` and the popover views meet. `store` is a plain stored property,
/// not `@State`: SwiftUI observes property reads inside `body` for any `@Observable` type
/// automatically, reference-type semantics make that safe here.
private struct RootView: View {
    let store: UsageStore
    let onQuit: () -> Void

    var body: some View {
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
    }
}
