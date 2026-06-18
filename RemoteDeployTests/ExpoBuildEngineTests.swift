// Tests for ExpoBuildEngine phase sequencing, cancellation, and error handling.
// Uses MockProcessRunner to verify commands without spawning real processes. TKT-048.
import XCTest
@testable import RemoteDeployServer

final class ExpoBuildEngineTests: XCTestCase {

    private var mockRunner: MockProcessRunner!
    private var mockXcodeEngine: MockBuildEngine!
    private var engine: ExpoBuildEngine!

    /// Temporary directory simulating an Expo project with app.json.
    private var tmpDir: String!

    override func setUp() {
        super.setUp()
        mockRunner = MockProcessRunner()
        mockXcodeEngine = MockBuildEngine()
        engine = ExpoBuildEngine(processRunner: mockRunner, xcodeEngine: mockXcodeEngine)

        // Create a temp directory with a minimal Expo project structure.
        let base = NSTemporaryDirectory() + "ExpoBuildEngineTests-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        let appDir = (base as NSString).appendingPathComponent("app")
        let iosDir = (appDir as NSString).appendingPathComponent("ios")
        try? FileManager.default.createDirectory(atPath: iosDir, withIntermediateDirectories: true)
        // Create app.json so the engine doesn't bail early.
        let appJson = (appDir as NSString).appendingPathComponent("app.json")
        try? "{}".data(using: .utf8)?.write(to: URL(fileURLWithPath: appJson))
        // Create a fake workspace so the engine finds it.
        let fakeWorkspace = (iosDir as NSString).appendingPathComponent("TestApp.xcworkspace")
        try? FileManager.default.createDirectory(atPath: fakeWorkspace, withIntermediateDirectories: true)

        tmpDir = base
    }

    override func tearDown() {
        if let tmpDir {
            try? FileManager.default.removeItem(atPath: tmpDir)
        }
        super.tearDown()
    }

    // MARK: - Phase Sequencing

    /// Verifies that build() runs npm install, expo prebuild, and pod install in order
    /// before delegating to the xcode engine.
    func testBuildRunsPhasesInOrder() async throws {
        var project = ProjectConfig(name: "TestExpo", projectPath: tmpDir)
        project.projectType = .expo
        project.expoAppDirectory = "app"
        project.scheme = "TestApp"
        project.teamID = "ABCDE12345"

        _ = try await engine.build(project: project)

        let invocations = mockRunner.invocations
        XCTAssertEqual(invocations.count, 3, "Should run 3 phases via ProcessRunner (npm, prebuild, pod)")

        // Phase 1: npm install at project root
        XCTAssertEqual(invocations[0].command, "npm")
        XCTAssertEqual(invocations[0].arguments, ["install"])
        XCTAssertEqual(invocations[0].workingDirectory, tmpDir)

        // Phase 2: expo prebuild in app directory
        XCTAssertEqual(invocations[1].command, "npx")
        XCTAssertEqual(invocations[1].arguments, ["expo", "prebuild", "--clean", "--no-install"])
        let expectedAppDir = (tmpDir as NSString).appendingPathComponent("app")
        XCTAssertEqual(invocations[1].workingDirectory, expectedAppDir)

        // Phase 3: pod install in app/ios/
        XCTAssertEqual(invocations[2].command, "pod")
        XCTAssertEqual(invocations[2].arguments, ["install"])
        let expectedIosDir = (expectedAppDir as NSString).appendingPathComponent("ios")
        XCTAssertEqual(invocations[2].workingDirectory, expectedIosDir)

        // Phase 4: xcodebuild delegated to xcode engine
        XCTAssertEqual(mockXcodeEngine.buildCallCount, 1, "Should delegate xcodebuild phase to xcode engine")
    }

    /// Verifies that when expoAppDirectory is nil, the app directory is the project root.
    func testBuildWithoutExpoAppDirectory() async throws {
        // Place app.json at the project root instead of a subdirectory.
        let rootAppJson = (tmpDir as NSString).appendingPathComponent("app.json")
        try "{}".data(using: .utf8)?.write(to: URL(fileURLWithPath: rootAppJson))
        // Create ios/ at root level
        let rootIos = (tmpDir as NSString).appendingPathComponent("ios")
        try FileManager.default.createDirectory(atPath: rootIos, withIntermediateDirectories: true)
        let fakeWs = (rootIos as NSString).appendingPathComponent("Test.xcworkspace")
        try FileManager.default.createDirectory(atPath: fakeWs, withIntermediateDirectories: true)

        var project = ProjectConfig(name: "TestExpo", projectPath: tmpDir)
        project.projectType = .expo
        project.expoAppDirectory = nil
        project.scheme = "Test"
        project.teamID = "ABCDE12345"

        _ = try await engine.build(project: project)

        let invocations = mockRunner.invocations
        XCTAssertEqual(invocations[1].workingDirectory, tmpDir, "expo prebuild should run at project root when expoAppDirectory is nil")
    }

    // MARK: - Error Handling

    /// Verifies that a missing app.json produces a clear error.
    func testBuildFailsWithMissingAppJson() async {
        let emptyDir = NSTemporaryDirectory() + "EmptyDir-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: emptyDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: emptyDir) }

        var project = ProjectConfig(name: "NoApp", projectPath: emptyDir)
        project.projectType = .expo
        project.scheme = "NoApp"
        project.teamID = "ABCDE12345"

        do {
            _ = try await engine.build(project: project)
            XCTFail("Expected ExpoBuildError.missingAppJson")
        } catch let error as ExpoBuildError {
            switch error {
            case .missingAppJson:
                break // expected
            default:
                XCTFail("Expected missingAppJson, got \(error)")
            }
        } catch {
            XCTFail("Expected ExpoBuildError, got \(error)")
        }
    }

    /// Verifies that a failing phase (e.g., npm install fails) stops the pipeline.
    func testBuildStopsOnPhaseFailure() async {
        mockRunner.errorsByCommand["npm"] = ProcessRunnerError.nonZeroExit(
            executable: "npm", exitCode: 1, lastStderr: "ERR! missing script"
        )

        var project = ProjectConfig(name: "TestExpo", projectPath: tmpDir)
        project.projectType = .expo
        project.expoAppDirectory = "app"
        project.scheme = "TestApp"
        project.teamID = "ABCDE12345"

        do {
            _ = try await engine.build(project: project)
            XCTFail("Expected build to fail on npm install")
        } catch {
            // npm should be the only invocation — later phases should not run.
            XCTAssertEqual(mockRunner.invocations.count, 1, "Only npm should have been attempted")
            XCTAssertEqual(mockXcodeEngine.buildCallCount, 0, "xcodebuild should not run after failure")
        }
    }

    // MARK: - Cancellation

    /// Verifies that cancelling the runner prevents subsequent phases from starting.
    func testCancellationPreventsSubsequentPhases() async {
        // Cancel right after the first phase records
        mockRunner.errorsByCommand["npx"] = ProcessRunnerError.cancelled

        var project = ProjectConfig(name: "TestExpo", projectPath: tmpDir)
        project.projectType = .expo
        project.expoAppDirectory = "app"
        project.scheme = "TestApp"
        project.teamID = "ABCDE12345"

        do {
            _ = try await engine.build(project: project)
            XCTFail("Expected build to be cancelled")
        } catch {
            // npm install succeeded, expo prebuild threw cancelled
            XCTAssertEqual(mockRunner.invocations.count, 2, "npm + npx should be recorded")
            XCTAssertEqual(mockXcodeEngine.buildCallCount, 0, "xcodebuild should not run after cancellation")
        }
    }

    /// Verifies that cancelBuild() propagates to both the process runner and xcode engine.
    func testCancelBuildForwardsToRunnerAndXcodeEngine() async {
        await engine.cancelBuild()

        XCTAssertTrue(mockRunner.isCancelled, "ProcessRunner should be cancelled")
        XCTAssertEqual(mockXcodeEngine.cancelBuildCallCount, 1, "Xcode engine should receive cancel")
    }

    // MARK: - Status

    /// Verifies that status transitions to failure after a build error.
    func testStatusIsFailureAfterError() async {
        let emptyDir = NSTemporaryDirectory() + "StatusTest-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: emptyDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: emptyDir) }

        var project = ProjectConfig(name: "Fail", projectPath: emptyDir)
        project.projectType = .expo
        project.scheme = "Fail"
        project.teamID = "ABCDE12345"

        _ = try? await engine.build(project: project)

        if case .failure = engine.status {
            // expected
        } else {
            XCTFail("Expected .failure status, got \(engine.status)")
        }
    }

    /// Verifies that status is .success after a successful build.
    func testStatusIsSuccessAfterBuild() async throws {
        var project = ProjectConfig(name: "TestExpo", projectPath: tmpDir)
        project.projectType = .expo
        project.expoAppDirectory = "app"
        project.scheme = "TestApp"
        project.teamID = "ABCDE12345"

        _ = try await engine.build(project: project)

        if case .success = engine.status {
            // expected
        } else {
            XCTFail("Expected .success status, got \(engine.status)")
        }
    }

    // MARK: - Scheme Filtering (TKT-049)

    /// Verifies that detectSchemes filters out CocoaPods dependency schemes,
    /// keeping only the scheme matching the app .xcodeproj name.
    func testDetectSchemesFiltersCocoaPodsSchemes() async throws {
        // Set up: ios/ already has TestApp.xcworkspace from setUp().
        // Add TestApp.xcodeproj and Pods.xcodeproj to simulate Expo layout.
        let iosDir = (tmpDir as NSString)
            .appendingPathComponent("app")
            .appending("/ios")
        let appProj = (iosDir as NSString).appendingPathComponent("TestApp.xcodeproj")
        let podsProj = (iosDir as NSString).appendingPathComponent("Pods.xcodeproj")
        try FileManager.default.createDirectory(atPath: appProj, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: podsProj, withIntermediateDirectories: true)

        // Stub the xcode engine to return a mix of app + pod schemes.
        mockXcodeEngine.detectSchemesResult = [
            "TestApp", "boost", "DoubleConversion", "EXConstants", "Expo",
            "ExpoModulesCore", "FBLazyVector", "React-Core", "RCT-Folly",
            "hermes-engine", "Pods-TestApp"
        ]

        let schemes = try await engine.detectSchemes(at: tmpDir)

        XCTAssertEqual(schemes, ["TestApp"],
                       "Only the app scheme matching the .xcodeproj name should be returned")
    }

    /// Verifies that detectSchemes falls back to the full list when no
    /// .xcodeproj files exist (e.g., if the directory layout is unexpected).
    func testDetectSchemesFallsBackWhenNoXcodeproj() async throws {
        // setUp() creates ios/ with only a .xcworkspace — no .xcodeproj files.
        mockXcodeEngine.detectSchemesResult = ["SchemeA", "SchemeB"]

        let schemes = try await engine.detectSchemes(at: tmpDir)

        XCTAssertEqual(schemes, ["SchemeA", "SchemeB"],
                       "Should return the full list when no .xcodeproj is found for filtering")
    }

    /// Verifies that if the filter would produce an empty result (no scheme
    /// name matches a .xcodeproj), the full list is returned as a fallback.
    func testDetectSchemesFallsBackWhenFilterEmpty() async throws {
        let iosDir = (tmpDir as NSString)
            .appendingPathComponent("app")
            .appending("/ios")
        let appProj = (iosDir as NSString).appendingPathComponent("MyApp.xcodeproj")
        try FileManager.default.createDirectory(atPath: appProj, withIntermediateDirectories: true)

        // No scheme matches "MyApp"
        mockXcodeEngine.detectSchemesResult = ["OtherScheme", "AnotherScheme"]

        let schemes = try await engine.detectSchemes(at: tmpDir)

        XCTAssertEqual(schemes, ["OtherScheme", "AnotherScheme"],
                       "Should return the full list when filter produces no matches")
    }
}
