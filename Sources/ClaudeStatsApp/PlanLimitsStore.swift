import Foundation
import Observation
import ClaudeStatsCore

/// Polls the plan-usage-limits endpoint for the popover's Limits tab: one fetch
/// at launch, then hourly — minute-level polling earned HTTP 429s from the
/// endpoint, so background refresh stays coarse and the header's Refresh button
/// covers "right now" wants. On failure the last good limits stay visible and
/// only `errorText` changes — a flaky network must never blank the tab.
@MainActor
@Observable
final class PlanLimitsStore {
    private(set) var limits: [PlanLimit]?
    private(set) var errorText: String?
    private(set) var lastFetched: Date?

    private let client = PlanLimitsClient()
    private var timer: Timer?
    private var isFetching = false

    func start() {
        refresh()
        let timer = Timer(timeInterval: 3600, repeats: true) { _ in
            Task { @MainActor in self.refresh() }
        }
        // `.common` keeps ticks flowing while menus/popovers hold the run loop in event tracking.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func refresh() {
        guard !isFetching else { return }
        isFetching = true
        Task {
            let result = await client.fetch()
            isFetching = false
            switch result {
            case .success(let fetched):
                limits = fetched
                lastFetched = Date()
                errorText = nil
            case .failure(let error):
                errorText = Self.message(for: error)
            }
        }
    }

    private static func message(for error: PlanLimitsError) -> String {
        switch error {
        case .noCredentials:
            return "No Claude Code login found — sign in to Claude Code first."
        case .tokenExpired:
            return "Login token expired — open Claude Code to refresh it."
        case .http(429):
            return "Rate-limited by the usage endpoint — showing last fetch."
        case .http(let code):
            return "Usage endpoint returned HTTP \(code)."
        case .network:
            return "Usage endpoint unreachable — will keep retrying."
        case .decoding:
            return "Couldn't read the usage response."
        }
    }
}
