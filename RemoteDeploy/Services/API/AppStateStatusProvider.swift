// Real implementation of StatusProviding that builds a ServerStatus snapshot
// from an AppStateBridge plus the live NIODeployServer instance.
import Foundation
import RemoteDeployShared

/// Builds a `ServerStatus` snapshot from app state and the deploy server.
final class AppStateStatusProvider: StatusProviding, @unchecked Sendable {

    private let bridge: AppStateBridge
    private let deployServer: NIODeployServer

    /// Creates a new status provider.
    ///
    /// - Parameter bridge: Thread-safe bridge for reading AppState values.
    /// - Parameter deployServer: The NIO deploy server, queried for live `isRunning` and `port`.
    init(bridge: AppStateBridge, deployServer: NIODeployServer) {
        self.bridge = bridge
        self.deployServer = deployServer
    }

    func currentStatus() -> ServerStatus {
        let snapshot = bridge.snapshot()
        return ServerStatus(
            serverRunning: deployServer.isRunning,
            tailscaleConnected: snapshot.tailscaleConnected,
            hostname: snapshot.hostname,
            serverPort: deployServer.port,
            buildStatus: bridge.buildStatusInfo()
        )
    }
}
