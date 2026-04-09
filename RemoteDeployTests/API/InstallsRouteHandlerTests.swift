// Tests for InstallsRouteHandler — list endpoint with limit query parameter handling.
@testable import RemoteDeploy
import XCTest
import Foundation
import RemoteDeployShared

@MainActor
final class InstallsRouteHandlerTests: XCTestCase {

    private func makeHandler() -> (handler: InstallsRouteHandler, tracker: MockInstallTracker) {
        let tracker = MockInstallTracker()
        let handler = InstallsRouteHandler(installTracker: tracker)
        return (handler, tracker)
    }

    private func seedInstalls(in tracker: MockInstallTracker, count: Int) async {
        for i in 0..<count {
            await tracker.recordInstall(projectName: "Project\(i)", sourceIP: "10.0.0.\(i)", userAgent: "ua-\(i)")
        }
    }

    // MARK: - default limit

    func test_list_returnsRecordsWithDefaultLimit50() async {
        let (handler, tracker) = makeHandler()
        await seedInstalls(in: tracker, count: 3)
        let req = APITestSupport.makeRequest(method: .GET, uri: "/api/v1/installs")
        let response = handler.list(req)
        XCTAssertEqual(response.status, .ok)
        XCTAssertEqual(tracker.recentInstallsCallCount, 1)
        XCTAssertEqual(tracker.lastRecentInstallsLimit, 50, "Default limit should be 50 when query missing")
        let decoded = try? APITestSupport.decoder().decode([InstallRecord].self, from: response.body)
        XCTAssertEqual(decoded?.count, 3)
    }

    // MARK: - custom limit

    func test_list_acceptsCustomLimitFromQuery() async {
        let (handler, tracker) = makeHandler()
        await seedInstalls(in: tracker, count: 10)
        let req = APITestSupport.makeRequest(method: .GET, uri: "/api/v1/installs?limit=5")
        let response = handler.list(req)
        XCTAssertEqual(response.status, .ok)
        XCTAssertEqual(tracker.lastRecentInstallsLimit, 5)
        let decoded = try? APITestSupport.decoder().decode([InstallRecord].self, from: response.body)
        XCTAssertEqual(decoded?.count, 5, "Tracker should return exactly 5 records")
    }

    func test_list_invalidLimitFallsBackTo50() {
        let (handler, tracker) = makeHandler()
        let req = APITestSupport.makeRequest(method: .GET, uri: "/api/v1/installs?limit=not-a-number")
        let response = handler.list(req)
        XCTAssertEqual(response.status, .ok)
        XCTAssertEqual(tracker.lastRecentInstallsLimit, 50, "Invalid limit string should fall back to 50")
    }

    // MARK: - empty store

    func test_list_returnsEmptyArrayWhenNoRecords() {
        let (handler, _) = makeHandler()
        let req = APITestSupport.makeRequest(method: .GET, uri: "/api/v1/installs")
        let response = handler.list(req)
        XCTAssertEqual(response.status, .ok)
        let decoded = try? APITestSupport.decoder().decode([InstallRecord].self, from: response.body)
        XCTAssertEqual(decoded?.count, 0)
    }

    // MARK: - large limit

    func test_list_largeLimitReturnsAllAvailableRecords() async {
        let (handler, tracker) = makeHandler()
        await seedInstalls(in: tracker, count: 3)
        let req = APITestSupport.makeRequest(method: .GET, uri: "/api/v1/installs?limit=1000")
        let response = handler.list(req)
        XCTAssertEqual(response.status, .ok)
        let decoded = try? APITestSupport.decoder().decode([InstallRecord].self, from: response.body)
        XCTAssertEqual(decoded?.count, 3, "Large limit returns however many records exist")
    }

    // MARK: - delete single

    func test_delete_removesExistingRecord() async {
        let (handler, tracker) = makeHandler()
        await seedInstalls(in: tracker, count: 3)
        let targetID = tracker.records[1].id
        let req = APITestSupport.makeRequest(method: .DELETE, uri: "/api/v1/installs/\(targetID.uuidString)")
        let response = handler.delete(req, installID: targetID)
        XCTAssertEqual(response.status, .ok)
        XCTAssertEqual(tracker.deleteInstallCallCount, 1)
        XCTAssertEqual(tracker.lastDeletedInstallID, targetID)
        XCTAssertEqual(tracker.records.count, 2, "One record should have been removed")
    }

    func test_delete_returns404ForUnknownID() {
        let (handler, _) = makeHandler()
        let unknownID = UUID()
        let req = APITestSupport.makeRequest(method: .DELETE, uri: "/api/v1/installs/\(unknownID.uuidString)")
        let response = handler.delete(req, installID: unknownID)
        XCTAssertEqual(response.status, .notFound)
    }

    // MARK: - delete all

    func test_deleteAll_removesAllRecords() async {
        let (handler, tracker) = makeHandler()
        await seedInstalls(in: tracker, count: 5)
        let req = APITestSupport.makeRequest(method: .DELETE, uri: "/api/v1/installs")
        let response = handler.deleteAll(req)
        XCTAssertEqual(response.status, .ok)
        XCTAssertEqual(tracker.deleteAllInstallsCallCount, 1)
        XCTAssertTrue(tracker.records.isEmpty, "All records should have been removed")
    }

    func test_deleteAll_succeedsWhenAlreadyEmpty() {
        let (handler, tracker) = makeHandler()
        let req = APITestSupport.makeRequest(method: .DELETE, uri: "/api/v1/installs")
        let response = handler.deleteAll(req)
        XCTAssertEqual(response.status, .ok)
        XCTAssertEqual(tracker.deleteAllInstallsCallCount, 1)
    }
}
