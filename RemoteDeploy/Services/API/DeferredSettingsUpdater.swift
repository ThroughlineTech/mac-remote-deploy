// Stub implementation of SettingsUpdating that accepts any update without applying it.
// The real implementation that validates inputs and persists settings lands in TKT-009
// (complete settings update endpoint).
import Foundation
import RemoteDeployShared

/// No-op settings updater used until TKT-009 implements real persistence + validation.
final class DeferredSettingsUpdater: SettingsUpdating, @unchecked Sendable {
    func updateSettings(_ settings: SettingsData) -> String? {
        // Settings update from API is deferred; real impl lands in TKT-009.
        return nil
    }
}
