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
            return .failure(http.statusCode == 401 || http.statusCode == 403
                ? .tokenExpired
                : .http(http.statusCode))
        }

        do {
            return .success(try PlanLimitsDecoder.decode(data))
        } catch {
            return .failure(.decoding(error.localizedDescription))
        }
    }
}
