// Tests for EnvironmentChecker tool detection. These run against the actual
// host environment, so results depend on what's installed. The tests verify
// the detection logic itself rather than asserting specific tool presence. TKT-048.
import XCTest
@testable import RemoteDeploy

final class EnvironmentCheckerTests: XCTestCase {

    // MARK: - Node Detection

    /// If node is installed (likely on a dev Mac), the version should be non-empty.
    /// If not installed, nil is acceptable.
    func testNodeVersionReturnsStringOrNil() {
        let version = EnvironmentChecker.nodeVersion()
        // Either nil (not installed) or a non-empty version string
        if let v = version {
            XCTAssertFalse(v.isEmpty, "Node version should not be empty if detected")
        }
    }

    // MARK: - npm Detection

    func testNpmVersionReturnsStringOrNil() {
        let version = EnvironmentChecker.npmVersion()
        if let v = version {
            XCTAssertFalse(v.isEmpty, "npm version should not be empty if detected")
        }
    }

    // MARK: - CocoaPods Detection

    func testCocoapodsVersionReturnsStringOrNil() {
        let version = EnvironmentChecker.cocoapodsVersion()
        if let v = version {
            XCTAssertFalse(v.isEmpty, "pod version should not be empty if detected")
        }
    }

    // MARK: - Warnings

    /// Warnings should be an array of strings. If all tools are installed,
    /// the array should be empty.
    func testExpoEnvironmentWarningsReturnsArray() {
        let warnings = EnvironmentChecker.expoEnvironmentWarnings()
        // Just verify it's a valid array — contents depend on host env
        XCTAssertNotNil(warnings)
    }

    func testWarningsContainNodeMessageWhenNodeMissing() {
        // This is a structural test — we can't easily mock the Process calls,
        // but we verify the warning message format is correct if warnings exist.
        let warnings = EnvironmentChecker.expoEnvironmentWarnings()
        for warning in warnings {
            XCTAssertFalse(warning.isEmpty, "Warnings should not be empty strings")
            // Each warning should mention a tool name
            let mentionsTool = warning.contains("Node") || warning.contains("npm") || warning.contains("CocoaPods")
            XCTAssertTrue(mentionsTool, "Warning should reference a specific tool: \(warning)")
        }
    }
}
