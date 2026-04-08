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
        let handler = PairingRouteHandler(deviceStore: store, serverName: serverName, minInterval: 0)
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

    // MARK: - Rate limiting (TKT-018)

    func test_pair_rateLimits_consecutiveCallsWithin1Second() {
        // With default minInterval = 1.0, two consecutive calls should be throttled.
        let store = MockPairedDeviceStore()
        let handler = PairingRouteHandler(deviceStore: store, serverName: "TestMac") // default 1s

        let token = "throttle-test-\(UUID().uuidString)"
        handler.registerPendingToken(JSONPairedDeviceStore.hashToken(token))

        let body = try! APITestSupport.encoder().encode(PairRequest(token: token, deviceName: "iPhone"))
        let req = APITestSupport.makeRequest(method: .POST, uri: "/api/v1/pair", body: body)

        let firstResponse = handler.pair(req)
        XCTAssertEqual(firstResponse.status, .created)

        // Second call immediately after — should be 429 Too Many Requests.
        let secondResponse = handler.pair(req)
        XCTAssertEqual(secondResponse.status, .tooManyRequests, "Second call within 1s should be throttled")
    }

    func test_pair_locksOutAfter10FailedAttempts() {
        // With minInterval = 0 we can blast the endpoint. After 10 failures we expect 429 lockout.
        let (handler, _) = makeHandler()

        let body = try! APITestSupport.encoder().encode(PairRequest(token: "wrong", deviceName: "iPhone"))
        let req = APITestSupport.makeRequest(method: .POST, uri: "/api/v1/pair", body: body)

        // 10 failed attempts.
        for _ in 0..<10 {
            _ = handler.pair(req)
        }
        // 11th should be locked out with 429.
        let response = handler.pair(req)
        XCTAssertEqual(response.status, .tooManyRequests, "11th attempt should be locked out")
    }

    func test_pair_successResetsFailureCounter() {
        // A successful pair clears the failure counter, allowing further attempts.
        let (handler, _) = makeHandler()
        let token = registerAndReturnToken(handler)

        // Rack up 9 failures (one below lockout).
        let badBody = try! APITestSupport.encoder().encode(PairRequest(token: "wrong", deviceName: "iPhone"))
        let badReq = APITestSupport.makeRequest(method: .POST, uri: "/api/v1/pair", body: badBody)
        for _ in 0..<9 {
            _ = handler.pair(badReq)
        }

        // Successful pair should reset the counter.
        let goodBody = try! APITestSupport.encoder().encode(PairRequest(token: token, deviceName: "iPhone"))
        let goodReq = APITestSupport.makeRequest(method: .POST, uri: "/api/v1/pair", body: goodBody)
        let goodResponse = handler.pair(goodReq)
        XCTAssertEqual(goodResponse.status, .created)

        // Now register a fresh token and confirm we can still fail 9 more times
        // before being locked out (i.e. counter was reset to 0).
        let nextToken = registerAndReturnToken(handler)
        let nextBody = try! APITestSupport.encoder().encode(PairRequest(token: nextToken, deviceName: "iPhone"))
        let nextReq = APITestSupport.makeRequest(method: .POST, uri: "/api/v1/pair", body: nextBody)

        // 9 bad attempts should still not lock out (counter is fresh).
        let badAttempts = (0..<9).map { _ in handler.pair(badReq).status }
        for s in badAttempts {
            XCTAssertNotEqual(s, .tooManyRequests, "Counter reset should allow 9 more failures")
        }

        // The next (good) attempt should succeed since the counter hasn't hit 10 yet.
        XCTAssertEqual(handler.pair(nextReq).status, .created)
    }
}
