// Persists server connection details (URL + bearer token + server name) in
// the iOS Keychain as a single JSON blob under one keychain item. Keeping
// all three fields in one item means a read only triggers a single
// .userPresence challenge (biometric / passcode) at cold launch, not three.
// See TKT-020.
//
// Legacy migration: earlier builds stored the three fields as separate
// keychain items (server_url, server_token, server_name). On first launch
// after upgrade, load() reads the legacy items (3 prompts, one-time),
// writes them as the new blob, and deletes the legacy items. Subsequent
// launches hit the blob path and only prompt once.
import Foundation
import Security

/// Manages Keychain storage for paired server credentials.
final class KeychainStore {

    // MARK: - Constants

    private static let serviceKey = "com.remotedeploy.companion"
    private static let credentialsKey = "credentials"

    // Legacy keys — retained for the one-time migration from the 3-item format.
    private static let legacyURLKey = "server_url"
    private static let legacyTokenKey = "server_token"
    private static let legacyNameKey = "server_name"

    // MARK: - Stored payload

    /// Single keychain payload holding all three fields. Encoded as JSON.
    private struct StoredCredentials: Codable {
        let url: String
        let token: String
        let serverName: String
    }

    // MARK: - Public API

    /// Saves the server connection details to the Keychain as a single JSON blob.
    ///
    /// - Parameter url: The server's base URL.
    /// - Parameter token: The bearer token for API authentication.
    /// - Parameter serverName: The display name of the Mac server.
    static func save(url: String, token: String, serverName: String) {
        let credentials = StoredCredentials(url: url, token: token, serverName: serverName)
        guard let data = try? JSONEncoder().encode(credentials) else {
            NSLog("KeychainStore: failed to encode credentials for save")
            return
        }
        setData(key: credentialsKey, data: data)
    }

    /// Loads the saved server connection details from the Keychain.
    ///
    /// Reads the single-blob item first (1 biometric prompt). If that's not present,
    /// falls back to the legacy 3-item format (3 prompts, one-time), rewrites the
    /// data as the new blob, and deletes the legacy items.
    ///
    /// - Returns: A tuple of (url, token, serverName), or nil if not saved.
    static func load() -> (url: String, token: String, serverName: String)? {
        // Fast path: new single-blob format.
        if let data = getData(key: credentialsKey),
           let credentials = try? JSONDecoder().decode(StoredCredentials.self, from: data) {
            return (credentials.url, credentials.token, credentials.serverName)
        }

        // Migration path: read the legacy 3-item format if present, rewrite as blob,
        // delete the legacy items so the next launch takes the fast path.
        if let legacy = loadLegacy() {
            save(url: legacy.url, token: legacy.token, serverName: legacy.serverName)
            clearLegacy()
            return legacy
        }

        return nil
    }

    /// Clears all saved server credentials (new blob + any stray legacy items).
    static func clear() {
        delete(key: credentialsKey)
        clearLegacy()
    }

    // MARK: - Legacy helpers

    /// Reads the legacy 3-item format. Triggers 3 biometric prompts (one per item).
    /// Only called on first launch after upgrade.
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

    // MARK: - Generic keychain helpers

    /// Writes arbitrary Data to the keychain under the given account key, applying
    /// `.userPresence` access control on device (and a simulator fallback that
    /// doesn't require biometrics).
    private static func setData(key: String, data: Data) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceKey,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)

        var addQuery = query
        addQuery[kSecValueData as String] = data

        #if targetEnvironment(simulator)
        // Simulator doesn't support biometric — use basic accessibility.
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        #else
        // Require device passcode/biometric to access the credentials.
        if let access = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            .userPresence,
            nil
        ) {
            addQuery[kSecAttrAccessControl as String] = access
        } else {
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        }
        #endif

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus != errSecSuccess {
            NSLog("KeychainStore: SecItemAdd failed for key '\(key)' with status \(addStatus)")
        }
    }

    /// Reads arbitrary Data from the keychain. Triggers a biometric prompt if the
    /// item is guarded by `.userPresence`.
    private static func getData(key: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceKey,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return data
    }

    /// Convenience that decodes `getData` as a UTF-8 string. Used only by the
    /// legacy migration path.
    private static func getString(key: String) -> String? {
        guard let data = getData(key: key) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Deletes a keychain item. Does NOT trigger a biometric prompt —
    /// `SecItemDelete` is allowed without auth.
    private static func delete(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceKey,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
