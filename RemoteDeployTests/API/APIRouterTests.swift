// Tests for APIRouter — focuses on routing, auth gating, CORS preflight,
// method-not-allowed paths, and malformed UUID handling. Per-handler behavior
// is covered in the dedicated *RouteHandlerTests files.
@testable import RemoteDeploy
import XCTest
import Foundation
import NIOHTTP1
import RemoteDeployShared

@MainActor
final class APIRouterTests: XCTestCase {

    // MARK: - Helpers

    private func makeRouter() -> (router: APIRouter, deviceStore: MockPairedDeviceStore, projectStore: MockProjectStore) {
        let deviceStore = MockPairedDeviceStore()
        let projectStore = MockProjectStore()
        let deps = APIRouterFactory.Dependencies(
            deviceStore: deviceStore,
            projectStore: projectStore,
            installTracker: MockInstallTracker(),
            schemeDetector: MockSchemeDetector(),
            statusProvider: MockStatusProvider(),
            buildTrigger: MockBuildTrigger(),
            buildStatus: MockBuildStatusProvider(),
            buildCanceler: MockBuildCanceler(),
            buildHistory: MockBuildHistoryProvider(),
            settingsProvider: MockSettingsProvider(),
            settingsUpdater: MockSettingsUpdater(),
            serverName: "TestMac"
        )
        return (APIRouterFactory.make(deps: deps).router, deviceStore, projectStore)
    }

    // MARK: - shouldHandle

    func test_shouldHandle_returnsTrueForApiPaths() {
        let (router, _, _) = makeRouter()
        XCTAssertTrue(router.shouldHandle(path: "/api/v1/status"))
        XCTAssertTrue(router.shouldHandle(path: "/api/v1/projects"))
        XCTAssertTrue(router.shouldHandle(path: "/api/anything"))
    }

    func test_shouldHandle_returnsFalseForNonApiPaths() {
        let (router, _, _) = makeRouter()
        XCTAssertFalse(router.shouldHandle(path: "/"))
        XCTAssertFalse(router.shouldHandle(path: "/app/index.html"))
        XCTAssertFalse(router.shouldHandle(path: "/myproject/manifest.plist"))
    }

    // MARK: - Authentication gating

    func test_handle_unauthenticatedNonPairRequest_returns401() {
        let (router, _, _) = makeRouter()
        let req = APITestSupport.makeRequest(method: .GET, uri: "/api/v1/status")
        let response = router.handle(req)
        XCTAssertEqual(response.status, .unauthorized)
    }

    func test_handle_pairingPostBypassesAuth() {
        // POST /api/v1/pair never requires auth (token validation happens inside the handler).
        let (router, _, _) = makeRouter()
        let body = try! APITestSupport.encoder().encode(PairRequest(token: "any", deviceName: "iPhone"))
        let req = APITestSupport.makeRequest(method: .POST, uri: "/api/v1/pair", body: body)
        let response = router.handle(req)
        // Will be 403 (invalid token) — but NOT 401 — proving auth was not enforced.
        XCTAssertNotEqual(response.status, .unauthorized)
        XCTAssertEqual(response.status, .forbidden)
    }

    func test_handle_pairingDeleteRequiresAuth() {
        let (router, _, _) = makeRouter()
        let req = APITestSupport.makeRequest(method: .DELETE, uri: "/api/v1/pair")
        let response = router.handle(req)
        XCTAssertEqual(response.status, .unauthorized)
    }

    // MARK: - 404 / 405

    func test_handle_unknownPath_returns404() {
        let (router, store, _) = makeRouter()
        let token = APITestSupport.pairDevice(in: store)
        let req = APITestSupport.makeRequest(method: .GET, uri: "/api/v1/nonexistent", bearerToken: token)
        let response = router.handle(req)
        XCTAssertEqual(response.status, .notFound)
    }

    func test_handle_unsupportedMethodOnProjects_returns405() {
        let (router, store, _) = makeRouter()
        let token = APITestSupport.pairDevice(in: store)
        let req = APITestSupport.makeRequest(method: .PATCH, uri: "/api/v1/projects", bearerToken: token)
        let response = router.handle(req)
        XCTAssertEqual(response.status, .methodNotAllowed)
    }

    func test_handle_unsupportedMethodOnPair_returns405() {
        let (router, _, _) = makeRouter()
        let req = APITestSupport.makeRequest(method: .GET, uri: "/api/v1/pair")
        let response = router.handle(req)
        XCTAssertEqual(response.status, .methodNotAllowed)
    }

    func test_handle_unsupportedMethodOnSettings_returns405() {
        let (router, store, _) = makeRouter()
        let token = APITestSupport.pairDevice(in: store)
        let req = APITestSupport.makeRequest(method: .DELETE, uri: "/api/v1/settings", bearerToken: token)
        let response = router.handle(req)
        XCTAssertEqual(response.status, .methodNotAllowed)
    }

    // MARK: - CORS preflight

    // NOTE: CORS preflight (OPTIONS → 204) is handled at the HTTPHandler layer in
    // NIODeployServer, not inside APIRouter.handle(). The router treats OPTIONS as
    // just another method, so an OPTIONS request that reaches the router falls
    // through to the 404 path (no route matched). This documents that boundary.
    func test_handle_optionsRequestThroughRouter_returns404NotPreflight() {
        let (router, store, _) = makeRouter()
        let token = APITestSupport.pairDevice(in: store)
        let req = APITestSupport.makeRequest(method: .OPTIONS, uri: "/api/v1/status", bearerToken: token)
        let response = router.handle(req)
        XCTAssertEqual(response.status, .notFound, "Router itself doesn't handle CORS — that's HTTPHandler's job")
    }

    // MARK: - Malformed UUIDs

    func test_handle_invalidProjectUUID_returns400() {
        let (router, store, _) = makeRouter()
        let token = APITestSupport.pairDevice(in: store)
        let req = APITestSupport.makeRequest(method: .GET, uri: "/api/v1/projects/not-a-uuid", bearerToken: token)
        let response = router.handle(req)
        XCTAssertEqual(response.status, .badRequest)
    }

    func test_handle_invalidDeviceUUID_returns400() {
        let (router, store, _) = makeRouter()
        let token = APITestSupport.pairDevice(in: store)
        let req = APITestSupport.makeRequest(method: .DELETE, uri: "/api/v1/devices/not-a-uuid", bearerToken: token)
        let response = router.handle(req)
        XCTAssertEqual(response.status, .badRequest)
    }

    // MARK: - Authenticated request decorates request.device

    func test_handle_authenticatedRequest_attachesDeviceToRequest() {
        // Indirect proof: hit the unpair endpoint which only succeeds if request.device is set.
        let (router, store, _) = makeRouter()
        let (token, _) = APITestSupport.pairDeviceReturningRecord(in: store)
        let req = APITestSupport.makeRequest(method: .DELETE, uri: "/api/v1/pair", bearerToken: token)
        let response = router.handle(req)
        XCTAssertEqual(response.status, .ok)
        XCTAssertEqual(store.deleteCallCount, 1)
    }
}
