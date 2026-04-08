// Tests for PairingRouteHandler — pair and unpair flows, token bookkeeping,
// and the cleanupExpiredTokens behavior (which is currently dead code; see TKT-018).
@testable import RemoteDeploy
import XCTest
import Foundation
import RemoteDeployShared

@MainActor
final class PairingRouteHandlerTests: XCTestCase {

    private func makeHandler(serverName: String = "TestMac") -> (handler: PairingRouteHandler, store: MockPairedDeviceStore) {
        let store = MockPairedDeviceStore()
        let handler = PairingRouteHandler(deviceStore: store, serverName: serverName)
        return (handler, store)
    }

    private func registerAndReturnToken(_ handler: PairingRouteHandler) -> String {
        let token = "raw-pair-\(UUID().uuidString)"
        handler.registerPendingToken(JSONPairedDeviceStore.hashToken(token))
        return token
    }

    // MARK: - pair() happy path

    func test_pair_succeedsWithValidPendingToken() {
        let (handler, store) = makeHandler(serverName: "MyMac")
        let token = registerAndReturnToken(handler)

        let body = try! APITestSupport.encoder().encode(PairRequest(token: token, deviceName: "iPhone 15"))
        let req = APITestSupport.makeRequest(method: .POST, uri: "/api/v1/pair", body: body)
        let response = handler.pair(req)

        XCTAssertEqual(response.status, .created)
        XCTAssertEqual(store.saveCallCount, 1)
        XCTAssertEqual(store.lastSavedDevice?.name, "iPhone 15")
        XCTAssertEqual(store.lastSavedDevice?.tokenHash, JSONPairedDeviceStore.hashToken(token))

        let decoded = try? APITestSupport.decoder().decode(PairResponse.self, from: response.body)
        XCTAssertEqual(decoded?.serverName, "MyMac")
        XCTAssertTrue(decoded?.paired ?? false)
    }

    func test_pair_savesPushEndpointWhenProvided() {
        let (handler, store) = makeHandler()
        let token = registerAndReturnToken(handler)

        let body = try! APITestSupport.encoder().encode(
            PairRequest(token: token, deviceName: "iPhone", pushEndpoint: "https://push.example.com/abc")
        )
        let req = APITestSupport.makeRequest(method: .POST, uri: "/api/v1/pair", body: body)
        _ = handler.pair(req)

        XCTAssertEqual(store.lastSavedDevice?.pushEndpoint, "https://push.example.com/abc")
    }

    // MARK: - pair() failure paths

    func test_pair_returns400ForMalformedBody() {
        let (handler, store) = makeHandler()
        let req = APITestSupport.makeRequest(method: .POST, uri: "/api/v1/pair", body: Data("not-json".utf8))
        let response = handler.pair(req)
        XCTAssertEqual(response.status, .badRequest)
        XCTAssertEqual(store.saveCallCount, 0)
    }

    func test_pair_returns403ForUnregisteredToken() {
        let (handler, store) = makeHandler()
        // Do NOT register any token.
        let body = try! APITestSupport.encoder().encode(PairRequest(token: "never-registered", deviceName: "iPhone"))
        let req = APITestSupport.makeRequest(method: .POST, uri: "/api/v1/pair", body: body)
        let response = handler.pair(req)
        XCTAssertEqual(response.status, .forbidden)
        XCTAssertEqual(store.saveCallCount, 0)
    }

    func test_pair_consumesTokenSoSecondClaimFails() {
        let (handler, store) = makeHandler()
        let token = registerAndReturnToken(handler)

        let body = try! APITestSupport.encoder().encode(PairRequest(token: token, deviceName: "iPhone"))
        let req = APITestSupport.makeRequest(method: .POST, uri: "/api/v1/pair", body: body)

        let firstResponse = handler.pair(req)
        XCTAssertEqual(firstResponse.status, .created)

        let secondResponse = handler.pair(req)
        XCTAssertEqual(secondResponse.status, .forbidden, "Second pair with same token should fail because the token was consumed")
        XCTAssertEqual(store.saveCallCount, 1, "Only one device should have been saved")
    }

    func test_pair_returns500WhenStoreSaveThrows() {
        let (handler, store) = makeHandler()
        let token = registerAndReturnToken(handler)
        struct FakeError: Error {}
        store.saveShouldThrow = FakeError()

        let body = try! APITestSupport.encoder().encode(PairRequest(token: token, deviceName: "iPhone"))
        let req = APITestSupport.makeRequest(method: .POST, uri: "/api/v1/pair", body: body)
        let response = handler.pair(req)
        XCTAssertEqual(response.status, .internalServerError)
    }

    // MARK: - unpair()

    func test_unpair_deletesAuthenticatedDevice() {
        let (handler, store) = makeHandler()
        let device = PairedDevice(name: "iPhone", tokenHash: "hash")
        store.devices.append(device)

        var req = APITestSupport.makeRequest(method: .DELETE, uri: "/api/v1/pair")
        req.device = device

        let response = handler.unpair(req)
        XCTAssertEqual(response.status, .ok)
        XCTAssertEqual(store.deleteCallCount, 1)
        XCTAssertEqual(store.lastDeletedDeviceID, device.id)
    }

    func test_unpair_returns401WhenRequestHasNoDevice() {
        let (handler, store) = makeHandler()
        let req = APITestSupport.makeRequest(method: .DELETE, uri: "/api/v1/pair")
        // request.device left nil
        let response = handler.unpair(req)
        XCTAssertEqual(response.status, .unauthorized)
        XCTAssertEqual(store.deleteCallCount, 0)
    }

    func test_unpair_returns500WhenStoreDeleteThrows() {
        let (handler, store) = makeHandler()
        let device = PairedDevice(name: "iPhone", tokenHash: "hash")
        store.devices.append(device)
        struct FakeError: Error {}
        store.deleteShouldThrow = FakeError()

        var req = APITestSupport.makeRequest(method: .DELETE, uri: "/api/v1/pair")
        req.device = device
        let response = handler.unpair(req)
        XCTAssertEqual(response.status, .internalServerError)
    }

    // MARK: - registerPendingToken / cleanupExpiredTokens

    func test_registerPendingToken_isIdempotentForSameHash() {
        let (handler, _) = makeHandler()
        let hash = JSONPairedDeviceStore.hashToken("dup-token")
        handler.registerPendingToken(hash)
        handler.registerPendingToken(hash)
        // No public way to count entries, but pair should still succeed.
        let body = try! APITestSupport.encoder().encode(PairRequest(token: "dup-token", deviceName: "iPhone"))
        let req = APITestSupport.makeRequest(method: .POST, uri: "/api/v1/pair", body: body)
        XCTAssertEqual(handler.pair(req).status, .created)
    }

    func test_cleanupExpiredTokens_doesNotRemoveFreshTokens() {
        // Just-registered tokens are never older than the 10-minute cutoff,
        // so cleanup is a no-op and the token can still be used to pair.
        let (handler, _) = makeHandler()
        let token = registerAndReturnToken(handler)

        handler.cleanupExpiredTokens()

        let body = try! APITestSupport.encoder().encode(PairRequest(token: token, deviceName: "iPhone"))
        let req = APITestSupport.makeRequest(method: .POST, uri: "/api/v1/pair", body: body)
        XCTAssertEqual(handler.pair(req).status, .created)
    }

    // NOTE: Verifying that cleanupExpiredTokens() actually removes >10-minute-old tokens
    // requires either a clock-injection seam or a 10+ minute test delay. PairingRouteHandler
    // currently uses Date() directly with no injection point, and pendingTokens is private —
    // so we can't time-travel from a unit test without modifying production code.
    //
    // More importantly: cleanupExpiredTokens() is **never called anywhere** in the codebase.
    // The pair() method does not check token age either, so the documented "10-minute pairing
    // token TTL" from docs/SECURITY_AUDIT.md is currently UNENFORCED. Wiring cleanup into the
    // pair flow (or into a periodic timer) and adding the matching test is tracked in TKT-018.
}
