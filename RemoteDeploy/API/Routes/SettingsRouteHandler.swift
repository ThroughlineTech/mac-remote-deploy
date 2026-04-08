// Handles GET/PUT /api/v1/settings endpoints.
// Allows companion devices to read and update server settings.
import Foundation
import RemoteDeployShared

/// Provides settings access to companion devices.
final class SettingsRouteHandler: @unchecked Sendable {

    private let settingsProvider: any SettingsProviding
    private let settingsUpdater: any SettingsUpdating

    /// Creates a new settings route handler.
    ///
    /// - Parameter settingsProvider: Source of the current server settings.
    /// - Parameter settingsUpdater: Sink for applying updated settings.
    init(
        settingsProvider: any SettingsProviding,
        settingsUpdater: any SettingsUpdating
    ) {
        self.settingsProvider = settingsProvider
        self.settingsUpdater = settingsUpdater
    }

    /// GET /api/v1/settings — Return current settings with secrets redacted.
    func get(_ request: APIRequest) -> APIResponse {
        var settings = settingsProvider.currentSettings()
        // Redact sensitive values — companion app only needs to know enabled/disabled status
        settings.certPath = settings.certPath.isEmpty ? "" : "[configured]"
        settings.keyPath = settings.keyPath.isEmpty ? "" : "[configured]"
        settings.pushNotificationConfig.prowlAPIKey = settings.pushNotificationConfig.prowlAPIKey.isEmpty ? "" : "[redacted]"
        settings.pushNotificationConfig.pushoverAppToken = settings.pushNotificationConfig.pushoverAppToken.isEmpty ? "" : "[redacted]"
        settings.pushNotificationConfig.pushoverUserKey = settings.pushNotificationConfig.pushoverUserKey.isEmpty ? "" : "[redacted]"
        settings.pushNotificationConfig.ntfyTopic = settings.pushNotificationConfig.ntfyTopic.isEmpty ? "" : "[redacted]"
        return .json(settings)
    }

    /// PUT /api/v1/settings — Update settings.
    func update(_ request: APIRequest) -> APIResponse {
        guard let settings = try? request.decodeBody(SettingsData.self) else {
            return .error(status: .badRequest, message: "Invalid settings data")
        }

        if let errorMessage = settingsUpdater.updateSettings(settings) {
            return .error(status: .internalServerError, message: errorMessage)
        }

        return .json(settings)
    }
}
