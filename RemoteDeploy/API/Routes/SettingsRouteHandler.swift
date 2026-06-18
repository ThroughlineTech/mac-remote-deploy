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

    /// Placeholder substituted for a configured cert/key path on GET so the raw
    /// filesystem path never leaves the Mac. On PUT it means "keep the stored path".
    static let pathPlaceholder = "[configured]"
    /// Placeholder substituted for a non-empty push secret on GET. On PUT it
    /// means "keep the stored secret" so round-tripping clients don't clobber it.
    static let secretPlaceholder = "[redacted]"

    /// GET /api/v1/settings — Return current settings with secrets redacted.
    func get(_ request: APIRequest) -> APIResponse {
        return .json(Self.redacted(settingsProvider.currentSettings()))
    }

    /// PUT /api/v1/settings — Update settings.
    ///
    /// GET redacts secrets, so a client that round-trips settings sends the
    /// placeholders back. Before validating/applying, restore any field still
    /// equal to its placeholder from the stored settings; otherwise the cert/key
    /// existence check would 500 on "[configured]" and "[redacted]" would be
    /// persisted as a real secret. The response is re-redacted to match GET.
    func update(_ request: APIRequest) -> APIResponse {
        guard var settings = try? request.decodeBody(SettingsData.self) else {
            return .error(status: .badRequest, message: "Invalid settings data")
        }

        settings = Self.unredacting(settings, against: settingsProvider.currentSettings())

        if let errorMessage = settingsUpdater.updateSettings(settings) {
            return .error(status: .internalServerError, message: errorMessage)
        }

        return .json(Self.redacted(settings))
    }

    /// Returns a copy of `settings` with cert/key paths and push secrets replaced
    /// by their placeholders when set, leaving empty values empty.
    static func redacted(_ settings: SettingsData) -> SettingsData {
        var s = settings
        s.certPath = s.certPath.isEmpty ? "" : pathPlaceholder
        s.keyPath = s.keyPath.isEmpty ? "" : pathPlaceholder
        s.pushNotificationConfig.prowlAPIKey = s.pushNotificationConfig.prowlAPIKey.isEmpty ? "" : secretPlaceholder
        s.pushNotificationConfig.pushoverAppToken = s.pushNotificationConfig.pushoverAppToken.isEmpty ? "" : secretPlaceholder
        s.pushNotificationConfig.pushoverUserKey = s.pushNotificationConfig.pushoverUserKey.isEmpty ? "" : secretPlaceholder
        s.pushNotificationConfig.ntfyTopic = s.pushNotificationConfig.ntfyTopic.isEmpty ? "" : secretPlaceholder
        return s
    }

    /// Returns a copy of `incoming` where any field still holding its placeholder
    /// is restored from `current`, so unchanged redacted secrets survive a PUT.
    static func unredacting(_ incoming: SettingsData, against current: SettingsData) -> SettingsData {
        var s = incoming
        if s.certPath == pathPlaceholder { s.certPath = current.certPath }
        if s.keyPath == pathPlaceholder { s.keyPath = current.keyPath }
        var push = s.pushNotificationConfig
        let currentPush = current.pushNotificationConfig
        if push.prowlAPIKey == secretPlaceholder { push.prowlAPIKey = currentPush.prowlAPIKey }
        if push.pushoverAppToken == secretPlaceholder { push.pushoverAppToken = currentPush.pushoverAppToken }
        if push.pushoverUserKey == secretPlaceholder { push.pushoverUserKey = currentPush.pushoverUserKey }
        if push.ntfyTopic == secretPlaceholder { push.ntfyTopic = currentPush.ntfyTopic }
        s.pushNotificationConfig = push
        return s
    }
}
