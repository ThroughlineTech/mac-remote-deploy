// Tests for AuthMiddleware — bearer token extraction, validation, and last-seen updates.
@testable import RemoteDeploy
import XCTest
import Foundation
import RemoteDeployShared

final class AuthMiddlewareTests: XCTestCase {

    private func makeMiddleware() -> (auth: AuthMiddleware, store: MockPairedDeviceStore) {
        let store = MockPairedDeviceStore()
        let auth = AuthMiddleware(deviceStore: store)
        return (auth, store)
    }

    private func seedDevice(in store: MockPairedDeviceStore, rawToken: String = "raw-token-abc") -> (PairedDevice, String) {
        let hash = JSONPairedDeviceStore.hashToken(rawToken)
        let device = PairedDevice(name: "TestDevice", tokenHash: hash)
        store.devices.append(device)
        return (device, hash)
    }

    func test_authenticate_returnsNilWhenAuthorizationHeaderMissing() {
        let (auth, _) = makeMiddleware()
        let result = auth.authenticate(headers: [])
        XCTAssertNil(result)
    }

    func test_authenticate_returnsNilWhenHeaderMissingBearerPrefix() {
        let (auth, _) = makeMiddleware()
        let result = auth.authenticate(headers: [("Authorization", "raw-token-abc")])
        XCTAssertNil(result)
    }

    func test_authenticate_returnsNilWhenTokenIsEmpty() {
        let (auth, _) = makeMiddleware()
        let result = auth.authenticate(headers: [("Authorization", "Bearer ")])
        XCTAssertNil(result)
    }

    func test_authenticate_returnsNilForUnknownToken() {
        let (auth, store) = makeMiddleware()
        _ = seedDevice(in: store)
        let result = auth.authenticate(headers: [("Authorization", "Bearer wrong-token")])
        XCTAssertNil(result)
    }

    func test_authenticate_returnsDeviceForValidToken() {
        let (auth, store) = makeMiddleware()
        let (device, _) = seedDevice(in: store)
        let result = auth.authenticate(headers: [("Authorization", "Bearer raw-token-abc")])
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.id, device.id)
    }

    func test_authenticate_isCaseInsensitiveOnAuthorizationHeaderName() {
        let (auth, store) = makeMiddleware()
        _ = seedDevice(in: store)
        // The middleware lowercases the header name when matching.
        let result = auth.authenticate(headers: [("authorization", "Bearer raw-token-abc")])
        XCTAssertNotNil(result)
    }

    func test_authenticate_acceptsLowercaseBearerKeyword() {
        let (auth, store) = makeMiddleware()
        _ = seedDevice(in: store)
        // The middleware lowercases the header value before checking the "bearer " prefix.
        let result = auth.authenticate(headers: [("Authorization", "bearer raw-token-abc")])
        XCTAssertNotNil(result)
    }

    func test_authenticate_updatesLastSeenForValidToken() {
        let (auth, store) = makeMiddleware()
        let (_, hash) = seedDevice(in: store)
        _ = auth.authenticate(headers: [("Authorization", "Bearer raw-token-abc")])
        XCTAssertEqual(store.updateLastSeenCallCount, 1)
        XCTAssertEqual(store.lastUpdatedTokenHash, hash)
    }

    func test_authenticate_doesNotFailWhenLastSeenUpdateThrows() {
        // updateLastSeen is best-effort; if the store throws, authentication should still succeed.
        let (auth, store) = makeMiddleware()
        _ = seedDevice(in: store)
        struct FakeError: Error {}
        store.updateLastSeenShouldThrow = FakeError()
        let result = auth.authenticate(headers: [("Authorization", "Bearer raw-token-abc")])
        XCTAssertNotNil(result, "Auth should still succeed even if last-seen update fails")
    }
}
