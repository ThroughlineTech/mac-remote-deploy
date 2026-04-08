// Verifies that BuildManager fans out build log lines and status
// transitions to its injected BuildEventBroadcasting sink. TKT-027.
//
// Uses MockBuildEngine (emits a canned log stream and returns a fake
// IPA path) + MockBuildEventBroadcaster (records calls) to drive the
// triggerBuild pipeline end-to-end without touching xcodebuild or the
// real deploy server.
@testable import RemoteDeploy
import XCTest
import Foundation
import RemoteDeployShared

/// In-memory stub implementing BuildHistoryStoring so BuildManager's
/// configure() has something to inject without touching the real
/// on-disk JSON store.
private final class StubBuildHistoryStore: BuildHistoryStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var records: [BuildResult] = []

    func append(_ result: BuildResult) {
        lock.lock(); defer { lock.unlock() }
        records.insert(result, at: 0)
    }
    func recentBuilds() -> [BuildResult] {
        lock.lock(); defer { lock.unlock() }
        return records
    }
}

@MainActor
final class BuildManagerBroadcastTests: XCTestCase {

    private var manager: BuildManager!
    private var broadcaster: MockBuildEventBroadcaster!
    private var buildEngine: MockBuildEngine!
    private var deployServer: MockDeployServer!
    private var notificationManager: NotificationManager!
    private var ipaImporter: IPAImporter!
    private var historyStore: StubBuildHistoryStore!

    override func setUp() async throws {
        try await super.setUp()
        manager = BuildManager()
        broadcaster = MockBuildEventBroadcaster()
        buildEngine = MockBuildEngine()
        deployServer = MockDeployServer()
        notificationManager = NotificationManager.shared
        ipaImporter = IPAImporter()
        historyStore = StubBuildHistoryStore()

        manager.configure(
            buildEngine: buildEngine,
            deployServer: deployServer,
            notificationManager: notificationManager,
            ipaImporter: ipaImporter,
            buildHistoryStore: historyStore,
            buildEventBroadcaster: broadcaster
        )
    }

    override func tearDown() async throws {
        manager = nil
        broadcaster = nil
        buildEngine = nil
        deployServer = nil
        ipaImporter = nil
        historyStore = nil
        try await super.tearDown()
    }

    private func makeProject() -> ProjectConfig {
        var p = ProjectConfig(name: "Test", projectPath: "/tmp/Test.xcodeproj")
        p.scheme = "TestScheme"
        p.bundleID = "com.test.app"
        return p
    }

    /// Waits briefly for pending @MainActor tasks to drain. `triggerBuild`
    /// spawns an internal Task that runs the build pipeline; the log loop
    /// and status assignments happen inside that task asynchronously.
    private func drain(ms: UInt64 = 200) async {
        for _ in 0..<20 {
            await Task.yield()
            try? await Task.sleep(nanoseconds: ms * 100_000)
        }
    }

    // MARK: - Happy path: build log fan-out

    func test_triggerBuild_fansEachLogLineToBroadcaster() async {
        // Emit 3 lines and close the stream.
        buildEngine.stubbedBuildLogStream = AsyncStream { continuation in
            continuation.yield("line one")
            continuation.yield("line two")
            continuation.yield("line three")
            continuation.finish()
        }

        manager.triggerBuild(
            project: makeProject(),
            serverURL: "https://example.test:8443",
            serverPort: 8443,
            certPath: "",
            keyPath: "",
            serverRunning: false,
            onServerStarted: {}
        )

        await drain()

        XCTAssertEqual(broadcaster.buildLogCalls, ["line one", "line two", "line three"],
                       "Each xcodebuild log line should fan out to the broadcaster")
    }

    // MARK: - Happy path: build status transitions

    func test_triggerBuild_happyPath_broadcastsBuildingThenSuccess() async {
        buildEngine.stubbedBuildLogStream = AsyncStream { $0.finish() }
        buildEngine.buildResult = "/tmp/test.ipa"

        manager.triggerBuild(
            project: makeProject(),
            serverURL: "https://example.test:8443",
            serverPort: 8443,
            certPath: "",
            keyPath: "",
            serverRunning: false,
            onServerStarted: {}
        )

        await drain()

        // First status should be .building, last should be .success
        guard broadcaster.buildStatusCalls.count >= 2 else {
            XCTFail("Expected at least 2 status broadcasts, got \(broadcaster.buildStatusCalls.count)")
            return
        }
        if case .building = broadcaster.buildStatusCalls.first! {
            // Expected
        } else {
            XCTFail("First broadcast should be .building, was \(broadcaster.buildStatusCalls.first!)")
        }
        if case .success(let path) = broadcaster.buildStatusCalls.last! {
            XCTAssertEqual(path, "/tmp/test.ipa")
        } else {
            XCTFail("Last broadcast should be .success, was \(broadcaster.buildStatusCalls.last!)")
        }
    }

    // MARK: - Error path: build status transitions

    func test_triggerBuild_failurePath_broadcastsBuildingThenFailure() async {
        buildEngine.stubbedBuildLogStream = AsyncStream { $0.finish() }
        struct TestError: LocalizedError {
            var errorDescription: String? { "simulated xcodebuild failure" }
        }
        buildEngine.buildShouldThrow = TestError()

        manager.triggerBuild(
            project: makeProject(),
            serverURL: "https://example.test:8443",
            serverPort: 8443,
            certPath: "",
            keyPath: "",
            serverRunning: false,
            onServerStarted: {}
        )

        await drain()

        guard broadcaster.buildStatusCalls.count >= 2 else {
            XCTFail("Expected at least 2 status broadcasts, got \(broadcaster.buildStatusCalls.count)")
            return
        }
        if case .failure(let err) = broadcaster.buildStatusCalls.last! {
            XCTAssertTrue(err.contains("simulated xcodebuild failure"))
        } else {
            XCTFail("Last broadcast should be .failure, was \(broadcaster.buildStatusCalls.last!)")
        }
    }

    // MARK: - Import helpers fan out too

    func test_markImportSucceeded_broadcastsSuccess() {
        manager.markImportSucceeded(ipaPath: "/tmp/imported.ipa")

        XCTAssertEqual(broadcaster.buildStatusCalls.count, 1)
        if case .success(let path) = broadcaster.buildStatusCalls.first! {
            XCTAssertEqual(path, "/tmp/imported.ipa")
        } else {
            XCTFail("Expected .success broadcast from markImportSucceeded")
        }
    }

    func test_markImportFailed_broadcastsFailure() {
        manager.markImportFailed(reason: "bad plist")

        XCTAssertEqual(broadcaster.buildStatusCalls.count, 1)
        if case .failure(let err) = broadcaster.buildStatusCalls.first! {
            XCTAssertTrue(err.contains("bad plist"))
        } else {
            XCTFail("Expected .failure broadcast from markImportFailed")
        }
    }

    // MARK: - No broadcaster configured

    func test_triggerBuild_withoutBroadcaster_doesNotCrash() async {
        // Reconfigure without a broadcaster.
        let bare = BuildManager()
        bare.configure(
            buildEngine: buildEngine,
            deployServer: deployServer,
            notificationManager: notificationManager,
            ipaImporter: ipaImporter,
            buildHistoryStore: historyStore
        )
        buildEngine.stubbedBuildLogStream = AsyncStream { continuation in
            continuation.yield("line one")
            continuation.finish()
        }

        bare.triggerBuild(
            project: makeProject(),
            serverURL: "https://example.test:8443",
            serverPort: 8443,
            certPath: "",
            keyPath: "",
            serverRunning: false,
            onServerStarted: {}
        )

        await drain()
        // No assertion — the test passes if nothing crashes.
    }
}
