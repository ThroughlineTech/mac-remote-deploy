// Integration tests for the NIODeployServer WebSocket upgrade path from
// TKT-011 / TKT-024 Commit 6. Starts a real HTTPS server with a
// self-signed certificate, pairs a companion device via /api/v1/pair to
// obtain a bearer token, then exercises the `/api/v1/ws` upgrade:
//
//   1. Unauthenticated upgrade → 401 (HTTP fall-through in HTTPHandler)
//   2. Authenticated upgrade → 101 + subscribe + broadcast flows
//
// Shares the self-signed-cert + TrustAllCerts plumbing from
// HTTPServerIntegrationTests; re-created here rather than refactored into
// a helper to keep the cleanup commit self-contained.
import XCTest
import RemoteDeployShared
@testable import RemoteDeployServer

final class WebSocketUpgradeTests: XCTestCase {

    // MARK: - Properties

    private var server: NIODeployServer!
    private var tempDir: URL!
    private var certPath: String!
    private var keyPath: String!
    private var serveRoot: String!
    private var serverPort: Int!
    /// TKT-028: random ephemeral port for the plain-HTTP listener.
    private var httpPort: Int!
    private var session: URLSession!
    private var deviceStore: JSONPairedDeviceStore!

    // MARK: - Setup / Teardown

    override func setUp() async throws {
        try await super.setUp()

        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WebSocketUpgradeTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        certPath = tempDir.appendingPathComponent("cert.pem").path
        keyPath = tempDir.appendingPathComponent("key.pem").path
        serveRoot = tempDir.appendingPathComponent("serve").path
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

        // Wire up the API router + WebSocket authenticator. Mirrors how
        // AppDelegate.configureAPIRouter does it in production: the same
        // AuthMiddleware instance guards both REST routes and the WS
        // upgrade path.
        deviceStore = JSONPairedDeviceStore(directory: tempDir)
        let output = await makeTestRouter(deviceStore: deviceStore, tempDir: tempDir)
        server.apiRouter = output.router
        let auth = output.auth
        server.webSocketAuthenticator = { headers in
            auth.authenticateWebSocket(headers: headers) != nil
        }

        let trustAllDelegate = TrustAllWSCertsDelegate()
        session = URLSession(
            configuration: .ephemeral,
            delegate: trustAllDelegate,
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

    /// Unauthenticated WebSocket upgrade must be rejected. The NIO upgrader
    /// returns nil from shouldUpgrade, the request falls through to
    /// HTTPHandler which returns 401 for `/api/v1/ws`, and URLSession
    /// surfaces that as a handshake failure.
    func testUnauthenticatedUpgradeIsRejected() async throws {
        try await server.start(port: serverPort, httpPort: httpPort, certPath: certPath, keyPath: keyPath)

        let wsURL = URL(string: "wss://localhost:\(serverPort!)/api/v1/ws")!
        let task = session.webSocketTask(with: wsURL)
        task.resume()

        // No Authorization header. The handshake should fail — either the
        // receive call throws, or the task transitions to a non-running
        // state with a non-nil error.
        do {
            _ = try await task.receive()
            XCTFail("Unauthenticated WebSocket upgrade should have failed")
        } catch {
            // Expected: some URLError for the bad handshake response.
            XCTAssertTrue(error is URLError, "Expected URLError, got \(type(of: error)): \(error)")
        }
    }

    /// Authenticated WebSocket upgrade succeeds and end-to-end messaging
    /// works: client subscribes, server broadcasts, client receives.
    ///
    /// Uses the callback form of `URLSessionWebSocketTask.receive(_:)`
    /// rather than the async bridge. The async bridge is not
    /// cooperatively cancellable, so a task-group timeout cannot
    /// interrupt a hung handshake — the test would hang indefinitely if
    /// the upgrade path broke. XCTestExpectation can time out cleanly.
    func testAuthenticatedUpgradeAcceptsAndBroadcastsFlow() async throws {
        try await server.start(port: serverPort, httpPort: httpPort, certPath: certPath, keyPath: keyPath)

        // Pair a device to obtain a real bearer token.
        let token = try pairTestDevice()

        let wsURL = URL(string: "wss://localhost:\(serverPort!)/api/v1/ws")!
        var request = URLRequest(url: wsURL)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let task = session.webSocketTask(with: request)

        let receivedFrame = expectation(description: "WebSocket frame received")
        // Capture the received message for post-assertion. Lock-free use
        // is fine: the receive callback runs on the URLSession delegate
        // queue, the expectation.wait blocks the test queue, and we only
        // read after fulfillment.
        var receivedText: String?

        task.receive { result in
            if case .success(let msg) = result {
                switch msg {
                case .string(let text):
                    receivedText = text
                case .data(let data):
                    receivedText = String(data: data, encoding: .utf8)
                @unknown default:
                    break
                }
                receivedFrame.fulfill()
            }
        }

        task.resume()

        // Send a subscribe frame so the server routes broadcasts to us.
        let sendExpectation = expectation(description: "subscribe sent")
        let subscribeMsg = WSMessage(type: "subscribe", payload: "buildlog")
        let subscribeJSON = String(data: try JSONEncoder().encode(subscribeMsg), encoding: .utf8)!
        task.send(.string(subscribeJSON)) { error in
            // A handshake failure would surface here as an error.
            XCTAssertNil(error, "Subscribe send should not error: \(String(describing: error))")
            sendExpectation.fulfill()
        }
        wait(for: [sendExpectation], timeout: 5.0)

        // Give the server time to process the subscribe frame — the
        // URLSession send callback fires once the frame is on the wire,
        // but the server's WebSocketChannelHandler.channelRead needs a
        // runloop turn to decode it and register the subscription.
        Thread.sleep(forTimeInterval: 0.5)

        // Sanity check: the upgraded channel should be registered with
        // the manager by now. Catches regressions where handlerAdded
        // isn't wired up on post-upgrade channels.
        XCTAssertGreaterThan(
            server.webSocketManager.connectionCount,
            0,
            "Expected at least one WebSocket client registered after upgrade"
        )

        // Broadcast from the server side. The WebSocketManager is the
        // real one owned by NIODeployServer.
        server.webSocketManager.broadcast(type: "buildlog", payload: "hello from the server")

        wait(for: [receivedFrame], timeout: 5.0)

        let text = receivedText ?? ""
        XCTAssertTrue(text.contains("buildlog"), "Expected frame to carry the broadcast type, got: \(text)")
        XCTAssertTrue(text.contains("hello from the server"), "Expected frame to carry the payload, got: \(text)")

        task.cancel(with: .normalClosure, reason: nil)
    }

    /// TKT-058: a browser-style upgrade that carries the bearer token in the
    /// Sec-WebSocket-Protocol subprotocol (no Authorization header) succeeds and
    /// receives broadcasts. This is the path browsers must use.
    func testSubprotocolUpgradeAcceptsAndBroadcastsFlow() async throws {
        try await server.start(port: serverPort, httpPort: httpPort, certPath: certPath, keyPath: keyPath)

        let token = try pairTestDevice()

        let wsURL = URL(string: "wss://localhost:\(serverPort!)/api/v1/ws")!
        // No Authorization header: the token rides in the subprotocol list, just
        // like the PWA's `new WebSocket(url, ['bearer', token])`.
        let task = session.webSocketTask(with: wsURL, protocols: ["bearer", token])

        let receivedFrame = expectation(description: "WebSocket frame received")
        var receivedText: String?
        task.receive { result in
            if case .success(let msg) = result {
                switch msg {
                case .string(let text): receivedText = text
                case .data(let data): receivedText = String(data: data, encoding: .utf8)
                @unknown default: break
                }
                receivedFrame.fulfill()
            }
        }
        task.resume()

        let sendExpectation = expectation(description: "subscribe sent")
        let subscribeMsg = WSMessage(type: "subscribe", payload: "buildlog")
        let subscribeJSON = String(data: try JSONEncoder().encode(subscribeMsg), encoding: .utf8)!
        task.send(.string(subscribeJSON)) { error in
            XCTAssertNil(error, "Subscribe send should not error: \(String(describing: error))")
            sendExpectation.fulfill()
        }
        wait(for: [sendExpectation], timeout: 5.0)
        Thread.sleep(forTimeInterval: 0.5)

        XCTAssertGreaterThan(
            server.webSocketManager.connectionCount,
            0,
            "Expected at least one WebSocket client registered after subprotocol upgrade"
        )

        server.webSocketManager.broadcast(type: "buildlog", payload: "hello over subprotocol")
        wait(for: [receivedFrame], timeout: 5.0)

        let text = receivedText ?? ""
        XCTAssertTrue(text.contains("buildlog"), "Expected frame to carry the broadcast type, got: \(text)")
        XCTAssertTrue(text.contains("hello over subprotocol"), "Expected frame to carry the payload, got: \(text)")

        task.cancel(with: .normalClosure, reason: nil)
    }

    /// Regression for the menu bar build log: the plain-HTTP loopback listener
    /// (:8080 in production, an ephemeral port here) must ALSO upgrade
    /// `/api/v1/ws`. The menu bar connects over `ws://127.0.0.1:8080`; TKT-056
    /// split the listeners but wired the upgrader only into the HTTPS pipeline,
    /// so the loopback upgrade fell through to HTTPHandler and the menu bar's
    /// build log never streamed. Mirrors the authenticated HTTPS flow but over
    /// plain `ws://` on `httpPort` -- the exact surface the menu bar uses.
    func testLoopbackPlainHTTPUpgradeAcceptsAndBroadcastsFlow() async throws {
        try await server.start(port: serverPort, httpPort: httpPort, certPath: certPath, keyPath: keyPath)

        let token = try pairTestDevice()

        let wsURL = URL(string: "ws://localhost:\(httpPort!)/api/v1/ws")!
        var request = URLRequest(url: wsURL)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let task = session.webSocketTask(with: request)

        let receivedFrame = expectation(description: "WebSocket frame received")
        var receivedText: String?
        task.receive { result in
            if case .success(let msg) = result {
                switch msg {
                case .string(let text): receivedText = text
                case .data(let data): receivedText = String(data: data, encoding: .utf8)
                @unknown default: break
                }
                receivedFrame.fulfill()
            }
        }
        task.resume()

        let sendExpectation = expectation(description: "subscribe sent")
        let subscribeMsg = WSMessage(type: "subscribe", payload: "buildlog")
        let subscribeJSON = String(data: try JSONEncoder().encode(subscribeMsg), encoding: .utf8)!
        task.send(.string(subscribeJSON)) { error in
            XCTAssertNil(error, "Subscribe send should not error: \(String(describing: error))")
            sendExpectation.fulfill()
        }
        wait(for: [sendExpectation], timeout: 5.0)
        Thread.sleep(forTimeInterval: 0.5)

        XCTAssertGreaterThan(
            server.webSocketManager.connectionCount,
            0,
            "Expected a WebSocket client registered after the loopback (plain-HTTP) upgrade"
        )

        server.webSocketManager.broadcast(type: "buildlog", payload: "hello over loopback")
        wait(for: [receivedFrame], timeout: 5.0)

        let text = receivedText ?? ""
        XCTAssertTrue(text.contains("buildlog"), "Expected frame to carry the broadcast type, got: \(text)")
        XCTAssertTrue(text.contains("hello over loopback"), "Expected frame to carry the payload, got: \(text)")

        task.cancel(with: .normalClosure, reason: nil)
    }

    // MARK: - Helpers

    /// Writes a paired device directly into the shared store and returns
    /// the bearer token the companion would use to authenticate. We bypass
    /// the `/api/v1/pair` REST flow because the pairing handler held by
    /// the server's APIRouter has its own internal pending-token state
    /// that isn't exposed through NIODeployServer; since the store is
    /// shared with `AuthMiddleware` and the WebSocket authenticator,
    /// writing directly is equivalent from the WS upgrade path's POV.
    private func pairTestDevice() throws -> String {
        let token = JSONPairedDeviceStore.generateToken()
        let tokenHash = JSONPairedDeviceStore.hashToken(token)
        let device = PairedDevice(name: "WSTestDevice", tokenHash: tokenHash)
        try deviceStore.save(device: device)
        return token
    }

    /// Builds the same APIRouter the server uses — mirrors
    /// HTTPServerIntegrationTests.makeTestRouter but scoped locally so this
    /// test file is standalone.
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

    /// Generates a self-signed PEM certificate + key using openssl.
    private func generateSelfSignedCert(certPath: String, keyPath: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = [
            "req", "-x509",
            "-newkey", "rsa:2048",
            "-keyout", keyPath,
            "-out", certPath,
            "-days", "1",
            "-nodes",
            "-subj", "/CN=localhost"
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "WebSocketUpgradeTests",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "openssl failed"]
            )
        }
    }

}

// MARK: - URLSession Delegate (Trust All Certs)

private final class TrustAllWSCertsDelegate: NSObject, URLSessionDelegate {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: serverTrust))
    }
}
