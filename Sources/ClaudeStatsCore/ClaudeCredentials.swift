import Foundation
import Security

/// The Claude Code OAuth access token, read-only. We NEVER refresh the token
/// ourselves — refreshing rotates Claude Code's refresh token and could break
/// its login; when it expires, opening Claude Code mints a fresh one.
public struct ClaudeOAuthCredentials: Sendable {
    public let accessToken: String
    public let expiresAt: Date

    public var isExpired: Bool { expiresAt <= Date() }
}

/// Loads credentials from the same places Claude Code writes them: the macOS
/// Keychain item "Claude Code-credentials" (canonical, rotated on refresh) and
/// `~/.claude/.credentials.json` (often stale — expiry-checked before use).
public enum ClaudeCredentialsReader {
    /// Parses the credentials JSON — identical shape in keychain and file:
    /// `{"claudeAiOauth": {"accessToken": "...", "expiresAt": <epoch ms>}}`.
    public static func parse(_ data: Data) throws -> ClaudeOAuthCredentials {
        let wrapper = try JSONDecoder().decode(Wrapper.self, from: data)
        return ClaudeOAuthCredentials(
            accessToken: wrapper.claudeAiOauth.accessToken,
            expiresAt: Date(timeIntervalSince1970: wrapper.claudeAiOauth.expiresAt / 1000)
        )
    }

    /// Keychain first; the file only if the keychain copy is missing or expired.
    /// An expired keychain token still beats nothing — the caller surfaces the
    /// expired state after the server confirms with a 401.
    public static func load() -> ClaudeOAuthCredentials? {
        let keychain = keychainData().flatMap { try? parse($0) }
        if let keychain, !keychain.isExpired { return keychain }
        let fileURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/.credentials.json")
        let file = (try? Data(contentsOf: fileURL)).flatMap { try? parse($0) }
        if let file, !file.isExpired { return file }
        return keychain ?? file
    }

    private static func keychainData() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    private struct Wrapper: Decodable {
        let claudeAiOauth: OAuth

        struct OAuth: Decodable {
            let accessToken: String
            let expiresAt: Double
        }
    }
}
