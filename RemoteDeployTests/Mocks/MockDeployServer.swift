@testable import RemoteDeploy
import Foundation

final class MockDeployServer: DeployServerProtocol, @unchecked Sendable {

    // MARK: - start(port:certPath:keyPath:)

    var startCallCount = 0
    var lastStartPort: Int?
    var lastStartCertPath: String?
    var lastStartKeyPath: String?
    var startShouldThrow: Error?

    func start(port: Int, certPath: String, keyPath: String) async throws {
        startCallCount += 1
        lastStartPort = port
        lastStartCertPath = certPath
        lastStartKeyPath = keyPath
        if let error = startShouldThrow { throw error }
        stubbedIsRunning = true
    }

    // MARK: - stop()

    var stopCallCount = 0

    func stop() async {
        stopCallCount += 1
        stubbedIsRunning = false
    }

    // MARK: - isRunning

    var stubbedIsRunning = false

    var isRunning: Bool {
        stubbedIsRunning
    }

    // MARK: - port

    var stubbedPort: Int = 8443

    var port: Int {
        stubbedPort
    }

    // MARK: - delegate

    var delegate: DeployServerDelegate?
}
