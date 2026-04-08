// Integration tests for NIODeployServer.
// Starts a real HTTPS server with a self-signed certificate, makes HTTP requests
// using URLSession, and verifies responses.

import XCTest
import RemoteDeployShared
@testable import RemoteDeploy

final class HTTPServerIntegrationTests: XCTestCase {

    /// Builds a fully wired APIRouter via APIRouterFactory using stub adapters.
    /// All four pre-existing test setups now share this helper, so they only need to
    /// pass the deviceStore and tempDir they want exercised.
    @MainActor
    private static func makeTestRouter(deviceStore: any PairedDeviceStoring, tempDir: URL) -> APIRouterFactory.Output {
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
            settingsUpdater: DeferredSettingsUpdater(),
            serverName: "TestMac"
        )
        return APIRouterFactory.make(deps: deps)
    }


    // MARK: - Properties

    private var server: NIODeployServer!
    private var tempDir: URL!
    private var certPath: String!
    private var keyPath: String!
    private var serveRoot: String!
    private var serverPort: Int!

    /// URLSession configured to trust any certificate (needed for self-signed).
    private var session: URLSession!

    // MARK: - Setup / Teardown

    override func setUp() async throws {
        try await super.setUp()

        // Create a temp directory for certs and serve root
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("HTTPServerIntegrationTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        certPath = tempDir.appendingPathComponent("cert.pem").path
        keyPath = tempDir.appendingPathComponent("key.pem").path
        serveRoot = tempDir.appendingPathComponent("serve").path
        try FileManager.default.createDirectory(atPath: serveRoot, withIntermediateDirectories: true)

        // Generate self-signed certificate using openssl
        try generateSelfSignedCert(certPath: certPath, keyPath: keyPath)

        // Pick a random high port to avoid conflicts
        serverPort = Int.random(in: 49152...65000)

        // Create the server with real generators
        server = NIODeployServer(
            manifestGenerator: ManifestGenerator(),
            installPageGenerator: InstallPageGenerator(),
            serveRoot: serveRoot
        )
        server.setBaseURL("https://localhost:\(serverPort!)")

        // Configure URLSession to trust the self-signed certificate
        let trustAllDelegate = TrustAllCertsDelegate()
        session = URLSession(
            configuration: .ephemeral,
            delegate: trustAllDelegate,
            delegateQueue: nil
        )
    }

    override func tearDown() async throws {
        // Stop the server if it is still running
        if server.isRunning {
            await server.stop()
        }
        server = nil

        session.invalidateAndCancel()
        session = nil

        // Clean up temp directory
        if let tempDir = tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }

        try await super.tearDown()
    }

    // MARK: - Tests

    func testServerStartStop() async throws {
        XCTAssertFalse(server.isRunning, "Server should not be running before start")

        try await server.start(port: serverPort, certPath: certPath, keyPath: keyPath)
        XCTAssertTrue(server.isRunning, "Server should be running after start")
        XCTAssertEqual(server.port, serverPort)

        await server.stop()
        XCTAssertFalse(server.isRunning, "Server should not be running after stop")
    }

    func testRootReturnsIndexPage() async throws {
        try await server.start(port: serverPort, certPath: certPath, keyPath: keyPath)

        let url = URL(string: "https://localhost:\(serverPort!)/")!
        let (data, response) = try await session.data(from: url)

        let httpResponse = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(httpResponse.statusCode, 200)

        let contentType = try XCTUnwrap(httpResponse.value(forHTTPHeaderField: "Content-Type"))
        XCTAssertTrue(contentType.contains("text/html"), "Root should return HTML, got: \(contentType)")

        let body = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(body.contains("RemoteDeploy"), "Index page should contain 'RemoteDeploy'")
        XCTAssertTrue(body.contains("<!DOCTYPE html>"), "Index page should be valid HTML")
    }

    func testProjectInstallPage() async throws {
        // Register a test project
        var project = ProjectConfig(name: "TestApp", projectPath: "/tmp/fake")
        project.bundleID = "com.test.app"
        project.urlSlug = "testapp"
        server.registerProject(project)

        // Create the serve directory for this slug (IPA not needed for install page)
        let slugDir = "\(serveRoot!)/testapp"
        try FileManager.default.createDirectory(atPath: slugDir, withIntermediateDirectories: true)

        try await server.start(port: serverPort, certPath: certPath, keyPath: keyPath)

        let url = URL(string: "https://localhost:\(serverPort!)/testapp/")!
        let (data, response) = try await session.data(from: url)

        let httpResponse = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(httpResponse.statusCode, 200)

        let contentType = try XCTUnwrap(httpResponse.value(forHTTPHeaderField: "Content-Type"))
        XCTAssertTrue(contentType.contains("text/html"), "Install page should return HTML, got: \(contentType)")

        let body = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(body.contains("TestApp"), "Install page should contain the app name")
        XCTAssertTrue(body.contains("manifest.plist"), "Install page should reference manifest.plist")
        XCTAssertTrue(body.contains("itms-services://"), "Install page should contain itms-services link")
    }

    func testManifestPlist() async throws {
        var project = ProjectConfig(name: "TestApp", projectPath: "/tmp/fake")
        project.bundleID = "com.test.app"
        project.urlSlug = "testapp"
        server.registerProject(project)

        try await server.start(port: serverPort, certPath: certPath, keyPath: keyPath)

        let url = URL(string: "https://localhost:\(serverPort!)/testapp/manifest.plist")!
        let (data, response) = try await session.data(from: url)

        let httpResponse = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(httpResponse.statusCode, 200)

        let contentType = try XCTUnwrap(httpResponse.value(forHTTPHeaderField: "Content-Type"))
        XCTAssertTrue(
            contentType.contains("application/xml") || contentType.contains("text/xml"),
            "Manifest should return XML content type, got: \(contentType)"
        )

        let body = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(body.contains("<?xml"), "Manifest should be XML")
        XCTAssertTrue(body.contains("com.test.app"), "Manifest should contain the bundle ID")
        XCTAssertTrue(body.contains("TestApp"), "Manifest should contain the app name")
        XCTAssertTrue(body.contains("software-package"), "Manifest should contain software-package asset kind")
        XCTAssertTrue(body.contains("app.ipa"), "Manifest should reference the IPA URL")
    }

    func testIPADownload() async throws {
        var project = ProjectConfig(name: "TestApp", projectPath: "/tmp/fake")
        project.bundleID = "com.test.app"
        project.urlSlug = "testapp"
        server.registerProject(project)

        // Place a fake IPA file in the serve directory
        let slugDir = "\(serveRoot!)/testapp"
        try FileManager.default.createDirectory(atPath: slugDir, withIntermediateDirectories: true)
        let fakeIPAContent = Data("PK\u{03}\u{04}fake-ipa-content-for-testing".utf8)
        let ipaPath = "\(slugDir)/app.ipa"
        try fakeIPAContent.write(to: URL(fileURLWithPath: ipaPath))

        // Track download callback
        let downloadExpectation = expectation(description: "IPA download callback fired")
        var downloadedSlug: String?
        server.onIPADownload = { slug, _, _ in
            downloadedSlug = slug
            downloadExpectation.fulfill()
        }

        try await server.start(port: serverPort, certPath: certPath, keyPath: keyPath)

        let url = URL(string: "https://localhost:\(serverPort!)/testapp/app.ipa")!
        let (data, response) = try await session.data(from: url)

        let httpResponse = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(httpResponse.statusCode, 200)

        let contentType = try XCTUnwrap(httpResponse.value(forHTTPHeaderField: "Content-Type"))
        XCTAssertTrue(
            contentType.contains("application/octet-stream"),
            "IPA should be served as octet-stream, got: \(contentType)"
        )

        // Verify Content-Disposition header
        let disposition = httpResponse.value(forHTTPHeaderField: "Content-Disposition")
        XCTAssertNotNil(disposition, "Should have Content-Disposition header")
        XCTAssertTrue(disposition?.contains("app.ipa") ?? false, "Content-Disposition should reference app.ipa")

        // Verify the body matches what we wrote
        XCTAssertEqual(data, fakeIPAContent, "Downloaded data should match the fake IPA file")

        // Verify the download callback was invoked
        await fulfillment(of: [downloadExpectation], timeout: 5.0)
        XCTAssertEqual(downloadedSlug, "testapp", "Download callback should report the correct slug")
    }

    func testNotFoundReturns404() async throws {
        try await server.start(port: serverPort, certPath: certPath, keyPath: keyPath)

        let url = URL(string: "https://localhost:\(serverPort!)/nonexistent")!
        let (data, response) = try await session.data(from: url)

        let httpResponse = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(httpResponse.statusCode, 404)

        let body = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(body.contains("Not Found"), "404 response should contain 'Not Found'")
    }

    func testUnregisteredSlugReturns404() async throws {
        // Do NOT register any project -- all slug-based routes should 404
        try await server.start(port: serverPort, certPath: certPath, keyPath: keyPath)

        let installURL = URL(string: "https://localhost:\(serverPort!)/nope/")!
        let (_, installResponse) = try await session.data(from: installURL)
        let installHTTP = try XCTUnwrap(installResponse as? HTTPURLResponse)
        XCTAssertEqual(installHTTP.statusCode, 404)

        let manifestURL = URL(string: "https://localhost:\(serverPort!)/nope/manifest.plist")!
        let (_, manifestResponse) = try await session.data(from: manifestURL)
        let manifestHTTP = try XCTUnwrap(manifestResponse as? HTTPURLResponse)
        XCTAssertEqual(manifestHTTP.statusCode, 404)

        let ipaURL = URL(string: "https://localhost:\(serverPort!)/nope/app.ipa")!
        let (_, ipaResponse) = try await session.data(from: ipaURL)
        let ipaHTTP = try XCTUnwrap(ipaResponse as? HTTPURLResponse)
        XCTAssertEqual(ipaHTTP.statusCode, 404)
    }

    func testIPANotFoundWhenFileIsMissing() async throws {
        // Register a project but do NOT place an IPA file
        var project = ProjectConfig(name: "NoIPA", projectPath: "/tmp/fake")
        project.bundleID = "com.test.noipa"
        project.urlSlug = "noipa"
        server.registerProject(project)

        try await server.start(port: serverPort, certPath: certPath, keyPath: keyPath)

        let url = URL(string: "https://localhost:\(serverPort!)/noipa/app.ipa")!
        let (_, response) = try await session.data(from: url)

        let httpResponse = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(httpResponse.statusCode, 404, "Missing IPA file should return 404")
    }

    // MARK: - API Pairing Tests

    func testPairingOverHTTP() async throws {
        // Set up the server with an API router that includes pairing
        let deviceStore = JSONPairedDeviceStore(directory: tempDir)
        let output = await Self.makeTestRouter(deviceStore: deviceStore, tempDir: tempDir)
        let pairingHandler = output.pairingHandler
        server.apiRouter = output.router

        try await server.start(port: serverPort, certPath: certPath, keyPath: keyPath)

        // The HTTP listener starts on port 8080 alongside HTTPS.
        // For this test, we'll use the HTTPS listener with the API router since
        // the HTTP listener port isn't configurable. The pairing logic is the same.

        // Generate a token and register it as pending
        let token = JSONPairedDeviceStore.generateToken()
        let tokenHash = JSONPairedDeviceStore.hashToken(token)
        pairingHandler.registerPendingToken(tokenHash)

        // Send pairing request
        let pairURL = URL(string: "https://localhost:\(serverPort!)/api/v1/pair")!
        var request = URLRequest(url: pairURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = try JSONEncoder().encode(PairRequest(token: token, deviceName: "TestiPhone"))
        request.httpBody = body

        let (data, response) = try await session.data(for: request)
        let httpResponse = try XCTUnwrap(response as? HTTPURLResponse)

        XCTAssertEqual(httpResponse.statusCode, 201, "Pairing should succeed with status 201")

        let pairResponse = try JSONDecoder().decode(PairResponse.self, from: data)
        XCTAssertTrue(pairResponse.paired, "Response should indicate paired=true")
        XCTAssertEqual(pairResponse.serverName, "TestMac")

        // Verify the device was saved
        let devices = try deviceStore.loadDevices()
        XCTAssertEqual(devices.count, 1, "One device should be paired")
        XCTAssertEqual(devices.first?.name, "TestiPhone")

        // Verify the token works for authenticated requests
        var statusRequest = URLRequest(url: URL(string: "https://localhost:\(serverPort!)/api/v1/status")!)
        statusRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (statusData, statusResponse) = try await session.data(for: statusRequest)
        let statusHTTP = try XCTUnwrap(statusResponse as? HTTPURLResponse)
        XCTAssertEqual(statusHTTP.statusCode, 200, "Authenticated status request should succeed")
    }

    func testPairingWithInvalidToken() async throws {
        let deviceStore = JSONPairedDeviceStore(directory: tempDir)
        let output = await Self.makeTestRouter(deviceStore: deviceStore, tempDir: tempDir)
        server.apiRouter = output.router

        try await server.start(port: serverPort, certPath: certPath, keyPath: keyPath)

        // Do NOT register a pending token — pairing should fail
        let pairURL = URL(string: "https://localhost:\(serverPort!)/api/v1/pair")!
        var request = URLRequest(url: pairURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(PairRequest(token: "bogus", deviceName: "Hacker"))

        let (_, response) = try await session.data(for: request)
        let httpResponse = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(httpResponse.statusCode, 403, "Invalid token should return 403")

        let devices = try deviceStore.loadDevices()
        XCTAssertEqual(devices.count, 0, "No device should be paired")
    }

    func testUnauthenticatedRequestReturns401() async throws {
        let deviceStore = JSONPairedDeviceStore(directory: tempDir)
        let output = await Self.makeTestRouter(deviceStore: deviceStore, tempDir: tempDir)
        server.apiRouter = output.router

        try await server.start(port: serverPort, certPath: certPath, keyPath: keyPath)

        // Request without Authorization header
        let url = URL(string: "https://localhost:\(serverPort!)/api/v1/status")!
        let (_, response) = try await session.data(from: url)
        let httpResponse = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(httpResponse.statusCode, 401, "Unauthenticated request should return 401")
    }

    // MARK: - Helpers

    /// Generates a self-signed PEM certificate and private key using the openssl CLI.
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
                domain: "HTTPServerIntegrationTests",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "openssl failed with exit code \(process.terminationStatus)"]
            )
        }

        // Verify files were created
        XCTAssertTrue(FileManager.default.fileExists(atPath: certPath), "Certificate file should exist")
        XCTAssertTrue(FileManager.default.fileExists(atPath: keyPath), "Key file should exist")
    }
}

// MARK: - URLSession Delegate (Trust All Certs)

/// A URLSession delegate that accepts any server certificate.
/// Used only in tests to allow connections to self-signed HTTPS servers.
private final class TrustAllCertsDelegate: NSObject, URLSessionDelegate {

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
        let credential = URLCredential(trust: serverTrust)
        completionHandler(.useCredential, credential)
    }
}
