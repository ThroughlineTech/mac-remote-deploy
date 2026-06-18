@testable import RemoteDeployServer
import Foundation
import RemoteDeployShared

final class MockBuildStatusProvider: BuildStatusProviding, @unchecked Sendable {
    var stubbedStatus = BuildStatusInfo(state: "idle")

    var currentBuildStatusCallCount = 0

    func currentBuildStatus() -> BuildStatusInfo {
        currentBuildStatusCallCount += 1
        return stubbedStatus
    }
}
