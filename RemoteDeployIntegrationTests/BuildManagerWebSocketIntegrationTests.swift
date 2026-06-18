// End-to-end integration test for the TKT-027 broadcast path. Spins up
// a real NIODeployServer with a self-signed cert, opens an authenticated
// WebSocket connection, subscribes to buildlog + buildstatus, then
// drives the broadcast entry points directly (`broadcastBuildLog` /
// `broadcastBuildStatus`) to prove the whole wire works without needing
// a real xcodebuild run.
//
// Uses the same callback-based URLSessionWebSocketTask + XCTestExpectation
// pattern as WebSocketUpgradeTests because the async-bridge form of
// receive() isn't cooperatively cancellable — see the comment in
// WebSocketUpgradeTests for context.
import XCTest
import RemoteDeployShared
@testable import RemoteDeployServer

final class BuildManagerWebSocketIntegrationTests: XCTestCase {

    private var server: NIODeployServer!
    private var tempDir: URL!
    private var certPath: String!
    private var keyPath: String!
    private var serverPort: Int!
    /// TKT-028: random ephemeral port for the plain-HTTP listener.
    private var httpPort: Int!
    private var session: URLSession!
    private var deviceStore: JSONPairedDeviceStore!

    override func setUp() async throws {
        try await super.setUp()

        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BuildManagerWebSocketIntegrationTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        certPath = tempDir.appendingPathComponent("cert.pem").path
        keyPath = tempDir.appendingPathComponent("key.pem").path
        let serveRoot = tempDir.appendingPathComponent("serve").path
        try FileManager.default.createDirectory(atPath: serveRoot, withIntermediateDirectories: true)

        try generateSelfSignedCert(certPath: certPath, keyPath: keyPath)

        serverPort = Int.random(in: 49152...65000)
        repeat {
            httpPort = Int.random(in: 49152...65000)
        } while httpPort == serverPort

        server = NIODeployServer(
            manifestGenerator: ManifestGenerator(),
            installPageGenerator: InstallPageGenerator(),
            serveRoot: serveRoot
        )
        server.setBaseURL("https://localhost:\(serverPort!)")

        deviceStore = JSONPairedDeviceStore(directory: tempDir)
        let output = await makeTestRouter(deviceStore: deviceStore, tempDir: tempDir)
        server.apiRouter = output.router
        let auth = output.auth
        server.webSocketAuthenticator = { headers in
            auth.authenticate(headers: headers) != nil
        }

        session = URLSession(
            configuration: .ephemeral,
            delegate: TrustAllCertsDelegateBMI(),
            delegateQueue: nil
        )
    }

    override func tearDown() async throws {
        if server.isRunning {
            await server.stop()
        }
        server = nil
        session?.invalidateAndCancel()
        session = nil
        deviceStore = nil
        if let tempDir = tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        try await super.tearDown()
    }

    // MARK: - Tests

    /// Broadcasts a log line AND a status transition, and asserts that
    /// the client receives both frames with the expected channel types
    /// and payloads. Proves the full BuildEventBroadcasting → WebSocket
    /// path is wired end-to-end.
    func testBuildLogAndStatusBroadcastsReachSubscribedClient() async throws {
        try await server.start(port: serverPort, httpPort: httpPort, certPath: certPath, keyPath: keyPath)

        let token = try pairTestDevice()

        let wsURL = URL(string: "wss://localhost:\(serverPort!)/api/v1/ws")!
        var request = URLRequest(url: wsURL)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let task = session.webSocketTask(with: request)

        // Receive loop: collect frames until we see both buildlog and
        // buildstatus, or the test times out.
        let buildlogExpectation = expectation(description: "received buildlog frame")
        let buildstatusExpectation = expectation(description: "received buildstatus frame")
        var buildlogText: String?
        var buildstatusText: String?

        func receiveNext() {
            task.receive { result in
                guard case .success(let msg) = result else { return }
                if case .string(let text) = msg {
                    if text.contains("\"type\":\"buildlog\"") && buildlogText == nil {
                        buildlogText = text
                        buildlogExpectation.fulfill()
                    } else if text.contains("\"type\":\"buildstatus\"") && buildstatusText == nil {
                        buildstatusText = text
                        buildstatusExpectation.fulfill()
                    }
                }
                receiveNext()
            }
        }
        receiveNext()

        task.resume()

        // Subscribe to both channels.
        let subscribeExpectations = ["buildlog", "buildstatus"].map { channel -> XCTestExpectation in
            let exp = expectation(description: "subscribe \(channel) sent")
            let msg = WSMessage(type: "subscribe", payload: channel)
            let json = String(data: try! JSONEncoder().encode(msg), encoding: .utf8)!
            task.send(.string(json)) { error in
                XCTAssertNil(error, "subscribe \(channel) should not error: \(String(describing: error))")
                exp.fulfill()
            }
            return exp
        }
        await fulfillment(of: subscribeExpectations, timeout: 5.0)

        // Let the server process both subscribe frames.
        try await Task.sleep(nanoseconds: 500_000_000)

        // Sanity: the client should be registered with the WebSocketManager.
        XCTAssertGreaterThan(server.webSocketManager.connectionCount, 0)

        // Drive the broadcast entry points the same way BuildManager would.
        server.broadcastBuildLog("Compiling TestApp.swift")
        server.broadcastBuildStatus(.success(ipaPath: "/tmp/TestApp.ipa"))

        await fulfillment(of: [buildlogExpectation, buildstatusExpectation], timeout: 5.0)

        // Decode and assert the envelope + payload contents.
        let logEnvelope = try JSONDecoder().decode(WSMessage.self, from: Data((buildlogText ?? "").utf8))
        XCTAssertEqual(logEnvelope.type, "buildlog")
        XCTAssertEqual(logEnvelope.payload, "Compiling TestApp.swift")

        let statusEnvelope = try JSONDecoder().decode(WSMessage.self, from: Data((buildstatusText ?? "").utf8))
        XCTAssertEqual(statusEnvelope.type, "buildstatus")
        let info = try JSONDecoder().decode(BuildStatusInfo.self, from: Data(statusEnvelope.payload.utf8))
        XCTAssertEqual(info.state, "success")
        XCTAssertEqual(info.message, "/tmp/TestApp.ipa")

        task.cancel(with: .normalClosure, reason: nil)
    }

    /// Verifies the terminal failure status is delivered on the buildstatus
    /// channel and decodes to `state == "failure"` with the expected message.
    func testFailureBuildStatusBroadcastReachesSubscribedClient() async throws {
        try await server.start(port: serverPort, httpPort: httpPort, certPath: certPath, keyPath: keyPath)

        let token = try pairTestDevice()

        let wsURL = URL(string: "wss://localhost:\(serverPort!)/api/v1/ws")!
        var request = URLRequest(url: wsURL)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let task = session.webSocketTask(with: request)

        let buildstatusExpectation = expectation(description: "received buildstatus frame")
        var buildstatusText: String?

        func receiveNext() {
            task.receive { result in
                guard case .success(let msg) = result else { return }
                if case .string(let text) = msg,
                   text.contains("\"type\":\"buildstatus\""),
                   buildstatusText == nil {
                    buildstatusText = text
                    buildstatusExpectation.fulfill()
                    return
                }
                receiveNext()
            }
        }
        receiveNext()

        task.resume()

        let subscribeSent = expectation(description: "subscribe buildstatus sent")
        let subscribeMsg = WSMessage(type: "subscribe", payload: "buildstatus")
        let subscribeJSON = String(data: try JSONEncoder().encode(subscribeMsg), encoding: .utf8)!
        task.send(.string(subscribeJSON)) { error in
            XCTAssertNil(error, "subscribe buildstatus should not error: \(String(describing: error))")
            subscribeSent.fulfill()
        }
        await fulfillment(of: [subscribeSent], timeout: 5.0)

        // Allow the server event loop to process the subscribe frame.
        try await Task.sleep(nanoseconds: 500_000_000)

        server.broadcastBuildStatus(.failure(error: "code sign error"))

        await fulfillment(of: [buildstatusExpectation], timeout: 5.0)

        let statusEnvelope = try JSONDecoder().decode(WSMessage.self, from: Data((buildstatusText ?? "").utf8))
        XCTAssertEqual(statusEnvelope.type, "buildstatus")
        let info = try JSONDecoder().decode(BuildStatusInfo.self, from: Data(statusEnvelope.payload.utf8))
        XCTAssertEqual(info.state, "failure")
        XCTAssertEqual(info.message, "code sign error")

        task.cancel(with: .normalClosure, reason: nil)
    }

    /// TKT-045: end-to-end test that wires a real `XcodeBuildEngine` into a
    /// real `BuildManager` and triggers a build with a deliberately invalid
    /// scheme/destination, then asserts the subscribed WebSocket client
    /// receives a terminal `buildstatus` frame with `state == "failure"` and
    /// a message containing real xcodebuild stderr (not just an exit code).
    /// Reproduces the actual TKT-045 preflight-failure path the companion
    /// Build tab depends on to unstick itself.
    func test_triggerBuild_withRealXcodebuildPreflightFailure_broadcastsTerminalFailureFrame() async throws {
        try await server.start(port: serverPort, httpPort: httpPort, certPath: certPath, keyPath: keyPath)

        let token = try pairTestDevice()

        let wsURL = URL(string: "wss://localhost:\(serverPort!)/api/v1/ws")!
        var request = URLRequest(url: wsURL)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let task = session.webSocketTask(with: request)

        // Receive loop: collect every buildstatus frame the server emits
        // and look for the terminal `failure` one. BuildManager broadcasts
        // `.building(...)` before the engine throws, so we can't assume
        // the first frame is the failure — we have to inspect the inner
        // BuildStatusInfo payload (JSON-encoded as a string inside the
        // outer envelope) on each frame.
        let failureExpectation = expectation(description: "received terminal failure frame")
        let failureText = LockedBox<String>()

        func receiveNext() {
            task.receive { result in
                guard case .success(let msg) = result else { return }
                if case .string(let text) = msg,
                   text.contains("\"type\":\"buildstatus\"") {
                    // Decode the outer envelope to peek at the inner
                    // BuildStatusInfo state without depending on a
                    // specific JSON-escaping form.
                    if let envelope = try? JSONDecoder().decode(WSMessage.self, from: Data(text.utf8)),
                       let info = try? JSONDecoder().decode(BuildStatusInfo.self, from: Data(envelope.payload.utf8)),
                       info.state == "failure",
                       failureText.value == nil {
                        failureText.value = text
                        failureExpectation.fulfill()
                        return
                    }
                }
                receiveNext()
            }
        }
        receiveNext()

        task.resume()

        let subscribeSent = expectation(description: "subscribe buildstatus sent")
        let subscribeMsg = WSMessage(type: "subscribe", payload: "buildstatus")
        let subscribeJSON = String(data: try JSONEncoder().encode(subscribeMsg), encoding: .utf8)!
        task.send(.string(subscribeJSON)) { error in
            XCTAssertNil(error, "subscribe buildstatus should not error: \(String(describing: error))")
            subscribeSent.fulfill()
        }
        await fulfillment(of: [subscribeSent], timeout: 5.0)

        // Allow the server event loop to process the subscribe frame.
        try await Task.sleep(nanoseconds: 500_000_000)

        // Wire up a real BuildManager + real XcodeBuildEngine, with the
        // running NIODeployServer as both the deploy server and the
        // broadcaster (the deploy server is unused on the failure path
        // BuildManager exercises here, so it's fine to reuse the live
        // server for both roles). Then trigger a build against this repo's
        // xcodeproj with a scheme that does not exist so xcodebuild exits
        // non-zero almost immediately.
        let realEngine = XcodeBuildEngine()
        let history = InMemoryBuildHistoryForFailureTest()
        let buildManager = await BuildManager()
        await MainActor.run {
            buildManager.configure(
                buildEngine: realEngine,
                deployServer: server,
                notificationManager: NotificationManager.shared,
                ipaImporter: IPAImporter(),
                buildHistoryStore: history,
                buildEventBroadcaster: server
            )
        }

        let xcodeprojPath = try locateRepoXcodeproj()
        var project = ProjectConfig(name: "TKT045-Integration", projectPath: xcodeprojPath)
        project.scheme = "DoesNotExistScheme"
        project.platform = "macOS"
        project.teamID = "ZZZZZZZZZZ"
        project.buildConfiguration = "Debug"
        project.exportMethod = "development"

        await MainActor.run {
            buildManager.triggerBuild(
                project: project,
                serverURL: "https://localhost:\(serverPort!)",
                serverPort: serverPort,
                certPath: "",
                keyPath: "",
                serverRunning: true,
                onServerStarted: {}
            )
        }

        // Real xcodebuild preflight is typically 1-2s; allow up to 30s
        // for slow CI machines.
        await fulfillment(of: [failureExpectation], timeout: 30.0)

        let text = failureText.value ?? ""
        let envelope = try JSONDecoder().decode(WSMessage.self, from: Data(text.utf8))
        XCTAssertEqual(envelope.type, "buildstatus")
        let info = try JSONDecoder().decode(BuildStatusInfo.self, from: Data(envelope.payload.utf8))
        XCTAssertEqual(info.state, "failure")
        // The message should contain a substring of the actual xcodebuild
        // stderr — not just "exit code N". Match on any of the strings
        // xcodebuild emits when a scheme can't be found.
        let lower = (info.message ?? "").lowercased()
        XCTAssertTrue(
            lower.contains("scheme")
                || lower.contains("doesnotexistscheme")
                || lower.contains("not found"),
            "Expected real xcodebuild stderr substring in failure frame, got: \(info.message ?? "<nil>")"
        )

        task.cancel(with: .normalClosure, reason: nil)
    }

    /// Walks up from this test file to find the repo's RemoteDeploy.xcodeproj
    /// so the integration test isn't sensitive to the test runner's working
    /// directory. Same approach as XcodeBuildEngineFailureTests.
    private func locateRepoXcodeproj(file: StaticString = #filePath) throws -> String {
        let testFile = URL(fileURLWithPath: "\(file)")
        var dir = testFile.deletingLastPathComponent()
        let fm = FileManager.default
        for _ in 0..<6 {
            let candidate = dir.appendingPathComponent("RemoteDeploy.xcodeproj").path
            if fm.fileExists(atPath: candidate) {
                return candidate
            }
            dir = dir.deletingLastPathComponent()
        }
        throw XCTSkip("Could not find RemoteDeploy.xcodeproj relative to \(file)")
    }

    // MARK: - Helpers

    /// Writes a paired device directly into the shared store and returns
    /// the bearer token the companion would use to authenticate. Same
    /// pattern as WebSocketUpgradeTests.
    private func pairTestDevice() throws -> String {
        let token = JSONPairedDeviceStore.generateToken()
        let tokenHash = JSONPairedDeviceStore.hashToken(token)
        try deviceStore.save(device: PairedDevice(name: "BMIntegrationTest", tokenHash: tokenHash))
        return token
    }

    @MainActor
    private func makeTestRouter(deviceStore: any PairedDeviceStoring, tempDir: URL) -> APIRouterFactory.Output {
        let stubStatus = ServerStatus(
            serverRunning: true,
            tailscaleConnected: false,
            hostname: "",
            serverPort: 8443,
            buildStatus: BuildStatusInfo(state: "idle")
        )
        final class StubStatusProvider: StatusProviding, @unchecked Sendable {
            let s: ServerStatus
            init(_ s: ServerStatus) { self.s = s }
            func currentStatus() -> ServerStatus { s }
        }
        final class StubBuildTrigger: BuildTriggering, @unchecked Sendable {
            func triggerBuild(projectID: UUID, configuration: String?) -> String? { nil }
        }
        final class StubBuildStatus: BuildStatusProviding, @unchecked Sendable {
            func currentBuildStatus() -> BuildStatusInfo { BuildStatusInfo(state: "idle") }
        }
        final class StubBuildCanceler: BuildCanceling, @unchecked Sendable {
            func cancelCurrentBuild() -> Bool { false }
        }
        final class StubSettingsProvider: SettingsProviding, @unchecked Sendable {
            func currentSettings() -> SettingsData { SettingsData() }
        }
        let deps = APIRouterFactory.Dependencies(
            deviceStore: deviceStore,
            projectStore: UserDefaultsProjectStore(directory: tempDir),
            installTracker: ServerInstallTracker(directory: tempDir),
            schemeDetector: XcodebuildSchemeDetector(),
            statusProvider: StubStatusProvider(stubStatus),
            buildTrigger: StubBuildTrigger(),
            buildStatus: StubBuildStatus(),
            buildCanceler: StubBuildCanceler(),
            buildHistory: EmptyBuildHistoryProvider.empty(),
            settingsProvider: StubSettingsProvider(),
            settingsUpdater: DeferredSettingsUpdater.noop(),
            serverName: "TestMac"
        )
        return APIRouterFactory.make(deps: deps)
    }

    private func generateSelfSignedCert(certPath: String, keyPath: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = [
            "req", "-x509", "-newkey", "rsa:2048",
            "-keyout", keyPath, "-out", certPath,
            "-days", "1", "-nodes", "-subj", "/CN=localhost"
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "BuildManagerWebSocketIntegrationTests", code: Int(process.terminationStatus))
        }
    }
}

// MARK: - TKT-045 helpers

/// Tiny thread-safe value container used by the failure-frame test's
/// `task.receive` callback to publish the captured frame string back to the
/// test body without tripping Sendable warnings on a captured `var`.
private final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T?
    var value: T? {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); defer { lock.unlock() }; _value = newValue }
    }
}

/// In-memory build history store used only by the TKT-045 failure-path
/// integration test. BuildManager.configure() requires a non-nil store; this
/// implementation just records appended results in memory and does no I/O.
private final class InMemoryBuildHistoryForFailureTest: BuildHistoryStoring, @unchecked Sendable {
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

// MARK: - URLSession Delegate

private final class TrustAllCertsDelegateBMI: NSObject, URLSessionDelegate {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}
