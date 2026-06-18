// Real SettingsUpdating implementation. TKT-009 introduced validation +
// in-memory application + persist-to-disk; TKT-055 (Phase 2) repointed the
// apply step at the thread-safe SettingsStore (the single settings writer) and
// dropped the AppStateBridge dependency. Filename is retained (originally
// "Deferred...") to avoid churning the pbxproj.
import Foundation
import RemoteDeployShared

/// Applies settings updates submitted via PUT /api/v1/settings. Validates inputs,
/// then writes them through the SettingsStore, which persists to disk and posts
/// `.settingsDidChange` so AppState's UI projection refreshes.
final class DeferredSettingsUpdater: SettingsUpdating, @unchecked Sendable {

    /// The single settings writer. Nil means validation-only (the `noop()`
    /// factory used by tests that don't exercise the apply path).
    private let settingsStore: SettingsStore?

    /// Minimum valid TCP port for the HTTPS listener.
    private static let minPort = 1024
    /// Maximum valid TCP port.
    private static let maxPort = 65535

    init(settingsStore: SettingsStore) {
        self.settingsStore = settingsStore
    }

    /// Internal no-op init backing `noop()`. Used by tests that need a
    /// SettingsUpdating instance but don't care about persistence.
    private init() {
        self.settingsStore = nil
    }

    /// Factory for a no-op updater that still performs input validation.
    static func noop() -> DeferredSettingsUpdater {
        DeferredSettingsUpdater()
    }

    func updateSettings(_ settings: SettingsData) -> String? {
        // --- Validation ---
        if settings.serverPort < Self.minPort || settings.serverPort > Self.maxPort {
            return "Port \(settings.serverPort) out of range — must be between \(Self.minPort) and \(Self.maxPort)."
        }

        // Cert paths: if provided, must exist on disk AND be readable. Empty is OK (means unset).
        if !settings.certPath.isEmpty {
            if !FileManager.default.fileExists(atPath: settings.certPath) {
                return "Certificate file not found at \(settings.certPath)"
            }
            if !FileManager.default.isReadableFile(atPath: settings.certPath) {
                return "Certificate file not readable at \(settings.certPath)"
            }
        }
        if !settings.keyPath.isEmpty {
            if !FileManager.default.fileExists(atPath: settings.keyPath) {
                return "Key file not found at \(settings.keyPath)"
            }
            if !FileManager.default.isReadableFile(atPath: settings.keyPath) {
                return "Key file not readable at \(settings.keyPath)"
            }
        }

        // --- Apply ---
        // settingsStore is nil for the test-only noop() factory.
        settingsStore?.update(settings)
        return nil
    }
}
