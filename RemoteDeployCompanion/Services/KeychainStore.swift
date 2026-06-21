// Persists server connection details (URL + bearer token + server name) in the
// iOS Keychain as a single JSON blob under one keychain item.
//
// History:
// - TKT-020 collapsed the legacy 3-item format into one JSON blob.
// - TKT-022/023 gated the read behind LAContext (Face ID / passcode).
// - TKT-066 REMOVED that gate. The .userPresence access control made the saved
//   connection un-storable AND un-readable on devices without a passcode or
//   biometrics (SecItemAdd fails; evaluatePolicy fails with passcodeNotSet),
//   forcing a re-pair on every cold start. The token is now stored plain -- but
//   still device-only and excluded from iCloud/backups
//   (kSecAttrAccessibleWhenUnlockedThisDeviceOnly) -- and read without any prompt.
//
// The decoded credentials are cached in memory after the first successful load(),
// so subsequent load() calls return the cache without a keychain round-trip.
// save() and clear() keep the cache in sync.
import Foundation
import Security
import os

/// Manages Keychain storage for paired server credentials.
final class KeychainStore {

    // MARK: - Constants

    private static let serviceKey = "com.remotedeploy.companion"
    private static let credentialsKey = "credentials"
    private static let installIDKey = "install_id"

    // Legacy keys — retained for the one-time migration from the pre-TKT-020 format.
    private static let legacyURLKey = "server_url"
    private static let legacyTokenKey = "server_token"
    private static let legacyNameKey = "server_name"

    // MARK: - Stored payload

    private struct StoredCredentials: Codable {
        let url: String
        let token: String
        let serverName: String
    }

    // MARK: - In-memory cache

    private struct CachedCredentials {
        let url: String
        let token: String
        let serverName: String
    }

    /// Thread-safe in-memory cache populated by the first successful `load()`.
    /// `save()` and `clear()` keep it in sync.
    private static let lockedCache = OSAllocatedUnfairLock<CachedCredentials?>(initialState: nil)

    /// In-memory cache of the stable install id once read/generated.
    private static let lockedInstallID = OSAllocatedUnfairLock<String?>(initialState: nil)

    // MARK: - Public API

    /// A stable per-install identifier for this companion. Generated once (a random
    /// UUID) and persisted in the Keychain, which survives app reinstalls on iOS, so
    /// the Mac can tell a reinstall of THIS device apart from a genuinely different
    /// device when collapsing duplicate paired-device records. Distinct physical
    /// devices get distinct ids, so "Pair Another Device" keeps both phones paired
    /// (TKT-065/TKT-069). Deliberately NOT cleared by `clear()` (unpair): identity is
    /// per-install, not per-pairing, so an unpair/re-pair of the same phone still
    /// collapses to one record. Never prompts (no auth gate on the item).
    static func installID() -> String {
        if let cached = lockedInstallID.withLock({ $0 }) { return cached }

        if let data = getData(key: installIDKey),
           let existing = String(data: data, encoding: .utf8),
           !existing.isEmpty {
            lockedInstallID.withLock { $0 = existing }
            return existing
        }

        let generated = UUID().uuidString
        setData(key: installIDKey, data: Data(generated.utf8))
        lockedInstallID.withLock { $0 = generated }
        return generated
    }

    /// Saves the server connection details to the Keychain as a single JSON blob
    /// and populates the in-memory cache. Synchronous; safe to call from any thread.
    static func save(url: String, token: String, serverName: String) {
        let credentials = StoredCredentials(url: url, token: token, serverName: serverName)
        guard let data = try? JSONEncoder().encode(credentials) else {
            NSLog("KeychainStore: failed to encode credentials for save")
            return
        }
        setData(key: credentialsKey, data: data)

        lockedCache.withLock { $0 = CachedCredentials(url: url, token: token, serverName: serverName) }
    }

    /// Loads the saved server connection details from the Keychain.
    ///
    /// Returns the in-memory cache if populated; otherwise reads the single-blob
    /// item, falling back to the legacy 3-item format (rewriting it as a blob and
    /// clearing the legacy items). No authentication prompt (TKT-066).
    ///
    /// - Returns: A tuple of (url, token, serverName), or nil if not saved.
    static func load() async -> (url: String, token: String, serverName: String)? {
        // Fast path: in-memory cache.
        if let cached = lockedCache.withLock({ $0 }) {
            return (cached.url, cached.token, cached.serverName)
        }

        // Blob first.
        if let data = getData(key: credentialsKey),
           let decoded = try? JSONDecoder().decode(StoredCredentials.self, from: data) {
            let tuple = (decoded.url, decoded.token, decoded.serverName)
            updateCache(tuple)
            return tuple
        }

        // Legacy migration (pre-TKT-020 3-item format), rewritten as a blob.
        if let legacy = loadLegacy() {
            save(url: legacy.url, token: legacy.token, serverName: legacy.serverName)
            clearLegacy()
            // save() already updates the cache.
            return legacy
        }

        return nil
    }

    /// Reports whether any saved credentials exist WITHOUT reading the secret data.
    /// Lets the connection layer tell "genuinely unpaired" (show the QR screen)
    /// apart from "paired". Requesting attributes (not data) never requires auth,
    /// so this also correctly detects a credential left over from the old
    /// `.userPresence`-gated format.
    static func hasStoredCredentials() -> Bool {
        if lockedCache.withLock({ $0 }) != nil { return true }

        func itemExists(account: String) -> Bool {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: serviceKey,
                kSecAttrAccount as String: account,
                kSecMatchLimit as String: kSecMatchLimitOne,
                kSecReturnAttributes as String: true,
                kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail,
            ]
            var result: AnyObject?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            // errSecSuccess: exists (attributes returned). errSecInteractionNotAllowed:
            // exists but is an old auth-gated item -- still proof it exists.
            return status == errSecSuccess || status == errSecInteractionNotAllowed
        }

        return itemExists(account: credentialsKey) || itemExists(account: legacyURLKey)
    }

    /// Clears all saved server credentials (blob + stray legacy items + cache).
    static func clear() {
        delete(key: credentialsKey)
        clearLegacy()
        lockedCache.withLock { $0 = nil }
    }

    // MARK: - Legacy helpers

    /// Reads the legacy 3-item format (pre-TKT-020).
    private static func loadLegacy() -> (url: String, token: String, serverName: String)? {
        guard let url = getString(key: legacyURLKey),
              let token = getString(key: legacyTokenKey),
              let name = getString(key: legacyNameKey) else {
            return nil
        }
        return (url, token, name)
    }

    /// Deletes any leftover legacy keychain items so a post-migration unpair doesn't
    /// leave stale data behind.
    private static func clearLegacy() {
        delete(key: legacyURLKey)
        delete(key: legacyTokenKey)
        delete(key: legacyNameKey)
    }

    // MARK: - Cache update

    private static func updateCache(_ tuple: (url: String, token: String, serverName: String)) {
        lockedCache.withLock { $0 = CachedCredentials(url: tuple.url, token: tuple.token, serverName: tuple.serverName) }
    }

    // MARK: - Generic keychain helpers

    /// Writes Data to the keychain under the given account key with device-only
    /// accessibility -- not in backups, and readable without any auth prompt
    /// (TKT-066). Deletes any existing item for the key first.
    private static func setData(key: String, data: Data) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceKey,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)

        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus != errSecSuccess {
            NSLog("KeychainStore: SecItemAdd failed for key '\(key)' with status \(addStatus)")
        }
    }

    /// Reads Data from the keychain, or nil if absent/unreadable. Never prompts
    /// (`kSecUseAuthenticationUIFail`): a plain item returns its data; a leftover
    /// `.userPresence`-gated item returns errSecInteractionNotAllowed -> nil, which
    /// triggers a one-time re-pair that rewrites it ungated.
    private static func getData(key: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceKey,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            // errSecItemNotFound (-25300) is the normal "nothing saved" case.
            if status != errSecItemNotFound {
                NSLog("KeychainStore: read failed for key '\(key)' with status \(status)")
            }
            return nil
        }
        return data
    }

    /// Convenience that decodes `getData` as a UTF-8 string. Used by legacy migration.
    private static func getString(key: String) -> String? {
        guard let data = getData(key: key) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Deletes a keychain item.
    private static func delete(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceKey,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
