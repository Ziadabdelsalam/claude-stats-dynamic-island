import AppKit
import ServiceManagement
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
    private var attentionChime: AttentionChime?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Build the UI surfaces (and register their observation of `store`) before the first
        // load starts, so no state change is missed.
        statusItemController = StatusItemController(store: store)
        islandController = IslandController(store: store)
        attentionChime = AttentionChime(store: store)
        store.start()
        enableLaunchAtLoginOnFirstRun()
    }

    /// One-time opt-in to "open at login" so the island is simply there after a reboot —
    /// the toggle in the status item's right-click menu remains the user's override.
    /// Guarded to real .app runs: registering a bare `swift run` debug binary as a login
    /// item would enshrine a build-directory path in launchd.
    private func enableLaunchAtLoginOnFirstRun() {
        let key = "didAutoEnableLaunchAtLogin"
        guard Bundle.main.bundlePath.hasSuffix(".app"),
              !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        try? SMAppService.mainApp.register()
    }
}
