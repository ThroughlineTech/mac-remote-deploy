@testable import RemoteDeploy
import Foundation
import RemoteDeployShared

final class MockSettingsProvider: SettingsProviding, @unchecked Sendable {
    var stubbedSettings = SettingsData(
        serverPort: 8443,
        hostname: "",
        certPath: "",
        keyPath: "",
        pushNotificationConfig: PushNotificationConfig()
    )

    var currentSettingsCallCount = 0

    func currentSettings() -> SettingsData {
        currentSettingsCallCount += 1
        return stubbedSettings
    }
}
