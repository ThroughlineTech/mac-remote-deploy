// Persists server connection details (URL + bearer token + server name) in
// the iOS Keychain as a single JSON blob under one keychain item, gated by
// an explicit LAContext so reading only triggers ONE Face ID / passcode
// prompt per process lifetime. See TKT-022.
//
// Architecture notes:
// - All three fields live in one keychain item (key "credentials"), stored
//   as JSON. Single blob = single SecItemCopyMatching call = single prompt.
// - The access control flag is `.userPresence` which means "biometric OR
//   passcode." On a device with NSFaceIDUsageDescription in Info.plist, this
//   presents Face ID first with passcode fallback. Without that Info.plist
//   key, iOS silently disables biometrics and falls back to passcode-only.
//   NSFaceIDUsageDescription was added in this same ticket.
// - load() is async because LAContext.evaluatePolicy uses a completion
//   handler. We explicitly authenticate via evaluatePolicy() before doing
//   any SecItemCopyMatching call, and pass the authenticated context via
//   kSecUseAuthenticationContext on each query. The keychain trusts the
//   pre-authenticated context for the context's lifetime and skips prompting.
// - Once load() succeeds, the decoded tuple is cached in memory. Subsequent
//   load() calls return the cache without any keychain round-trip.
// - Migration from the legacy 3-item format (pre-TKT-020) happens inside
//   load() under the same authenticated context, so even first-launch-after-
//   upgrade only shows one prompt.
import Foundation
import Security
import os
// TKT-026: @preconcurrency tells the compiler to treat LocalAuthentication
// types (notably LAContext) as if they were Sendable for back-compat.
// Silences the "capture of non-Sendable LAContext in a @Sendable closure"
// warning that fires on `withCheckedContinuation { ... context.evaluatePolicy ... }`.
// Same pattern the host app uses for NIOSSL in NIODeployServer.swift.
@preconcurrency import LocalAuthentication

/// Manages Keychain storage for paired server credentials.
final class KeychainStore {

    // MARK: - Constants

    private static let serviceKey = "com.remotedeploy.companion"
    private static let credentialsKey = "credentials"

    // Legacy keys — retained for the one-time migration from the pre-TKT-020 format.
    private static let legacyURLKey = "server_url"
    private static let legacyTokenKey = "server_token"
    private static let legacyNameKey = "server_name"

    /// User-facing reason string for LocalAuthentication.
    private static let authReason = "Unlock your paired Mac's credentials"

    // MARK: - Stored payload

    private struct StoredCredentials: Codable {
        let url: String
        let token: String
        let serverName: String
    }

    // MARK: - In-memory cache

    /// Value type for the in-memory cache entry. Kept parallel to
    /// `StoredCredentials` so the struct wrapping the cache has the same
    /// shape as the on-disk format.
    private struct CachedCredentials {
        let url: String
        let token: String
        let serverName: String
    }

    /// Thread-safe in-memory cache populated by the first successful `load()`.
    /// Subsequent `load()` calls return this without touching the keychain.
    /// `save()` and `clear()` keep it in sync.
    ///
    /// TKT-026: migrated from `NSLock` + `nonisolated(unsafe) var cached` to
    /// `OSAllocatedUnfairLock` so the lock is async-safe. `withLock { ... }`
    /// is structurally scoped — the compiler can prove the lock isn't held
    /// across an await — which is why it's allowed inside an `async` function
    /// under Swift 6, unlike `NSLock.lock()` / `unlock()`.
    private static let lockedCache = OSAllocatedUnfairLock<CachedCredentials?>(initialState: nil)

    // MARK: - Public API

    /// Saves the server connection details to the Keychain as a single JSON blob
    /// and populates the in-memory cache. Synchronous; safe to call from any thread.
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

        lockedCache.withLock { $0 = CachedCredentials(url: url, token: token, serverName: serverName) }
    }

    /// Loads the saved server connection details from the Keychain.
    ///
    /// Returns the in-memory cache if populated. Otherwise authenticates the
    /// user via LocalAuthentication (Face ID or passcode), then reads the
    /// single-blob item under that authenticated context. Falls back to the
    /// legacy 3-item format if the blob doesn't exist yet, rewrites it as a
    /// blob, and clears the legacy items — all under the same one-shot auth.
    ///
    /// - Returns: A tuple of (url, token, serverName), or nil if not saved or auth failed.
    static func load() async -> (url: String, token: String, serverName: String)? {
        // Fast path: in-memory cache.
        if let cached = lockedCache.withLock({ $0 }) {
            return (cached.url, cached.token, cached.serverName)
        }

        #if targetEnvironment(simulator)
        // Simulator doesn't support biometric auth in a way that works for
        // XCUITest runs. Skip the LAContext step entirely and read the items
        // directly (they're stored without .userPresence on simulator).
        if let tuple = loadWithoutContext() {
            updateCache(tuple)
            return tuple
        }
        return nil
        #else
        // Device path: authenticate once via LAContext, then read with
        // kSecUseAuthenticationContext so the keychain trusts the pre-auth'd
        // context and doesn't prompt again. On a device with no passcode/biometrics
        // the item was stored WITHOUT a user-presence gate, so read it directly --
        // evaluatePolicy would just fail with passcodeNotSet and block restore.
        let context: LAContext?
        if deviceAuthAvailable() {
            guard let authed = await authenticatedContext() else {
                return nil
            }
            context = authed
        } else {
            context = nil
        }

        // Blob first.
        if let data = getData(key: credentialsKey, context: context),
           let decoded = try? JSONDecoder().decode(StoredCredentials.self, from: data) {
            let tuple = (decoded.url, decoded.token, decoded.serverName)
            updateCache(tuple)
            return tuple
        }

        // Legacy migration.
        if let legacy = loadLegacy(context: context) {
            save(url: legacy.url, token: legacy.token, serverName: legacy.serverName)
            clearLegacy()
            // save() already updates the cache.
            return legacy
        }

        return nil
        #endif
    }

    /// Reports whether any saved credentials exist WITHOUT prompting for Face ID
    /// / passcode. Lets the connection layer tell "genuinely unpaired" (show the
    /// QR screen, never prompt) apart from "paired but the read/auth failed"
    /// (worth retrying), and avoids a spurious biometric prompt for users who
    /// have never paired.
    ///
    /// Checks existence by requesting ATTRIBUTES (not the secret data). For a
    /// `.userPresence`-protected item, attributes are readable WITHOUT
    /// authentication, so this never prompts -- yet still detects the item.
    ///
    /// TKT-066: the previous implementation used `kSecUseAuthenticationUISkip`,
    /// which does NOT return "exists but needs auth" -- it SILENTLY OMITS any
    /// auth-protected item from the results, so the query returned
    /// `errSecItemNotFound`. That made `hasStoredCredentials()` always report
    /// false for the real (Face-ID-gated) credential, so `restoreConnection` was
    /// never attempted, `load()`'s Face ID prompt never fired, and the app
    /// re-paired on every cold start.
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
            // errSecSuccess: item exists (attributes returned, no auth needed).
            // errSecInteractionNotAllowed: item exists but is auth-gated -- still
            // proof it exists, which is all we need here.
            return status == errSecSuccess || status == errSecInteractionNotAllowed
        }

        return itemExists(account: credentialsKey) || itemExists(account: legacyURLKey)
    }

    // MARK: - Diagnostics (TKT-066)
    // Persisted to UserDefaults (survives force-quit, unlike the keychain item
    // when a write fails) so the pairing screen can show WHY a cold-start restore
    // failed -- no Console/device logs needed. Remove once the re-pair-on-cold-
    // start issue is resolved.

    private static let diagLastSaveStatusKey = "diag.kc.lastSaveStatus"
    private static let diagLastReadStatusKey = "diag.kc.lastReadStatus"

    /// Human-readable summary of the last credential save/read OSStatus plus
    /// whether an item is currently stored. Shown on the pairing screen.
    static func diagnosticSummary() -> String {
        let d = UserDefaults.standard
        let save = d.object(forKey: diagLastSaveStatusKey) as? Int
        let read = d.object(forKey: diagLastReadStatusKey) as? Int
        return "kc save=\(statusName(save)) stored=\(hasStoredCredentials()) read=\(statusName(read))"
    }

    private static func statusName(_ status: Int?) -> String {
        guard let status else { return "n/a" }
        switch OSStatus(status) {
        case errSecSuccess: return "ok"
        case errSecItemNotFound: return "notFound(-25300)"
        case errSecMissingEntitlement: return "missingEntitlement(-34018)"
        case errSecInteractionNotAllowed: return "interactionNotAllowed(-25308)"
        case errSecAuthFailed: return "authFailed(-25293)"
        case errSecParam: return "param(-50)"
        case errSecNotAvailable: return "notAvailable(-25291)"
        default: return "\(status)"
        }
    }

    /// Clears all saved server credentials (new blob + stray legacy items + cache).
    static func clear() {
        delete(key: credentialsKey)
        clearLegacy()
        lockedCache.withLock { $0 = nil }
    }

    // MARK: - LAContext authentication

    /// Whether the device can evaluate owner authentication (a passcode and/or
    /// biometrics are set). When false -- e.g. an iPhone SE with no passcode and
    /// no Touch ID -- a `.userPresence`-gated keychain item can be neither stored
    /// (SecItemAdd fails) nor read (`evaluatePolicy` fails with `passcodeNotSet`).
    /// In that case the credential is stored and read WITHOUT the gate, so pairing
    /// still survives a relaunch. TKT-066.
    static func deviceAuthAvailable() -> Bool {
        var error: NSError?
        return LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: &error)
    }

    /// Creates an LAContext and authenticates the user.
    ///
    /// Uses `.deviceOwnerAuthentication` — Apple's standard "biometrics first,
    /// automatic passcode fallback on failure" pattern. On a Face-ID-enrolled
    /// device, iOS shows Face ID first; if it fails (cover face, look away,
    /// mismatch) iOS automatically transitions to the passcode screen without
    /// any user action. This is the same pattern used by Apple Wallet, locked
    /// Notes, and Keychain Access.
    ///
    /// Returns the authenticated context on success, nil on user-cancel or
    /// double-failure. TKT-023.
    private static func authenticatedContext() async -> LAContext? {
        let context = LAContext()
        context.localizedFallbackTitle = "Use Passcode"

        return await withCheckedContinuation { continuation in
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: authReason) { success, error in
                if success {
                    continuation.resume(returning: context)
                } else {
                    if let error {
                        NSLog("KeychainStore: LAContext auth failed: \(error.localizedDescription)")
                    }
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    // MARK: - Legacy helpers

    /// Reads the legacy 3-item format using an authenticated LAContext so all
    /// three reads share the same auth and only show one prompt total.
    private static func loadLegacy(context: LAContext?) -> (url: String, token: String, serverName: String)? {
        guard let url = getString(key: legacyURLKey, context: context),
              let token = getString(key: legacyTokenKey, context: context),
              let name = getString(key: legacyNameKey, context: context) else {
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

    #if targetEnvironment(simulator)
    /// Simulator fallback: reads without an LAContext since biometric auth
    /// isn't available. Tries blob first, then legacy 3-item format.
    private static func loadWithoutContext() -> (url: String, token: String, serverName: String)? {
        if let data = getData(key: credentialsKey, context: nil),
           let decoded = try? JSONDecoder().decode(StoredCredentials.self, from: data) {
            return (decoded.url, decoded.token, decoded.serverName)
        }
        if let url = getString(key: legacyURLKey, context: nil),
           let token = getString(key: legacyTokenKey, context: nil),
           let name = getString(key: legacyNameKey, context: nil) {
            save(url: url, token: token, serverName: name)
            clearLegacy()
            return (url, token, name)
        }
        return nil
    }
    #endif

    // MARK: - Cache update

    private static func updateCache(_ tuple: (url: String, token: String, serverName: String)) {
        lockedCache.withLock { $0 = CachedCredentials(url: tuple.url, token: tuple.token, serverName: tuple.serverName) }
    }

    // MARK: - Generic keychain helpers

    /// Writes arbitrary Data to the keychain under the given account key, applying
    /// `.userPresence` access control on device and plain accessibility on simulator.
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
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        #else
        // Gate behind biometrics/passcode only when the device can evaluate it.
        // On a device with no passcode (e.g. a bare SE), a .userPresence item
        // can't be created at all, so store plain device-only accessibility there
        // -- otherwise SecItemAdd fails and the pairing never persists. TKT-066.
        if deviceAuthAvailable(),
           let access = SecAccessControlCreateWithFlags(
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
        if key == credentialsKey {
            UserDefaults.standard.set(Int(addStatus), forKey: diagLastSaveStatusKey)
        }
        if addStatus != errSecSuccess {
            NSLog("KeychainStore: SecItemAdd failed for key '\(key)' with status \(addStatus)")
        }
    }

    /// Reads arbitrary Data from the keychain. Pass an authenticated LAContext
    /// via `context` to skip a biometric prompt when the item is `.userPresence`-
    /// guarded. Pass nil on simulator or when no auth is needed.
    private static func getData(key: String, context: LAContext?) -> Data? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceKey,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if let context {
            query[kSecUseAuthenticationContext as String] = context
        }
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if key == credentialsKey {
            UserDefaults.standard.set(Int(status), forKey: diagLastReadStatusKey)
        }
        guard status == errSecSuccess, let data = result as? Data else {
            // errSecItemNotFound (-25300) is the normal "nothing saved" case.
            // Anything else (e.g. -34018 errSecMissingEntitlement, -25308
            // errSecInteractionNotAllowed, -25293 errSecAuthFailed) is a real
            // failure that previously vanished silently and dropped the user to
            // the pairing screen -- log the status so it can be diagnosed.
            if status != errSecItemNotFound {
                NSLog("KeychainStore: read failed for key '\(key)' with status \(status)")
            }
            return nil
        }
        return data
    }

    /// Convenience that decodes `getData` as a UTF-8 string. Used by legacy migration.
    private static func getString(key: String, context: LAContext?) -> String? {
        guard let data = getData(key: key, context: context) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Deletes a keychain item. Does NOT require authentication.
    private static func delete(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceKey,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
