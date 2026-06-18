// Builds a ServerStatus snapshot from the stores and the live deploy server,
// with no AppState snapshot. TKT-055 (Phase 2): replaces AppStateStatusProvider
// and lets AppStateBridge be deleted.
//
// Sources:
// - serverRunning / serverPort: the live NIODeployServer.
// - hostname / configured port: the SettingsStore (single settings source).
// - tailscaleConnected: the RuntimeStatusStore (live runtime flag).
// - buildStatus: BuildManager via the injected BuildStatusProviding.
import Foundation
import RemoteDeployShared

final class ServerStatusProvider: StatusProviding, @unchecked Sendable {

    private let settingsStore: SettingsStore
    private let runtimeStatus: RuntimeStatusStore
    private let deployServer: NIODeployServer
    private let buildStatusProvider: any BuildStatusProviding

    /// Creates a new status provider.
    ///
    /// - Parameters:
    ///   - settingsStore: Single source of truth for hostname/port.
    ///   - runtimeStatus: Live runtime flags (Tailscale connectivity).
    ///   - deployServer: The NIO deploy server, queried for live `isRunning`/`port`.
    ///   - buildStatusProvider: Source of the current build status (BuildManager-backed).
    init(
        settingsStore: SettingsStore,
        runtimeStatus: RuntimeStatusStore,
        deployServer: NIODeployServer,
        buildStatusProvider: any BuildStatusProviding
    ) {
        self.settingsStore = settingsStore
        self.runtimeStatus = runtimeStatus
        self.deployServer = deployServer
        self.buildStatusProvider = buildStatusProvider
    }

    func currentStatus() -> ServerStatus {
        let settings = settingsStore.current()
        return ServerStatus(
            serverRunning: deployServer.isRunning,
            tailscaleConnected: runtimeStatus.tailscaleConnected,
            hostname: settings.hostname,
            serverPort: deployServer.port,
            buildStatus: buildStatusProvider.currentBuildStatus()
        )
    }
}
