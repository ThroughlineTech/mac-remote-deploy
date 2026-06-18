// Cross-process handoff of the menu bar's loopback bearer token. TKT-060 (Phase 6).
//
// After the process split the headless server mints the loopback token, registers
// its SHA-256 hash as a paired device (so its own AuthMiddleware accepts it), and
// writes the RAW token here with 0600 perms. The separate menu bar process reads
// it at startup to configure its loopback APIClient against http://127.0.0.1:8080.
//
// Compiled into BOTH targets: the server writes/clears it; the menu bar reads it.
// This keeps the server's token hashing (JSONPairedDeviceStore) out of the menu
// bar. Blast radius of the raw token on disk (0600, user-owned, app support) is
// equivalent to the existing hash-in-json record; acceptable for loopback. See
// Phase 7 for hardening.
import Foundation

enum LoopbackTokenStore {

    /// Paired-device record name for the menu bar's loopback token. The server
    /// names the device record this; the menu bar filters it out of the Devices
    /// list so the user cannot revoke it out from under the running app.
    static let deviceName = "Menu bar (local)"

    /// `~/Library/Application Support/RemoteDeploy/loopback_token`. Mirrors the
    /// app-support convention used by the JSON stores and SettingsStore.
    static var tokenURL: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        return appSupport
            .appendingPathComponent("RemoteDeploy", isDirectory: true)
            .appendingPathComponent("loopback_token")
    }

    /// Writes the raw token to disk with 0600 perms, creating the directory if
    /// needed. The atomic write renames a temp file into place, so concurrent
    /// readers always see either the old token or the new one in full -- never a
    /// partial write. Perms are reapplied after the rename (the atomic temp file
    /// is created under the process umask). TKT-060.
    static func write(_ token: String) throws {
        let url = tokenURL
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try token.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Reads the raw token, or nil when the file is absent/unreadable/empty (e.g.
    /// the server has not started yet). The menu bar polls until this returns.
    static func read() -> String? {
        guard let contents = try? String(contentsOf: tokenURL, encoding: .utf8) else { return nil }
        let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Removes the token file. Best-effort; called by the server on shutdown so a
    /// stale token does not linger after the server exits. TKT-060.
    static func clear() {
        try? FileManager.default.removeItem(at: tokenURL)
    }
}
