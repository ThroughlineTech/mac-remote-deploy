// Tests for the unified RemoteDeployError boundary type from TKT-010.
@testable import RemoteDeploy
import XCTest
import Foundation
import RemoteDeployShared

final class RemoteDeployErrorTests: XCTestCase {

    // MARK: - errorDescription / failureReason / recoverySuggestion per case

    func test_serverStartFailed_populatesAllLocalizedFields() {
        let err = RemoteDeployError.serverStartFailed(reason: "port 8443 in use")
        XCTAssertEqual(err.errorDescription, "Failed to start the deploy server")
        XCTAssertEqual(err.failureReason, "port 8443 in use")
        XCTAssertNotNil(err.recoverySuggestion)
        XCTAssertTrue(err.recoverySuggestion?.contains("port") ?? false)
    }

    func test_buildFailed_populatesAllLocalizedFields() {
        let err = RemoteDeployError.buildFailed(reason: "archive failed")
        XCTAssertEqual(err.errorDescription, "Build failed")
        XCTAssertEqual(err.failureReason, "archive failed")
        XCTAssertEqual(err.recoverySuggestion, "Open the build log to see the full error output.")
    }

    func test_pairingFailed_populatesAllLocalizedFields() {
        let err = RemoteDeployError.pairingFailed(reason: "token expired")
        XCTAssertEqual(err.errorDescription, "Pairing failed")
        XCTAssertEqual(err.failureReason, "token expired")
        XCTAssertTrue(err.recoverySuggestion?.contains("pairing code") ?? false)
    }

    func test_networkError_populatesAllLocalizedFields() {
        let err = RemoteDeployError.networkError(reason: "no route to host")
        XCTAssertEqual(err.errorDescription, "Network error")
        XCTAssertEqual(err.failureReason, "no route to host")
        XCTAssertTrue(err.recoverySuggestion?.contains("Tailscale") ?? false)
    }

    func test_fileNotFound_populatesAllLocalizedFields() {
        let err = RemoteDeployError.fileNotFound(path: "/Users/test/missing.ipa")
        XCTAssertEqual(err.errorDescription, "File not found")
        XCTAssertTrue(err.failureReason?.contains("/Users/test/missing.ipa") ?? false)
        XCTAssertNotNil(err.recoverySuggestion)
    }

    func test_validationFailed_populatesAllLocalizedFields() {
        let err = RemoteDeployError.validationFailed(field: "port", reason: "must be between 1024 and 65535")
        XCTAssertEqual(err.errorDescription, "Invalid port")
        XCTAssertEqual(err.failureReason, "must be between 1024 and 65535")
        XCTAssertNotNil(err.recoverySuggestion)
    }

    func test_unknown_populatesAllLocalizedFields() {
        let err = RemoteDeployError.unknown(reason: "something exploded")
        XCTAssertEqual(err.errorDescription, "Something went wrong")
        XCTAssertEqual(err.failureReason, "something exploded")
        XCTAssertNil(err.recoverySuggestion, "Unknown errors have no recovery suggestion")
    }

    // MARK: - localizedDescription (LocalizedError default)

    func test_localizedDescription_returnsErrorDescription() {
        let err = RemoteDeployError.buildFailed(reason: "x")
        // LocalizedError's default `localizedDescription` returns errorDescription.
        XCTAssertEqual((err as Error).localizedDescription, "Build failed")
    }

    // MARK: - init(wrapping:)

    func test_wrappingExistingRemoteDeployError_returnsUnchanged() {
        let original = RemoteDeployError.buildFailed(reason: "original message")
        let wrapped = RemoteDeployError(wrapping: original)
        // Should pass through, not double-wrap into .unknown.
        if case .buildFailed(let reason) = wrapped {
            XCTAssertEqual(reason, "original message")
        } else {
            XCTFail("Expected .buildFailed pass-through, got \(wrapped)")
        }
    }

    func test_wrappingArbitraryError_collapsesToUnknown() {
        struct CustomError: LocalizedError {
            var errorDescription: String? { "custom error message" }
        }
        let wrapped = RemoteDeployError(wrapping: CustomError())
        if case .unknown(let reason) = wrapped {
            XCTAssertEqual(reason, "custom error message")
        } else {
            XCTFail("Expected .unknown wrapping, got \(wrapped)")
        }
    }

    func test_wrappingNSError_preservesLocalizedDescription() {
        let nsError = NSError(domain: "TestDomain", code: 42, userInfo: [
            NSLocalizedDescriptionKey: "ns error description"
        ])
        let wrapped = RemoteDeployError(wrapping: nsError)
        if case .unknown(let reason) = wrapped {
            XCTAssertEqual(reason, "ns error description")
        } else {
            XCTFail("Expected .unknown wrapping, got \(wrapped)")
        }
    }

    func test_wrappingExistingModuleError_preservesItsDescription() {
        // BuildError lives in the macOS target and conforms to LocalizedError.
        // When wrapped, its description should be preserved as the .unknown reason.
        let buildErr = BuildError.cancelled
        let wrapped = RemoteDeployError(wrapping: buildErr)
        if case .unknown(let reason) = wrapped {
            XCTAssertEqual(reason, "Build was cancelled.", "Wrapping should preserve the original module-specific message")
        } else {
            XCTFail("Expected .unknown, got \(wrapped)")
        }
    }

    // MARK: - Sendable

    func test_isSendable() {
        // Compile-time check: passing the value across an actor boundary requires Sendable.
        // If this builds, the conformance is correct.
        let err: RemoteDeployError = .pairingFailed(reason: "x")
        Task.detached {
            _ = err.errorDescription
        }
    }
}
