@testable import RemoteDeploy
import Foundation
import RemoteDeployShared

final class MockSettingsUpdater: SettingsUpdating, @unchecked Sendable {
    var stubbedError: String?

    var updateSettingsCallCount = 0
    var lastUpdatedSettings: SettingsData?

    func updateSettings(_ settings: SettingsData) -> String? {
        updateSettingsCallCount += 1
        lastUpdatedSettings = settings
        return stubbedError
    }
}
