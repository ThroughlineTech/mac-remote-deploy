@testable import RemoteDeployServer
import Foundation

final class MockTailscaleProvider: TailscaleProviderProtocol, @unchecked Sendable {

    // MARK: - detectHostname()

    var detectHostnameCallCount = 0
    var detectHostnameResult: String = "test-mac.tail12345.ts.net"
    var detectHostnameShouldThrow: Error?

    func detectHostname() async throws -> String {
        detectHostnameCallCount += 1
        if let error = detectHostnameShouldThrow { throw error }
        return detectHostnameResult
    }

    // MARK: - isConnected()

    var isConnectedCallCount = 0
    var isConnectedResult: Bool = true

    func isConnected() async -> Bool {
        isConnectedCallCount += 1
        return isConnectedResult
    }

    // MARK: - generateCertificate(hostname:outputDir:)

    var generateCertificateCallCount = 0
    var lastGenerateCertHostname: String?
    var lastGenerateCertOutputDir: String?
    var generateCertificateResult: (certPath: String, keyPath: String) = (
        certPath: "/tmp/test-cert.pem",
        keyPath: "/tmp/test-key.pem"
    )
    var generateCertificateShouldThrow: Error?

    func generateCertificate(hostname: String, outputDir: String) async throws -> (certPath: String, keyPath: String) {
        generateCertificateCallCount += 1
        lastGenerateCertHostname = hostname
        lastGenerateCertOutputDir = outputDir
        if let error = generateCertificateShouldThrow { throw error }
        return generateCertificateResult
    }
}
