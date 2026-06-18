// Tests for DevicesRouteHandler — list and revoke flows backed by PairedDeviceStoring.
@testable import RemoteDeployServer
import XCTest
import Foundation
import RemoteDeployShared

final class DevicesRouteHandlerTests: XCTestCase {

    private func makeHandler() -> (handler: DevicesRouteHandler, store: MockPairedDeviceStore) {
        let store = MockPairedDeviceStore()
        let handler = DevicesRouteHandler(deviceStore: store)
        return (handler, store)
    }

    // MARK: - list

    func test_list_returnsAllPairedDevices() {
        let (handler, store) = makeHandler()
        store.devices = [
            PairedDevice(name: "iPhone 15", tokenHash: "h1"),
            PairedDevice(name: "iPad Pro", tokenHash: "h2")
        ]
        let req = APITestSupport.makeRequest(method: .GET, uri: "/api/v1/devices")
        let response = handler.list(req)
        XCTAssertEqual(response.status, .ok)
        XCTAssertEqual(store.loadDevicesCallCount, 1)
        let decoded = try? APITestSupport.decoder().decode([PairedDevice].self, from: response.body)
        XCTAssertEqual(decoded?.count, 2)
        XCTAssertEqual(decoded?.map(\.name), ["iPhone 15", "iPad Pro"])
    }

    func test_list_returnsEmptyArrayWhenNoDevices() {
        let (handler, _) = makeHandler()
        let req = APITestSupport.makeRequest(method: .GET, uri: "/api/v1/devices")
        let response = handler.list(req)
        XCTAssertEqual(response.status, .ok)
        let decoded = try? APITestSupport.decoder().decode([PairedDevice].self, from: response.body)
        XCTAssertEqual(decoded?.count, 0)
    }

    func test_list_returns500WhenStoreThrows() {
        let (handler, store) = makeHandler()
        struct FakeError: Error {}
        store.loadDevicesShouldThrow = FakeError()
        let req = APITestSupport.makeRequest(method: .GET, uri: "/api/v1/devices")
        let response = handler.list(req)
        XCTAssertEqual(response.status, .internalServerError)
    }

    // MARK: - revoke

    func test_revoke_deletesDeviceFromStore() {
        let (handler, store) = makeHandler()
        let device = PairedDevice(name: "iPhone", tokenHash: "h1")
        store.devices = [device]
        let req = APITestSupport.makeRequest(method: .DELETE, uri: "/api/v1/devices/\(device.id)")
        let response = handler.revoke(req, deviceID: device.id)
        XCTAssertEqual(response.status, .ok)
        XCTAssertEqual(store.deleteCallCount, 1)
        XCTAssertEqual(store.lastDeletedDeviceID, device.id)
    }

    func test_revoke_returns404WhenStoreThrows() {
        let (handler, store) = makeHandler()
        struct FakeError: Error {}
        store.deleteShouldThrow = FakeError()
        let req = APITestSupport.makeRequest(method: .DELETE, uri: "/api/v1/devices/\(UUID())")
        let response = handler.revoke(req, deviceID: UUID())
        XCTAssertEqual(response.status, .notFound)
    }

    func test_revoke_attemptsDeleteEvenWhenDeviceUnknown() {
        // The handler delegates to the store and only fails on a thrown error.
        // Mock store delete is a no-op for unknown IDs (no throw), so revoke succeeds.
        let (handler, store) = makeHandler()
        let unknownID = UUID()
        let req = APITestSupport.makeRequest(method: .DELETE, uri: "/api/v1/devices/\(unknownID)")
        let response = handler.revoke(req, deviceID: unknownID)
        XCTAssertEqual(response.status, .ok)
        XCTAssertEqual(store.lastDeletedDeviceID, unknownID)
    }
}
