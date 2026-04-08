// Smoke tests for APIRouterFactory.
//
// Each test builds a Dependencies struct with mocks, calls APIRouterFactory.make(deps:),
// dispatches a request through the router, and asserts both the response and that the
// expected mock was invoked. These exist as a safety net for TKT-004's refactor and as
// templates that TKT-003 will expand into comprehensive coverage.
@testable import RemoteDeploy
import XCTest
import Foundation
import NIOHTTP1
import RemoteDeployShared

@MainActor
final class APIRouterFactoryTests: XCTestCase {

    // MARK: - Helpers

    /// Holds every dependency the router needs so individual tests can mutate just the ones they care about.
    struct Bag {
        let deviceStore = MockPairedDeviceStore()
        let projectStore = MockProjectStore()
        let installTracker = MockInstallTracker()
        let schemeDetector = MockSchemeDetector()
        let statusProvider = MockStatusProvider()
        let buildTrigger = MockBuildTrigger()
        let buildStatus = MockBuildStatusProvider()
        let buildCanceler = MockBuildCanceler()
        let buildHistory = MockBuildHistoryProvider()
        let settingsProvider = MockSettingsProvider()
        let settingsUpdater = MockSettingsUpdater()
        let serverName = "TestMac"

        func dependencies() -> APIRouterFactory.Dependencies {
            APIRouterFactory.Dependencies(
                deviceStore: deviceStore,
                projectStore: projectStore,
                installTracker: installTracker,
                schemeDetector: schemeDetector,
                statusProvider: statusProvider,
                buildTrigger: buildTrigger,
                buildStatus: buildStatus,
                buildCanceler: buildCanceler,
                buildHistory: buildHistory,
                settingsProvider: settingsProvider,
                settingsUpdater: settingsUpdater,
                serverName: serverName
            )
        }
    }

    /// Decoder configured to match the encoder used by APIResponse.json (ISO8601 dates).
    private func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    /// Builds an APIRequest with the given method, URI, optional body, and optional bearer token.
    private func makeRequest(
        method: HTTPMethod,
        uri: String,
        body: Data = Data(),
        bearerToken: String? = nil
    ) -> APIRequest {
        var headers = HTTPHeaders()
        if let token = bearerToken {
            headers.add(name: "Authorization", value: "Bearer \(token)")
        }
        let head = HTTPRequestHead(version: .init(major: 1, minor: 1), method: method, uri: uri, headers: headers)
        return APIRequest(head: head, body: body)
    }

    /// Pairs a device with the given raw token in the mock store and returns the token.
    /// Used by tests that need to hit authenticated endpoints.
    private func pairDevice(in store: MockPairedDeviceStore, name: String = "iPhone") -> String {
        let token = "test-token-\(UUID().uuidString)"
        let hash = JSONPairedDeviceStore.hashToken(token)
        let device = PairedDevice(name: name, tokenHash: hash)
        store.devices.append(device)
        return token
    }

    // MARK: - Status

    func test_statusEndpoint_returnsStubbedStatus() {
        let bag = Bag()
        bag.statusProvider.stubbedStatus = ServerStatus(
            serverRunning: true,
            tailscaleConnected: true,
            hostname: "macbook.tailnet.ts.net",
            serverPort: 8443,
            buildStatus: BuildStatusInfo(state: "idle")
        )
        let token = pairDevice(in: bag.deviceStore)
        let router = APIRouterFactory.make(deps: bag.dependencies()).router

        let response = router.handle(makeRequest(method: .GET, uri: "/api/v1/status", bearerToken: token))

        XCTAssertEqual(response.status, .ok)
        XCTAssertEqual(bag.statusProvider.currentStatusCallCount, 1)
        let decoded = try? JSONDecoder().decode(ServerStatus.self, from: response.body)
        XCTAssertEqual(decoded?.hostname, "macbook.tailnet.ts.net")
        XCTAssertTrue(decoded?.serverRunning ?? false)
    }

    // MARK: - Pairing

    func test_pairingEndpoint_acceptsPendingToken() {
        let bag = Bag()
        let output = APIRouterFactory.make(deps: bag.dependencies())

        // Server-side: register a pending token (simulates the QR display flow).
        let rawToken = "pair-token-1234"
        let hash = JSONPairedDeviceStore.hashToken(rawToken)
        output.pairingHandler.registerPendingToken(hash)

        let body = try! JSONEncoder().encode(PairRequest(token: rawToken, deviceName: "Test iPhone"))
        let response = output.router.handle(makeRequest(method: .POST, uri: "/api/v1/pair", body: body))

        XCTAssertEqual(response.status, .created)
        XCTAssertEqual(bag.deviceStore.saveCallCount, 1)
        XCTAssertEqual(bag.deviceStore.lastSavedDevice?.name, "Test iPhone")
        XCTAssertEqual(bag.deviceStore.lastSavedDevice?.tokenHash, hash)
    }

    func test_pairingEndpoint_rejectsUnknownToken() {
        let bag = Bag()
        let router = APIRouterFactory.make(deps: bag.dependencies()).router

        let body = try! JSONEncoder().encode(PairRequest(token: "never-registered", deviceName: "Test iPhone"))
        let response = router.handle(makeRequest(method: .POST, uri: "/api/v1/pair", body: body))

        XCTAssertEqual(response.status, .forbidden)
        XCTAssertEqual(bag.deviceStore.saveCallCount, 0)
    }

    // MARK: - Projects

    func test_projectsList_returnsStoreContents() {
        let bag = Bag()
        bag.projectStore.projects = [
            ProjectConfig(name: "Alpha", projectPath: "/Users/me/Alpha.xcodeproj"),
            ProjectConfig(name: "Beta", projectPath: "/Users/me/Beta.xcodeproj")
        ]
        let token = pairDevice(in: bag.deviceStore)
        let router = APIRouterFactory.make(deps: bag.dependencies()).router

        let response = router.handle(makeRequest(method: .GET, uri: "/api/v1/projects", bearerToken: token))

        XCTAssertEqual(response.status, .ok)
        XCTAssertEqual(bag.projectStore.loadProjectsCallCount, 1)
        let decoded = try? JSONDecoder().decode([ProjectConfig].self, from: response.body)
        XCTAssertEqual(decoded?.count, 2)
        XCTAssertEqual(decoded?.map(\.name), ["Alpha", "Beta"])
    }

    // MARK: - Build trigger

    func test_buildTrigger_callsMockBuildTrigger() {
        let bag = Bag()
        let project = ProjectConfig(name: "Alpha", projectPath: "/Users/me/Alpha.xcodeproj")
        bag.projectStore.projects = [project]
        let token = pairDevice(in: bag.deviceStore)
        let router = APIRouterFactory.make(deps: bag.dependencies()).router

        let body = try! JSONEncoder().encode(BuildRequest(configuration: "Debug"))
        let uri = "/api/v1/projects/\(project.id.uuidString)/build"
        let response = router.handle(makeRequest(method: .POST, uri: uri, body: body, bearerToken: token))

        XCTAssertEqual(response.status, .accepted)
        XCTAssertEqual(bag.buildTrigger.triggerBuildCallCount, 1)
        XCTAssertEqual(bag.buildTrigger.lastProjectID, project.id)
        XCTAssertEqual(bag.buildTrigger.lastConfiguration, "Debug")
    }

    func test_buildCancel_returnsConflictWhenNoBuildRunning() {
        let bag = Bag()
        let project = ProjectConfig(name: "Alpha", projectPath: "/Users/me/Alpha.xcodeproj")
        bag.projectStore.projects = [project]
        bag.buildCanceler.stubbedResult = false
        let token = pairDevice(in: bag.deviceStore)
        let router = APIRouterFactory.make(deps: bag.dependencies()).router

        let uri = "/api/v1/projects/\(project.id.uuidString)/build"
        let response = router.handle(makeRequest(method: .DELETE, uri: uri, bearerToken: token))

        XCTAssertEqual(response.status, .conflict)
        XCTAssertEqual(bag.buildCanceler.cancelCurrentBuildCallCount, 1)
    }

    // MARK: - Installs

    func test_installsList_callsInstallTracker() async {
        let bag = Bag()
        // Seed the tracker with a record (records is set in the actor).
        await bag.installTracker.recordInstall(projectName: "Alpha", sourceIP: "10.0.0.5", userAgent: "ua")
        let token = pairDevice(in: bag.deviceStore)
        let router = APIRouterFactory.make(deps: bag.dependencies()).router

        let response = router.handle(makeRequest(method: .GET, uri: "/api/v1/installs", bearerToken: token))

        XCTAssertEqual(response.status, .ok)
        XCTAssertGreaterThan(bag.installTracker.recentInstallsCallCount, 0)
        let decoded = try? decoder().decode([InstallRecord].self, from: response.body)
        XCTAssertEqual(decoded?.count, 1)
        XCTAssertEqual(decoded?.first?.projectName, "Alpha")
    }

    // MARK: - Devices

    func test_devicesList_returnsStoreContents() {
        let bag = Bag()
        let token = pairDevice(in: bag.deviceStore, name: "iPhone 15")
        let router = APIRouterFactory.make(deps: bag.dependencies()).router

        let response = router.handle(makeRequest(method: .GET, uri: "/api/v1/devices", bearerToken: token))

        XCTAssertEqual(response.status, .ok)
        XCTAssertEqual(bag.deviceStore.loadDevicesCallCount, 1)
        let decoded = try? decoder().decode([PairedDevice].self, from: response.body)
        XCTAssertEqual(decoded?.count, 1)
        XCTAssertEqual(decoded?.first?.name, "iPhone 15")
    }

    // MARK: - Settings

    func test_settingsGet_returnsRedactedSettings() {
        let bag = Bag()
        var sample = SettingsData(
            serverPort: 8443,
            hostname: "macbook.tailnet.ts.net",
            certPath: "/etc/cert.pem",
            keyPath: "/etc/key.pem",
            pushNotificationConfig: PushNotificationConfig()
        )
        sample.pushNotificationConfig.prowlAPIKey = "secret-prowl"
        bag.settingsProvider.stubbedSettings = sample
        let token = pairDevice(in: bag.deviceStore)
        let router = APIRouterFactory.make(deps: bag.dependencies()).router

        let response = router.handle(makeRequest(method: .GET, uri: "/api/v1/settings", bearerToken: token))

        XCTAssertEqual(response.status, .ok)
        XCTAssertEqual(bag.settingsProvider.currentSettingsCallCount, 1)
        let decoded = try? JSONDecoder().decode(SettingsData.self, from: response.body)
        XCTAssertEqual(decoded?.certPath, "[configured]")
        XCTAssertEqual(decoded?.keyPath, "[configured]")
        XCTAssertEqual(decoded?.pushNotificationConfig.prowlAPIKey, "[redacted]")
    }

    // MARK: - Filesystem schemes

    func test_filesystemSchemes_callsSchemeDetector() {
        let bag = Bag()
        bag.schemeDetector.stubbedSchemes = ["AppScheme", "TestsScheme"]
        let token = pairDevice(in: bag.deviceStore)
        let router = APIRouterFactory.make(deps: bag.dependencies()).router

        // Use the test user's actual home prefix so the /Users/ guard passes.
        let path = "/Users/test/Project.xcodeproj"
        let response = router.handle(makeRequest(method: .GET, uri: "/api/v1/filesystem/schemes?path=\(path)", bearerToken: token))

        XCTAssertEqual(response.status, .ok)
        XCTAssertEqual(bag.schemeDetector.detectSchemesCallCount, 1)
        XCTAssertEqual(bag.schemeDetector.lastPath, path)
        let decoded = try? JSONDecoder().decode(SchemesResponse.self, from: response.body)
        XCTAssertEqual(decoded?.schemes, ["AppScheme", "TestsScheme"])
    }
}
