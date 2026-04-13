// Tests for local deploy functionality added in TKT-053.
// Covers ProjectConfig backward compatibility and LocalDeployManager
// protocol conformance.
import XCTest
@testable import RemoteDeploy
import RemoteDeployShared

// MARK: - Mock LocalDeployManager

/// Mock implementation of LocalDeployManagerProtocol for testing BuildManager
/// integration without performing real file operations.
final class MockLocalDeployManager: LocalDeployManagerProtocol, @unchecked Sendable {
    var deployCalled = false
    var lastAppName: String?
    var lastArchivePath: String?
    var lastTargetDir: String?
    var lastPort: Int?
    var shouldThrow: Error?

    func deploy(
        appName: String,
        fromArchive archivePath: String,
        toDirectory targetDir: String,
        port: Int?
    ) async throws {
        deployCalled = true
        lastAppName = appName
        lastArchivePath = archivePath
        lastTargetDir = targetDir
        lastPort = port
        if let error = shouldThrow {
            throw error
        }
    }
}

// MARK: - ProjectConfig Backward Compatibility

final class LocalDeployProjectConfigTests: XCTestCase {

    /// Configs saved before TKT-053 don't have localDeploy or localDeployPath.
    /// They should decode with localDeploy = false and localDeployPath = nil.
    func testLegacyConfigDecodesWithLocalDeployDefaults() throws {
        let json = """
        {
            "id": "12345678-1234-1234-1234-123456789012",
            "name": "OldApp",
            "projectPath": "/path/to/old",
            "scheme": "OldApp",
            "bundleID": "com.old.app",
            "teamID": "ABCDE12345",
            "buildConfiguration": "Release",
            "urlSlug": "oldapp",
            "exportMethod": "development"
        }
        """

        let data = json.data(using: .utf8)!
        let config = try JSONDecoder().decode(ProjectConfig.self, from: data)

        XCTAssertFalse(config.localDeploy)
        XCTAssertNil(config.localDeployPath)
    }

    /// Configs with localDeploy fields present should decode correctly.
    func testConfigWithLocalDeployFieldsDecodes() throws {
        let json = """
        {
            "id": "12345678-1234-1234-1234-123456789012",
            "name": "MacApp",
            "projectPath": "/path/to/mac",
            "scheme": "MacApp",
            "bundleID": "com.mac.app",
            "teamID": "ABCDE12345",
            "buildConfiguration": "Release",
            "urlSlug": "macapp",
            "exportMethod": "development",
            "platform": "macOS",
            "localDeploy": true,
            "localDeployPath": "/Users/dev/Apps"
        }
        """

        let data = json.data(using: .utf8)!
        let config = try JSONDecoder().decode(ProjectConfig.self, from: data)

        XCTAssertTrue(config.localDeploy)
        XCTAssertEqual(config.localDeployPath, "/Users/dev/Apps")
        XCTAssertEqual(config.platform, "macOS")
    }

    /// Round-trip encode/decode preserves localDeploy fields.
    func testLocalDeployRoundTrip() throws {
        var original = ProjectConfig(name: "TestApp", projectPath: "/path")
        original.platform = "macOS"
        original.localDeploy = true
        original.localDeployPath = "/opt/apps"

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ProjectConfig.self, from: data)

        XCTAssertTrue(decoded.localDeploy)
        XCTAssertEqual(decoded.localDeployPath, "/opt/apps")
    }

    /// Default init sets localDeploy to false and localDeployPath to nil.
    func testDefaultInitSetsLocalDeployDefaults() {
        let config = ProjectConfig(name: "NewApp", projectPath: "/path")
        XCTAssertFalse(config.localDeploy)
        XCTAssertNil(config.localDeployPath)
    }

    /// Config with localDeploy true but nil path should use default.
    func testLocalDeployWithNilPath() throws {
        var config = ProjectConfig(name: "App", projectPath: "/path")
        config.localDeploy = true
        config.localDeployPath = nil

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(ProjectConfig.self, from: data)

        XCTAssertTrue(decoded.localDeploy)
        XCTAssertNil(decoded.localDeployPath)
    }
}

// MARK: - Mock Deploy Manager Tests

final class MockLocalDeployManagerTests: XCTestCase {

    /// Verify the mock records parameters correctly.
    func testMockRecordsDeployCall() async throws {
        let mock = MockLocalDeployManager()
        try await mock.deploy(
            appName: "TestApp",
            fromArchive: "/tmp/test.xcarchive",
            toDirectory: "/Applications",
            port: 8443
        )

        XCTAssertTrue(mock.deployCalled)
        XCTAssertEqual(mock.lastAppName, "TestApp")
        XCTAssertEqual(mock.lastArchivePath, "/tmp/test.xcarchive")
        XCTAssertEqual(mock.lastTargetDir, "/Applications")
        XCTAssertEqual(mock.lastPort, 8443)
    }

    /// Verify the mock throws when configured to.
    func testMockThrowsOnDeploy() async {
        let mock = MockLocalDeployManager()
        mock.shouldThrow = LocalDeployError.appBundleNotFound("test")

        do {
            try await mock.deploy(
                appName: "TestApp",
                fromArchive: "/tmp/test.xcarchive",
                toDirectory: "/Applications",
                port: nil
            )
            XCTFail("Expected error to be thrown")
        } catch {
            XCTAssertTrue(mock.deployCalled)
        }
    }

    /// Verify nil port is passed through.
    func testMockWithNilPort() async throws {
        let mock = MockLocalDeployManager()
        try await mock.deploy(
            appName: "App",
            fromArchive: "/tmp/a.xcarchive",
            toDirectory: "/Apps",
            port: nil
        )

        XCTAssertNil(mock.lastPort)
    }
}
