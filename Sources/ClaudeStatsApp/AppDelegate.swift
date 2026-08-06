import AppKit
import ClaudeStatsCore

/// Owns the app's long-lived pieces of state: the `UsageStore` (T5 — off-main parsing
/// plus live FSEvents watching), the `StatusItemController` (T7) that surfaces it in the
/// menu bar, and the `IslandController` (D11) that renders the notch-hugging island on the
/// built-in display. Nothing in the app exists before `applicationDidFinishLaunching` fires.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = UsageStore()
    private var statusItemController: StatusItemController?
    private var islandController: IslandController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Build the UI surfaces (and register their observation of `store`) before the first
        // load starts, so no state change is missed.
        statusItemController = StatusItemController(store: store)
        islandController = IslandController(store: store)
        store.start()
    }
}
