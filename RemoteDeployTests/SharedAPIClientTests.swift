import XCTest
import RemoteDeployShared
@testable import RemoteDeploy

// TKT-056 (Phase 3): the API client now lives in RemoteDeployShared and is used
// by both the iOS companion and the macOS menu bar. These tests round-trip every
// endpoint against a stubbed URLProtocol "router", asserting the client hits the
// right HTTP method + path (matching the APIEndpoint contract), sends the bearer
// token (except on /pair), and decodes the server's JSON response.

// MARK: - Stub router

/// Intercepts every request the APIClient makes, records it for assertions, and
/// returns a canned JSON body. Stands in for the real NIO router so the client's
/// method/path/header/decoding behavior can be verified without a live server.
private final class APIClientStubURLProtocol: URLProtocol {
    static var lastRequest: URLRequest?
    static var responseBody = Data()
    static var statusCode = 200

    static func reset() {
        lastRequest = nil
        responseBody = Data()
        statusCode = 200
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequest = request
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: Self.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.responseBody)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class SharedAPIClientTests: XCTestCase {

    private var client: APIClient!
    private let token = "loopback-token"

    override func setUp() {
        super.setUp()
        APIClientStubURLProtocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [APIClientStubURLProtocol.self]
        let session = URLSession(configuration: config)
        client = APIClient(baseURL: URL(string: "http://127.0.0.1:8080")!, token: token, session: session)
    }

    override func tearDown() {
        client = nil
        APIClientStubURLProtocol.reset()
        super.tearDown()
    }

    // MARK: - Helpers

    private func stub<T: Encodable>(_ value: T) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        APIClientStubURLProtocol.responseBody = try! encoder.encode(value)
    }

    private func assertRequest(
        method: String,
        path: String,
        query: String? = nil,
        authenticated: Bool = true,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let req = APIClientStubURLProtocol.lastRequest
        XCTAssertEqual(req?.httpMethod, method, "HTTP method", file: file, line: line)
        XCTAssertEqual(req?.url?.path, path, "URL path", file: file, line: line)
        if let query {
            XCTAssertEqual(req?.url?.query, query, "URL query", file: file, line: line)
        }
        let auth = req?.value(forHTTPHeaderField: "Authorization")
        if authenticated {
            XCTAssertEqual(auth, "Bearer \(token)", "Authorization header", file: file, line: line)
        } else {
            XCTAssertNil(auth, "should be unauthenticated", file: file, line: line)
        }
    }

    // MARK: - Status

    func testGetStatus() async throws {
        stub(ServerStatus(serverRunning: true, tailscaleConnected: true, hostname: "mac.ts.net", serverPort: 8443, buildStatus: BuildStatusInfo(state: "idle")))
        let status = try await client.getStatus()
        assertRequest(method: "GET", path: "/api/v1/status")
        XCTAssertTrue(status.serverRunning)
        XCTAssertEqual(status.hostname, "mac.ts.net")
        XCTAssertEqual(status.buildStatus.state, "idle")
    }

    // MARK: - Projects

    func testListProjects() async throws {
        let project = ProjectConfig(name: "Demo", projectPath: "/tmp/demo")
        stub([project])
        let result = try await client.listProjects()
        assertRequest(method: "GET", path: "/api/v1/projects")
        XCTAssertEqual(result.first?.name, "Demo")
    }

    func testGetProject() async throws {
        let project = ProjectConfig(name: "Demo", projectPath: "/tmp/demo")
        stub(project)
        let result = try await client.getProject(project.id)
        assertRequest(method: "GET", path: "/api/v1/projects/\(project.id.uuidString)")
        XCTAssertEqual(result.id, project.id)
    }

    func testCreateProject() async throws {
        let project = ProjectConfig(name: "Demo", projectPath: "/tmp/demo")
        stub(project)
        let result = try await client.createProject(project)
        assertRequest(method: "POST", path: "/api/v1/projects")
        XCTAssertEqual(result.name, "Demo")
    }

    func testUpdateProject() async throws {
        let project = ProjectConfig(name: "Demo", projectPath: "/tmp/demo")
        stub(project)
        _ = try await client.updateProject(project)
        assertRequest(method: "PUT", path: "/api/v1/projects/\(project.id.uuidString)")
    }

    func testDeleteProject() async throws {
        let id = UUID()
        stub(["deleted": true])
        try await client.deleteProject(id)
        assertRequest(method: "DELETE", path: "/api/v1/projects/\(id.uuidString)")
    }

    // MARK: - Builds

    func testTriggerBuild() async throws {
        let id = UUID()
        stub(BuildStatusInfo(state: "building", projectID: id))
        let info = try await client.triggerBuild(projectID: id, configuration: "Debug")
        assertRequest(method: "POST", path: "/api/v1/projects/\(id.uuidString)/build")
        XCTAssertEqual(info.state, "building")
    }

    func testGetBuildStatus() async throws {
        let id = UUID()
        stub(BuildStatusInfo(state: "idle"))
        _ = try await client.getBuildStatus(projectID: id)
        assertRequest(method: "GET", path: "/api/v1/projects/\(id.uuidString)/build")
    }

    func testCancelBuild() async throws {
        let id = UUID()
        stub(["cancelled": true])
        try await client.cancelBuild(projectID: id)
        assertRequest(method: "DELETE", path: "/api/v1/projects/\(id.uuidString)/build")
    }

    func testGetBuildHistory() async throws {
        stub([BuildResult(projectID: UUID(), success: true, buildLog: "", startTime: Date(), endTime: Date())])
        let history = try await client.getBuildHistory()
        assertRequest(method: "GET", path: "/api/v1/builds")
        XCTAssertEqual(history.count, 1)
    }

    // MARK: - Installs

    func testGetInstalls() async throws {
        stub([InstallRecord(projectName: "Demo", sourceIP: "1.2.3.4", userAgent: "UA")])
        let installs = try await client.getInstalls(limit: 50)
        assertRequest(method: "GET", path: "/api/v1/installs", query: "limit=50")
        XCTAssertEqual(installs.first?.projectName, "Demo")
    }

    func testDeleteInstall() async throws {
        let id = UUID()
        stub(["deleted": true])
        try await client.deleteInstall(id: id)
        assertRequest(method: "DELETE", path: "/api/v1/installs/\(id.uuidString)")
    }

    func testDeleteAllInstalls() async throws {
        stub(["deleted": true])
        try await client.deleteAllInstalls()
        assertRequest(method: "DELETE", path: "/api/v1/installs")
    }

    // MARK: - Settings

    func testGetSettings() async throws {
        stub(SettingsData(serverPort: 8443, hostname: "mac.ts.net"))
        let settings = try await client.getSettings()
        assertRequest(method: "GET", path: "/api/v1/settings")
        XCTAssertEqual(settings.serverPort, 8443)
    }

    func testUpdateSettings() async throws {
        stub(SettingsData(serverPort: 9000))
        let settings = try await client.updateSettings(SettingsData(serverPort: 9000))
        assertRequest(method: "PUT", path: "/api/v1/settings")
        XCTAssertEqual(settings.serverPort, 9000)
    }

    // MARK: - Filesystem

    func testBrowseFilesystemNoPath() async throws {
        stub(FilesystemBrowseResponse(currentPath: "/", directories: [], xcodeProjects: [], xcodeWorkspaces: []))
        _ = try await client.browseFilesystem()
        assertRequest(method: "GET", path: "/api/v1/filesystem/browse")
        XCTAssertNil(APIClientStubURLProtocol.lastRequest?.url?.query)
    }

    func testBrowseFilesystemWithPath() async throws {
        stub(FilesystemBrowseResponse(currentPath: "/tmp", directories: [], xcodeProjects: [], xcodeWorkspaces: []))
        _ = try await client.browseFilesystem(path: "/tmp")
        assertRequest(method: "GET", path: "/api/v1/filesystem/browse", query: "path=/tmp")
    }

    func testDetectSchemes() async throws {
        stub(SchemesResponse(schemes: ["App"]))
        let schemes = try await client.detectSchemes(path: "/tmp/App")
        assertRequest(method: "GET", path: "/api/v1/filesystem/schemes", query: "path=/tmp/App")
        XCTAssertEqual(schemes.schemes, ["App"])
    }

    // MARK: - Devices

    func testListDevices() async throws {
        stub([PairedDevice(name: "iPhone", tokenHash: "abc123")])
        let devices = try await client.listDevices()
        assertRequest(method: "GET", path: "/api/v1/devices")
        XCTAssertEqual(devices.first?.name, "iPhone")
    }

    func testRevokeDevice() async throws {
        let id = UUID()
        stub(["deleted": true])
        try await client.revokeDevice(id: id)
        assertRequest(method: "DELETE", path: "/api/v1/devices/\(id.uuidString)")
    }

    // MARK: - Pairing

    func testCompletePairingIsUnauthenticated() async throws {
        stub(PairResponse(serverName: "Mac", paired: true))
        let response = try await client.completePairing(deviceName: "Browser")
        assertRequest(method: "POST", path: "/api/v1/pair", authenticated: false)
        XCTAssertTrue(response.paired)
    }
}
