// Tests for ProjectConfig backward-compatible decoding of the new
// projectType and expoAppDirectory fields. TKT-048.
import XCTest
@testable import RemoteDeployServer

final class ProjectConfigCodingTests: XCTestCase {

    // MARK: - Backward Compatibility

    /// Configs saved before TKT-048 don't have projectType or expoAppDirectory.
    /// They should decode with projectType = .xcode and expoAppDirectory = nil.
    func testLegacyConfigDecodesWithXcodeDefault() throws {
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

        XCTAssertEqual(config.projectType, .xcode)
        XCTAssertNil(config.expoAppDirectory)
        XCTAssertEqual(config.platform, "iOS")
    }

    // MARK: - Round-Trip (Expo)

    func testExpoConfigRoundTrip() throws {
        var original = ProjectConfig(name: "ExpoApp", projectPath: "/path/to/monorepo")
        original.projectType = .expo
        original.expoAppDirectory = "app"
        original.scheme = "CFB"
        original.bundleID = "com.cfb.cardgame"
        original.teamID = "RDJQ523WP4"

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ProjectConfig.self, from: data)

        XCTAssertEqual(decoded.projectType, .expo)
        XCTAssertEqual(decoded.expoAppDirectory, "app")
        XCTAssertEqual(decoded.scheme, original.scheme)
        XCTAssertEqual(decoded.bundleID, original.bundleID)
    }

    func testXcodeConfigRoundTripPreservesType() throws {
        var original = ProjectConfig(name: "NativeApp", projectPath: "/path/to/native")
        original.projectType = .xcode

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ProjectConfig.self, from: data)

        XCTAssertEqual(decoded.projectType, .xcode)
        XCTAssertNil(decoded.expoAppDirectory)
    }

    func testExpoConfigWithNilAppDirectory() throws {
        var original = ProjectConfig(name: "SingleApp", projectPath: "/path/to/single")
        original.projectType = .expo
        original.expoAppDirectory = nil

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ProjectConfig.self, from: data)

        XCTAssertEqual(decoded.projectType, .expo)
        XCTAssertNil(decoded.expoAppDirectory)
    }

    // MARK: - ProjectType Enum

    func testProjectTypeRawValues() {
        XCTAssertEqual(ProjectType.xcode.rawValue, "xcode")
        XCTAssertEqual(ProjectType.expo.rawValue, "expo")
    }

    func testProjectTypeAllCases() {
        XCTAssertEqual(ProjectType.allCases.count, 2)
        XCTAssertTrue(ProjectType.allCases.contains(.xcode))
        XCTAssertTrue(ProjectType.allCases.contains(.expo))
    }
}
