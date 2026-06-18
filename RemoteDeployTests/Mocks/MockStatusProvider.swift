@testable import RemoteDeployServer
import Foundation
import RemoteDeployShared

final class MockStatusProvider: StatusProviding, @unchecked Sendable {
    var stubbedStatus = ServerStatus(
        serverRunning: false,
        tailscaleConnected: false,
        hostname: "",
        serverPort: 0,
        buildStatus: BuildStatusInfo(state: "idle")
    )

    var currentStatusCallCount = 0

    func currentStatus() -> ServerStatus {
        currentStatusCallCount += 1
        return stubbedStatus
    }
}
