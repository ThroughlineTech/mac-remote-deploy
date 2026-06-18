@testable import RemoteDeployServer
import Foundation

final class MockBuildTrigger: BuildTriggering, @unchecked Sendable {
    var stubbedError: String?

    var triggerBuildCallCount = 0
    var lastProjectID: UUID?
    var lastConfiguration: String?

    func triggerBuild(projectID: UUID, configuration: String?) -> String? {
        triggerBuildCallCount += 1
        lastProjectID = projectID
        lastConfiguration = configuration
        return stubbedError
    }
}
