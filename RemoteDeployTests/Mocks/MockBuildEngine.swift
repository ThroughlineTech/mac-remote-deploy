@testable import RemoteDeployServer
import Foundation

final class MockBuildEngine: BuildEngineProtocol, @unchecked Sendable {

    // MARK: - build(project:)

    var buildCallCount = 0
    var lastBuildProject: ProjectConfig?
    var buildResult: String = "/tmp/test.ipa"
    var buildShouldThrow: Error?

    func build(project: ProjectConfig) async throws -> String {
        buildCallCount += 1
        lastBuildProject = project
        if let error = buildShouldThrow { throw error }
        return buildResult
    }

    // MARK: - cancelBuild()

    var cancelBuildCallCount = 0

    func cancelBuild() async {
        cancelBuildCallCount += 1
    }

    // MARK: - buildLogStream

    var stubbedBuildLogStream: AsyncStream<String> = AsyncStream { $0.finish() }

    var buildLogStream: AsyncStream<String> {
        stubbedBuildLogStream
    }

    // MARK: - status

    var stubbedStatus: BuildStatus = .idle

    var status: BuildStatus {
        stubbedStatus
    }

    // MARK: - detectSchemes(at:)

    var detectSchemesCallCount = 0
    var lastDetectSchemesPath: String?
    var detectSchemesResult: [String] = ["TestScheme"]
    var detectSchemesShouldThrow: Error?

    func detectSchemes(at projectPath: String) async throws -> [String] {
        detectSchemesCallCount += 1
        lastDetectSchemesPath = projectPath
        if let error = detectSchemesShouldThrow { throw error }
        return detectSchemesResult
    }
}
