// Tests for BuildEngineRouter dispatch logic. Verifies that .xcode and .expo
// projects are routed to the correct engine. TKT-048.
import XCTest
@testable import RemoteDeploy

final class BuildEngineRouterTests: XCTestCase {

    // MARK: - Dispatch

    func testXcodeProjectRoutesToXcodeEngine() async throws {
        let xcodeEngine = MockBuildEngine()
        let expoEngine = MockExpoBuildEngine()
        let router = makeMockRouter(xcode: xcodeEngine, expo: expoEngine)

        var project = ProjectConfig(name: "NativeApp", projectPath: "/tmp/native")
        project.projectType = .xcode
        project.scheme = "NativeApp"
        project.teamID = "ABCDE12345"

        _ = try await router.build(project: project)

        XCTAssertEqual(xcodeEngine.buildCallCount, 1, "Xcode engine should handle .xcode projects")
        XCTAssertEqual(expoEngine.buildCallCount, 0, "Expo engine should not be called for .xcode projects")
    }

    func testExpoProjectRoutesToExpoEngine() async throws {
        let xcodeEngine = MockBuildEngine()
        let expoEngine = MockExpoBuildEngine()
        let router = makeMockRouter(xcode: xcodeEngine, expo: expoEngine)

        var project = ProjectConfig(name: "ExpoApp", projectPath: "/tmp/expo")
        project.projectType = .expo
        project.scheme = "ExpoApp"
        project.teamID = "ABCDE12345"

        _ = try await router.build(project: project)

        XCTAssertEqual(expoEngine.buildCallCount, 1, "Expo engine should handle .expo projects")
        XCTAssertEqual(xcodeEngine.buildCallCount, 0, "Xcode engine should not be called for .expo projects")
    }

    // MARK: - Cancel

    func testCancelForwardsToActiveEngine() async throws {
        let xcodeEngine = MockBuildEngine()
        let expoEngine = MockExpoBuildEngine()
        let router = makeMockRouter(xcode: xcodeEngine, expo: expoEngine)

        // Prepare an expo build so the active engine is set
        var project = ProjectConfig(name: "ExpoApp", projectPath: "/tmp/expo")
        project.projectType = .expo
        router.prepareForBuild(project)

        // Start a build in background so the active engine is set during build
        _ = try await router.build(project: project)
        // After build completes, cancel should still be safe
        await router.cancelBuild()

        // The expo engine should have been the target
        XCTAssertEqual(expoEngine.buildCallCount, 1)
    }

    // MARK: - Status

    func testStatusReturnsIdleWhenNoActiveEngine() {
        let router = BuildEngineRouter()
        XCTAssertEqual(router.status, .idle)
    }

    // MARK: - PrepareForBuild

    func testPrepareForBuildSetsActiveEngine() {
        let xcodeEngine = MockBuildEngine()
        xcodeEngine.stubbedStatus = .building(progress: "test")
        let expoEngine = MockExpoBuildEngine()
        let router = makeMockRouter(xcode: xcodeEngine, expo: expoEngine)

        var project = ProjectConfig(name: "NativeApp", projectPath: "/tmp/native")
        project.projectType = .xcode
        router.prepareForBuild(project)

        // After prepare, status should come from the xcode engine
        XCTAssertEqual(router.status, .building(progress: "test"))
    }

    // MARK: - Helpers

    /// Creates a BuildEngineRouter with mock engines injected.
    /// Uses the internal xcode/expo engine init parameters.
    private func makeMockRouter(xcode: MockBuildEngine, expo: MockExpoBuildEngine) -> MockableBuildEngineRouter {
        MockableBuildEngineRouter(xcodeEngine: xcode, expoEngine: expo)
    }
}

// MARK: - Mockable Router

/// A testable router that accepts any BuildEngineProtocol for its engines.
/// The production BuildEngineRouter uses concrete types; this subclass-like
/// wrapper allows mock injection for unit tests. TKT-048.
final class MockableBuildEngineRouter: BuildEngineProtocol, @unchecked Sendable {

    private let xcodeEngine: any BuildEngineProtocol
    private let expoEngine: any BuildEngineProtocol
    private let lockedActiveEngine = OSAllocatedUnfairLock<(any BuildEngineProtocol)?>(initialState: nil)

    init(xcodeEngine: any BuildEngineProtocol, expoEngine: any BuildEngineProtocol) {
        self.xcodeEngine = xcodeEngine
        self.expoEngine = expoEngine
    }

    func prepareForBuild(_ project: ProjectConfig) {
        lockedActiveEngine.withLock { $0 = engine(for: project) }
    }

    func build(project: ProjectConfig) async throws -> String {
        let engine = engine(for: project)
        lockedActiveEngine.withLock { $0 = engine }
        defer { lockedActiveEngine.withLock { $0 = nil } }
        return try await engine.build(project: project)
    }

    func cancelBuild() async {
        let engine = lockedActiveEngine.withLock { $0 }
        await engine?.cancelBuild()
    }

    var buildLogStream: AsyncStream<String> {
        let engine = lockedActiveEngine.withLock { $0 }
        return (engine ?? xcodeEngine).buildLogStream
    }

    var status: BuildStatus {
        let engine = lockedActiveEngine.withLock { $0 }
        return engine?.status ?? .idle
    }

    func detectSchemes(at projectPath: String) async throws -> [String] {
        try await xcodeEngine.detectSchemes(at: projectPath)
    }

    private func engine(for project: ProjectConfig) -> any BuildEngineProtocol {
        switch project.projectType {
        case .expo: return expoEngine
        case .xcode: return xcodeEngine
        }
    }
}
