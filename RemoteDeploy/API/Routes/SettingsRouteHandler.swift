// Handles GET/PUT /api/v1/settings endpoints.
// Allows companion devices to read and update server settings.
import Foundation
import RemoteDeployShared

/// Provides settings access to companion devices.
final class SettingsRouteHandler: @unchecked Sendable {

    /// Closure that returns the current settings.
    private let settingsProvider: @Sendable () -> SettingsData

    /// Closure that applies updated settings. Returns nil on success, error message on failure.
    private let settingsUpdater: @Sendable (SettingsData) -> String?

    /// Creates a new settings route handler.
    ///
    /// - Parameter settingsProvider: Returns the current server settings.
    /// - Parameter settingsUpdater: Applies updated settings.
    init(
        settingsProvider: @escaping @Sendable () -> SettingsData,
        settingsUpdater: @escaping @Sendable (SettingsData) -> String?
    ) {
        self.settingsProvider = settingsProvider
        self.settingsUpdater = settingsUpdater
    }

    /// GET /api/v1/settings — Return current settings.
    func get(_ request: APIRequest) -> APIResponse {
        let settings = settingsProvider()
        return .json(settings)
    }

    /// PUT /api/v1/settings — Update settings.
    func update(_ request: APIRequest) -> APIResponse {
        guard let settings = try? request.decodeBody(SettingsData.self) else {
            return .error(status: .badRequest, message: "Invalid settings data")
        }

        if let errorMessage = settingsUpdater(settings) {
            return .error(status: .internalServerError, message: errorMessage)
        }

        return .json(settings)
    }
}
