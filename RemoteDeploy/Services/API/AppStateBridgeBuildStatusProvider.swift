// Real implementation of BuildStatusProviding that delegates to AppStateBridge.
import Foundation
import RemoteDeployShared

/// Reads the current build status via an AppStateBridge.
final class AppStateBridgeBuildStatusProvider: BuildStatusProviding, @unchecked Sendable {

    private let bridge: AppStateBridge

    init(bridge: AppStateBridge) {
        self.bridge = bridge
    }

    func currentBuildStatus() -> BuildStatusInfo {
        bridge.buildStatusInfo()
    }
}
