// Real SettingsUpdating implementation. TKT-009 replaced the original
// no-op stub with validation + in-memory application + persist-to-disk.
// Filename is retained (originally "Deferred...") to avoid churning the pbxproj.
import Foundation
import RemoteDeployShared

/// Applies settings updates submitted via PUT /api/v1/settings. Validates inputs,
/// updates the in-memory AppState on the main actor, and triggers a settings save.
final class DeferredSettingsUpdater: SettingsUpdating, @unchecked Sendable {

    /// Bridge used to read current settings so we can tell what's actually changing.
    /// Optional so tests that don't exercise settings updates can instantiate a no-op.
    private let bridge: AppStateBridge?

    /// Main-actor callback that applies validated settings to AppState and persists
    /// them to disk. Invoked from updateSettings(). Nil means validation-only (tests).
    private let applyOnMain: (@Sendable (SettingsData) -> Void)?

    /// Minimum valid TCP port for the HTTPS listener.
    private static let minPort = 1024
    /// Maximum valid TCP port.
    private static let maxPort = 65535

    init(bridge: AppStateBridge, applyOnMain: @escaping @Sendable (SettingsData) -> Void) {
        self.bridge = bridge
        self.applyOnMain = applyOnMain
    }

    /// Internal no-op init backing `noop()`. Used by tests that need a
    /// SettingsUpdating instance but don't care about the side effects.
    private init() {
        self.bridge = nil
        self.applyOnMain = nil
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
        // applyOnMain is nil for the test-only noop() factory.
        applyOnMain?(settings)
        return nil
    }
}
