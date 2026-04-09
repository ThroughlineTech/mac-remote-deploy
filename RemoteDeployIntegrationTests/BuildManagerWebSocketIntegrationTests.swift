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
@testable import RemoteDeploy

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
            buildCanceler: NoopBuildCanceler(),
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
