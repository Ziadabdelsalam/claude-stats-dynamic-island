import Foundation

public enum PlanLimitsError: Error, Equatable {
    case noCredentials
    case tokenExpired
    case http(Int)
    case network(String)
    case decoding(String)
}

/// Fetches plan usage limits from the OAuth usage endpoint — the source the
/// Claude Desktop menu bar app reads. Auth is the locally stored Claude Code
/// token; even a locally-expired token is still sent (the server is
/// authoritative) and a 401/403 maps to `.tokenExpired`.
public struct PlanLimitsClient: Sendable {
    private static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    public init() {}

    public func fetch() async -> Result<[PlanLimit], PlanLimitsError> {
        await fetch(allowRetry: true)
    }

    /// A 401 means the cached token was rotated out from under us — invalidate
    /// the cache and retry exactly once with a freshly loaded token before
    /// reporting `.tokenExpired`.
    private func fetch(allowRetry: Bool) async -> Result<[PlanLimit], PlanLimitsError> {
        guard let credentials = ClaudeCredentialsReader.load() else {
            return .failure(.noCredentials)
        }
        var request = URLRequest(url: Self.endpoint)
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.timeoutInterval = 15

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            return .failure(.network(error.localizedDescription))
        }

        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            guard http.statusCode == 401 || http.statusCode == 403 else {
                return .failure(.http(http.statusCode))
            }
            ClaudeCredentialsReader.invalidateCache()
            if allowRetry,
               let fresh = ClaudeCredentialsReader.load(),
               fresh.accessToken != credentials.accessToken {
                return await fetch(allowRetry: false)
            }
            return .failure(.tokenExpired)
        }

        do {
            return .success(try PlanLimitsDecoder.decode(data))
        } catch {
            return .failure(.decoding(error.localizedDescription))
        }
    }
}
