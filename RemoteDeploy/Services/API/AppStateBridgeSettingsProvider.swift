// Real implementation of SettingsProviding that delegates to AppStateBridge.
import Foundation
import RemoteDeployShared

/// Reads current settings via an AppStateBridge.
final class AppStateBridgeSettingsProvider: SettingsProviding, @unchecked Sendable {

    private let bridge: AppStateBridge

    init(bridge: AppStateBridge) {
        self.bridge = bridge
    }

    func currentSettings() -> SettingsData {
        bridge.settings()
    }
}
