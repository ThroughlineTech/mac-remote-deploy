// Thread-safe, file-backed single source of truth for app settings.
// TKT-055 (Phase 2): replaces AppDelegate's bespoke load/save plus the
// AppStateBridge settings snapshot. Persisted to
// ~/Library/Application Support/RemoteDeploy/settings.json.
//
// The store is safe to read from any thread (the NIO event loop reads it via
// SettingsProviding) because the in-memory value is guarded by an unfair lock
// and SettingsData is a Sendable value type. Writes persist to disk and post
// `.settingsDidChange` so AppState can refresh its UI projection.
import Foundation
import os
import RemoteDeployShared

final class SettingsStore: SettingsProviding, @unchecked Sendable {

    /// In-memory settings, guarded for cross-thread reads/writes.
    private let locked: OSAllocatedUnfairLock<SettingsData>

    /// Directory holding settings.json.
    private let storageDirectory: URL

    /// Full path to settings.json.
    private var storageURL: URL {
        storageDirectory.appendingPathComponent("settings.json")
    }

    /// Creates the store and loads any persisted settings from disk.
    ///
    /// - Parameter directory: Optional override for the storage directory. Defaults
    ///   to `~/Library/Application Support/RemoteDeploy`.
    init(directory: URL? = nil) {
        if let directory = directory {
            self.storageDirectory = directory
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            self.storageDirectory = appSupport.appendingPathComponent("RemoteDeploy")
        }
        self.locked = OSAllocatedUnfairLock(initialState: Self.readFromDisk(at: storageDirectory.appendingPathComponent("settings.json")))
    }

    // MARK: - Reads

    /// Returns a snapshot of the current settings. Thread-safe.
    func current() -> SettingsData {
        locked.withLock { $0 }
    }

    /// SettingsProviding conformance so the API reads the store directly.
    func currentSettings() -> SettingsData {
        current()
    }

    // MARK: - Writes

    /// Replaces the stored settings, persists them to disk, and posts
    /// `.settingsDidChange`. Thread-safe; callable from the NIO event loop.
    ///
    /// - Parameter settings: The new settings to persist.
    func update(_ settings: SettingsData) {
        locked.withLock { $0 = settings }
        writeToDisk(settings)
        NotificationCenter.default.post(name: .settingsDidChange, object: nil)
    }

    // MARK: - Persistence

    private static func readFromDisk(at url: URL) -> SettingsData {
        guard FileManager.default.fileExists(atPath: url.path),
              let data = FileManager.default.contents(atPath: url.path) else {
            return SettingsData()
        }
        do {
            return try JSONDecoder().decode(SettingsData.self, from: data)
        } catch {
            Logger.storage.error("Failed to load settings: \(error.localizedDescription, privacy: .public)")
            return SettingsData()
        }
    }

    private func writeToDisk(_ settings: SettingsData) {
        do {
            try FileManager.default.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(settings)
            try data.write(to: storageURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: storageURL.path)
        } catch {
            Logger.storage.error("Failed to save settings: \(error.localizedDescription, privacy: .public)")
        }
    }
}
