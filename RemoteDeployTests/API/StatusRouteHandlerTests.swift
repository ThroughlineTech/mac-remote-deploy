// Tests for StatusRouteHandler — thin wrapper around StatusProviding.
@testable import RemoteDeployServer
import XCTest
import Foundation
import RemoteDeployShared

final class StatusRouteHandlerTests: XCTestCase {

    func test_getStatus_returnsProvidedSnapshot() {
        let provider = MockStatusProvider()
        provider.stubbedStatus = ServerStatus(
            serverRunning: true,
            tailscaleConnected: true,
            hostname: "macbook.tailnet.ts.net",
            serverPort: 8443,
            buildStatus: BuildStatusInfo(state: "building", message: "Compiling")
        )
        let handler = StatusRouteHandler(statusProvider: provider)

        let req = APITestSupport.makeRequest(method: .GET, uri: "/api/v1/status")
        let response = handler.getStatus(req)

        XCTAssertEqual(response.status, .ok)
        XCTAssertEqual(provider.currentStatusCallCount, 1)

        let decoded = try? APITestSupport.decoder().decode(ServerStatus.self, from: response.body)
        XCTAssertEqual(decoded?.hostname, "macbook.tailnet.ts.net")
        XCTAssertEqual(decoded?.serverPort, 8443)
        XCTAssertTrue(decoded?.serverRunning ?? false)
        XCTAssertTrue(decoded?.tailscaleConnected ?? false)
        XCTAssertEqual(decoded?.buildStatus.state, "building")
        XCTAssertEqual(decoded?.buildStatus.message, "Compiling")
    }

    func test_getStatus_callsProviderEachInvocation() {
        let provider = MockStatusProvider()
        let handler = StatusRouteHandler(statusProvider: provider)
        let req = APITestSupport.makeRequest(method: .GET, uri: "/api/v1/status")

        _ = handler.getStatus(req)
        _ = handler.getStatus(req)
        _ = handler.getStatus(req)

        XCTAssertEqual(provider.currentStatusCallCount, 3)
    }

    func test_getStatus_returnsValidJSONForIdleState() {
        let provider = MockStatusProvider()
        // Default stubbed status uses state="idle" — verify it serializes cleanly.
        let handler = StatusRouteHandler(statusProvider: provider)
        let req = APITestSupport.makeRequest(method: .GET, uri: "/api/v1/status")
        let response = handler.getStatus(req)
        XCTAssertEqual(response.status, .ok)
        XCTAssertNoThrow(try APITestSupport.decoder().decode(ServerStatus.self, from: response.body))
    }
}
