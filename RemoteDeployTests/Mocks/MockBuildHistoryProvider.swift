@testable import RemoteDeploy
import Foundation
import RemoteDeployShared

final class MockBuildHistoryProvider: BuildHistoryProviding, @unchecked Sendable {
    var stubbedBuilds: [BuildResult] = []

    var recentBuildsCallCount = 0

    func recentBuilds() -> [BuildResult] {
        recentBuildsCallCount += 1
        return stubbedBuilds
    }
}
