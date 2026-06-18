// Protocol for reading the current SettingsData snapshot for the API layer.
// Decouples SettingsRouteHandler from the concrete settings source (SettingsStore).
import Foundation
import RemoteDeployShared

protocol SettingsProviding: Sendable {

    /// Returns a snapshot of current settings.
    ///
    /// The returned data may include secrets; callers (e.g. SettingsRouteHandler)
    /// are responsible for redacting sensitive fields before transmission.
    ///
    /// - Returns: A populated `SettingsData` value.
    func currentSettings() -> SettingsData
}
