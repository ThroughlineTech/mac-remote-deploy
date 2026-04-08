@testable import RemoteDeploy
import Foundation

final class MockBuildCanceler: BuildCanceling, @unchecked Sendable {
    var stubbedResult = false

    var cancelCurrentBuildCallCount = 0

    func cancelCurrentBuild() -> Bool {
        cancelCurrentBuildCallCount += 1
        return stubbedResult
    }
}
