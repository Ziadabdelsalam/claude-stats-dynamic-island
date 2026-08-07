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
///
/// Prompt hygiene: the keychain item belongs to Claude Code, so reads by this
/// app can trigger the "wants to use your confidential information" dialog.
/// Two measures keep that to at most one prompt ever, instead of one per poll:
/// results are cached in memory until the token expires (or a 401 invalidates
/// them), and the read goes through `/usr/bin/security` — Apple's own binary,
/// which the keychain typically already trusts durably — with the in-process
/// Security API only as a last resort.
public enum ClaudeCredentialsReader {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var memoryCache: ClaudeOAuthCredentials?
    /// Parses the credentials JSON — identical shape in keychain and file:
    /// `{"claudeAiOauth": {"accessToken": "...", "expiresAt": <epoch ms>}}`.
    public static func parse(_ data: Data) throws -> ClaudeOAuthCredentials {
        let wrapper = try JSONDecoder().decode(Wrapper.self, from: data)
        return ClaudeOAuthCredentials(
            accessToken: wrapper.claudeAiOauth.accessToken,
            expiresAt: Date(timeIntervalSince1970: wrapper.claudeAiOauth.expiresAt / 1000)
        )
    }

    /// A valid cached token short-circuits everything — no keychain traffic at
    /// all on the steady-state poll. Otherwise: keychain first, the file only if
    /// the keychain copy is missing or expired. An expired token still beats
    /// nothing — the caller surfaces the expired state after the server
    /// confirms with a 401.
    public static func load() -> ClaudeOAuthCredentials? {
        lock.lock()
        if let cached = memoryCache, !cached.isExpired {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let fresh = readFromSources()
        if let fresh, !fresh.isExpired {
            lock.lock()
            memoryCache = fresh
            lock.unlock()
        }
        return fresh
    }

    /// Called when the server rejects the token (401): Claude Code has rotated
    /// it, so the next `load()` must go back to the keychain.
    public static func invalidateCache() {
        lock.lock()
        memoryCache = nil
        lock.unlock()
    }

    private static func readFromSources() -> ClaudeOAuthCredentials? {
        let cli = securityCLIData().flatMap { try? parse($0) }
        if let cli, !cli.isExpired { return cli }
        let fileURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/.credentials.json")
        let file = (try? Data(contentsOf: fileURL)).flatMap { try? parse($0) }
        if let file, !file.isExpired { return file }
        let secItem = secItemData().flatMap { try? parse($0) }
        if let secItem, !secItem.isExpired { return secItem }
        return cli ?? file ?? secItem
    }

    /// Reads the item by spawning `/usr/bin/security`. The keychain ACL check
    /// applies to the *security* binary — Apple-signed and stable — so a grant
    /// to it survives this app being rebuilt/updated, unlike a grant to our
    /// ad-hoc-signed bundle, which macOS forgets on every new binary.
    private static func securityCLIData() -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        var data = stdout.fileHandleForReading.readDataToEndOfFile()
        if data.last == 0x0A { data.removeLast() }
        return data.isEmpty ? nil : data
    }

    /// In-process Security API — the path that shows the per-app permission
    /// dialog, kept only as the last fallback.
    private static func secItemData() -> Data? {
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
