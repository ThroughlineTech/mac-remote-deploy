// Persists server connection details (URL + bearer token) in the iOS Keychain.
// This ensures credentials survive app reinstalls and are stored securely.
import Foundation
import Security

/// Manages Keychain storage for paired server credentials.
final class KeychainStore {

    private static let serviceKey = "com.remotedeploy.companion"
    private static let urlKey = "server_url"
    private static let tokenKey = "server_token"
    private static let nameKey = "server_name"

    /// Saves the server connection details to the Keychain.
    ///
    /// - Parameter url: The server's base URL.
    /// - Parameter token: The bearer token for API authentication.
    /// - Parameter serverName: The display name of the Mac server.
    static func save(url: String, token: String, serverName: String) {
        set(key: urlKey, value: url)
        set(key: tokenKey, value: token)
        set(key: nameKey, value: serverName)
    }

    /// Loads the saved server connection details from the Keychain.
    ///
    /// - Returns: A tuple of (url, token, serverName), or nil if not saved.
    static func load() -> (url: String, token: String, serverName: String)? {
        guard let url = get(key: urlKey),
              let token = get(key: tokenKey),
              let name = get(key: nameKey) else {
            return nil
        }
        return (url, token, name)
    }

    /// Clears all saved server credentials from the Keychain.
    static func clear() {
        delete(key: urlKey)
        delete(key: tokenKey)
        delete(key: nameKey)
    }

    // MARK: - Private Helpers

    private static func set(key: String, value: String) {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceKey,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)

        var addQuery = query
        addQuery[kSecValueData as String] = data

        #if targetEnvironment(simulator)
        // Simulator doesn't support biometric — use basic accessibility
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        #else
        // Require device passcode/biometric to access the token
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

    private static func get(key: String) -> String? {
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
        return String(data: data, encoding: .utf8)
    }

    private static func delete(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceKey,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
