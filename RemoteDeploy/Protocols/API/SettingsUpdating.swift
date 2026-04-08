// Protocol for applying SettingsData updates from the API layer.
// The real implementation that validates and persists settings lands in TKT-009;
// the current production adapter is a no-op stub that always returns nil (success).
import Foundation
import RemoteDeployShared

protocol SettingsUpdating: Sendable {

    /// Applies an updated `SettingsData` snapshot.
    ///
    /// - Parameter settings: The new settings to apply.
    /// - Returns: `nil` on success, or a human-readable error message on failure.
    func updateSettings(_ settings: SettingsData) -> String?
}
