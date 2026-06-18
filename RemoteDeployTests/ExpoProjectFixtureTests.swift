// Tests that use the ExpoTestProject fixture to verify Expo project detection
// and validation without a real npm install. TKT-048.
import XCTest
@testable import RemoteDeployServer

final class ExpoProjectFixtureTests: XCTestCase {

    /// Path to the Expo test fixture. Resolved from the test bundle.
    private var fixturePath: String!

    override func setUp() {
        super.setUp()
        // The fixture is copied into the test bundle's resources via XcodeGen.
        // But since the test target just compiles from RemoteDeployTests/ and
        // xcodegen includes all sources, we resolve relative to the repo root.
        // Use a known anchor: the test file's #file location.
        let testFile = #file
        let testsDir = (testFile as NSString).deletingLastPathComponent
        fixturePath = (testsDir as NSString).appendingPathComponent("Fixtures/ExpoTestProject")
    }

    // MARK: - Expo Project Detection

    /// Verifies that the fixture has the expected structure for Expo auto-detection.
    func testFixtureHasExpectedStructure() {
        let fm = FileManager.default
        XCTAssertTrue(fm.fileExists(atPath: (fixturePath as NSString).appendingPathComponent("package.json")),
                       "Fixture must have root package.json")
        XCTAssertTrue(fm.fileExists(atPath: (fixturePath as NSString).appendingPathComponent("app/app.json")),
                       "Fixture must have app/app.json")
        XCTAssertTrue(fm.fileExists(atPath: (fixturePath as NSString).appendingPathComponent("app/package.json")),
                       "Fixture must have app/package.json")
    }

    /// Verifies that the Expo project path validator accepts the fixture root
    /// (which contains package.json).
    func testValidatorAcceptsFixtureRoot() {
        XCTAssertNil(ProjectSetupValidators.validateExpoProjectPath(fixturePath),
                     "Fixture root has package.json, should pass validation")
    }

    /// Verifies that the app directory validator accepts the fixture's "app" subdirectory.
    func testValidatorAcceptsFixtureAppDirectory() {
        XCTAssertNil(ProjectSetupValidators.validateExpoAppDirectory(fixturePath, expoAppDirectory: "app"),
                     "Fixture app/ has app.json, should pass validation")
    }

    /// Verifies that the app directory validator rejects a non-existent subdirectory.
    func testValidatorRejectsInvalidAppDirectory() {
        XCTAssertNotNil(ProjectSetupValidators.validateExpoAppDirectory(fixturePath, expoAppDirectory: "nonexistent"),
                        "Nonexistent subdirectory should fail validation")
    }

    // MARK: - Bundle ID Parsing from app.json

    /// Verifies that the bundle ID can be parsed from the fixture's app.json.
    func testBundleIDParsedFromFixtureAppJson() {
        let appJsonPath = (fixturePath as NSString).appendingPathComponent("app/app.json")
        let fm = FileManager.default
        guard let data = fm.contents(atPath: appJsonPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let expo = json["expo"] as? [String: Any],
              let ios = expo["ios"] as? [String: Any],
              let bundleID = ios["bundleIdentifier"] as? String else {
            XCTFail("Could not parse bundle ID from fixture app.json")
            return
        }
        XCTAssertEqual(bundleID, "com.test.cfbtest")
    }

    // MARK: - Fixture with ExpoBuildEngine

    /// Verifies that ExpoBuildEngine accepts the fixture project for a build
    /// (using mock runner so no real processes are spawned).
    func testExpoBuildEngineAcceptsFixture() async throws {
        let mockRunner = MockProcessRunner()
        let mockXcodeEngine = MockBuildEngine()
        let engine = ExpoBuildEngine(processRunner: mockRunner, xcodeEngine: mockXcodeEngine)

        var project = ProjectConfig(name: "CFBTest", projectPath: fixturePath)
        project.projectType = .expo
        project.expoAppDirectory = "app"
        project.scheme = "CFBTest"
        project.teamID = "ABCDE12345"

        _ = try await engine.build(project: project)

        // All 3 pre-xcode phases should have run
        XCTAssertEqual(mockRunner.invocations.count, 3)
        XCTAssertEqual(mockXcodeEngine.buildCallCount, 1)
    }
}
