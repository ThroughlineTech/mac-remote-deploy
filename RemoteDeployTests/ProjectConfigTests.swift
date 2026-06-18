import XCTest
@testable import RemoteDeployServer

final class ProjectConfigTests: XCTestCase {

    // MARK: - Default Initialization

    func testDefaultInitSetsName() {
        let config = ProjectConfig(name: "MyApp", projectPath: "/path/to/project")

        XCTAssertEqual(config.name, "MyApp")
    }

    func testDefaultInitSetsProjectPath() {
        let config = ProjectConfig(name: "MyApp", projectPath: "/path/to/project")

        XCTAssertEqual(config.projectPath, "/path/to/project")
    }

    func testDefaultInitGeneratesUUID() {
        let config = ProjectConfig(name: "MyApp", projectPath: "/path")

        XCTAssertFalse(config.id.uuidString.isEmpty, "Should generate a non-empty UUID")
    }

    func testDefaultInitSetsReleaseBuildConfiguration() {
        let config = ProjectConfig(name: "MyApp", projectPath: "/path")

        XCTAssertEqual(config.buildConfiguration, "Release")
    }

    func testDefaultInitSetsAdHocExportMethod() {
        let config = ProjectConfig(name: "MyApp", projectPath: "/path")

        XCTAssertEqual(config.exportMethod, "development")
    }

    func testDefaultInitSetsEmptyScheme() {
        let config = ProjectConfig(name: "MyApp", projectPath: "/path")

        XCTAssertEqual(config.scheme, "")
    }

    func testDefaultInitSetsEmptyBundleID() {
        let config = ProjectConfig(name: "MyApp", projectPath: "/path")

        XCTAssertEqual(config.bundleID, "")
    }

    func testDefaultInitSetsEmptyTeamID() {
        let config = ProjectConfig(name: "MyApp", projectPath: "/path")

        XCTAssertEqual(config.teamID, "")
    }

    func testDefaultInitSetsNilProjectFile() {
        let config = ProjectConfig(name: "MyApp", projectPath: "/path")

        XCTAssertNil(config.projectFile)
    }

    func testDefaultInitSetsNilWorkspaceFile() {
        let config = ProjectConfig(name: "MyApp", projectPath: "/path")

        XCTAssertNil(config.workspaceFile)
    }

    func testDefaultInitSetsNilProvisioningProfile() {
        let config = ProjectConfig(name: "MyApp", projectPath: "/path")

        XCTAssertNil(config.provisioningProfile)
    }

    // MARK: - URL Slug Generation

    func testURLSlugIsLowercasedName() {
        let config = ProjectConfig(name: "MyApp", projectPath: "/path")

        XCTAssertEqual(config.urlSlug, "myapp")
    }

    func testURLSlugReplacesSpacesWithDashes() {
        let config = ProjectConfig(name: "My Great App", projectPath: "/path")

        XCTAssertEqual(config.urlSlug, "my-great-app")
    }

    func testURLSlugWithMultipleSpaces() {
        let config = ProjectConfig(name: "A B C", projectPath: "/path")

        XCTAssertEqual(config.urlSlug, "a-b-c")
    }

    func testURLSlugPreservesHyphens() {
        let config = ProjectConfig(name: "rejog-ios", projectPath: "/path")

        XCTAssertEqual(config.urlSlug, "rejog-ios")
    }

    func testURLSlugWithAllLowercase() {
        let config = ProjectConfig(name: "myapp", projectPath: "/path")

        XCTAssertEqual(config.urlSlug, "myapp")
    }

    // MARK: - Codable Round-Trip

    func testCodableRoundTrip() throws {
        var original = ProjectConfig(name: "TestApp", projectPath: "/Users/dev/project")
        original.scheme = "TestApp"
        original.bundleID = "com.test.app"
        original.teamID = "ABC123"
        original.buildConfiguration = "Debug"
        original.projectFile = "TestApp.xcodeproj"
        original.workspaceFile = "TestApp.xcworkspace"
        original.provisioningProfile = "MyProfile"
        original.exportMethod = "development"

        let encoder = JSONEncoder()
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(ProjectConfig.self, from: data)

        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.name, original.name)
        XCTAssertEqual(decoded.projectPath, original.projectPath)
        XCTAssertEqual(decoded.scheme, original.scheme)
        XCTAssertEqual(decoded.bundleID, original.bundleID)
        XCTAssertEqual(decoded.teamID, original.teamID)
        XCTAssertEqual(decoded.buildConfiguration, original.buildConfiguration)
        XCTAssertEqual(decoded.projectFile, original.projectFile)
        XCTAssertEqual(decoded.workspaceFile, original.workspaceFile)
        XCTAssertEqual(decoded.provisioningProfile, original.provisioningProfile)
        XCTAssertEqual(decoded.exportMethod, original.exportMethod)
        XCTAssertEqual(decoded.urlSlug, original.urlSlug)
    }

    func testCodableRoundTripPreservesNils() throws {
        let original = ProjectConfig(name: "TestApp", projectPath: "/path")

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ProjectConfig.self, from: data)

        XCTAssertNil(decoded.projectFile)
        XCTAssertNil(decoded.workspaceFile)
        XCTAssertNil(decoded.provisioningProfile)
    }

    // MARK: - Equality

    func testEqualityForIdenticalConfigs() {
        var a = ProjectConfig(name: "App", projectPath: "/path")
        var b = a
        // Make sure they share the same ID
        b.id = a.id

        XCTAssertEqual(a, b)
    }

    func testInequalityForDifferentNames() {
        var a = ProjectConfig(name: "App1", projectPath: "/path")
        var b = ProjectConfig(name: "App2", projectPath: "/path")
        b.id = a.id

        XCTAssertNotEqual(a, b)
    }

    func testInequalityForDifferentIDs() {
        let a = ProjectConfig(name: "App", projectPath: "/path")
        let b = ProjectConfig(name: "App", projectPath: "/path")
        // Different UUIDs generated in init

        XCTAssertNotEqual(a, b, "Two configs with different IDs should not be equal")
    }

    func testEqualityAfterModification() {
        var a = ProjectConfig(name: "App", projectPath: "/path")
        var b = a
        b.scheme = "NewScheme"

        XCTAssertNotEqual(a, b, "Configs with different scheme values should not be equal")
    }

    // MARK: - Identifiable

    func testTwoInstancesHaveDifferentIDs() {
        let a = ProjectConfig(name: "App", projectPath: "/path")
        let b = ProjectConfig(name: "App", projectPath: "/path")

        XCTAssertNotEqual(a.id, b.id, "Each instance should get a unique UUID")
    }
}
