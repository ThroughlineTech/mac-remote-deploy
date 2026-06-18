import XCTest
@testable import RemoteDeployServer

final class InstallTrackerTests: XCTestCase {

    private var tempDirectory: URL!
    private var sut: ServerInstallTracker!

    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("InstallTrackerTests-\(UUID().uuidString)")
        sut = ServerInstallTracker(directory: tempDirectory)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDirectory)
        sut = nil
        tempDirectory = nil
        super.tearDown()
    }

    // MARK: - Recording and Retrieving

    func testRecordInstallAndRetrieve() async {
        await sut.recordInstall(
            projectName: "MyApp",
            sourceIP: "192.168.1.10",
            userAgent: "iPhone/15.0"
        )

        let records = await sut.recentInstalls(limit: 10)

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.projectName, "MyApp")
        XCTAssertEqual(records.first?.sourceIP, "192.168.1.10")
        XCTAssertEqual(records.first?.userAgent, "iPhone/15.0")
    }

    func testRecordMultipleInstalls() async {
        await sut.recordInstall(projectName: "App1", sourceIP: "10.0.0.1", userAgent: "UA1")
        await sut.recordInstall(projectName: "App2", sourceIP: "10.0.0.2", userAgent: "UA2")
        await sut.recordInstall(projectName: "App3", sourceIP: "10.0.0.3", userAgent: "UA3")

        let records = await sut.recentInstalls(limit: 10)

        XCTAssertEqual(records.count, 3)
    }

    func testRecentInstallsReturnedNewestFirst() async {
        await sut.recordInstall(projectName: "First", sourceIP: "1.1.1.1", userAgent: "UA")
        // Use longer delays to guarantee different timestamps
        try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
        await sut.recordInstall(projectName: "Second", sourceIP: "2.2.2.2", userAgent: "UA")
        try? await Task.sleep(nanoseconds: 100_000_000)
        await sut.recordInstall(projectName: "Third", sourceIP: "3.3.3.3", userAgent: "UA")

        let records = await sut.recentInstalls(limit: 10)

        XCTAssertEqual(records.first?.projectName, "Third", "Most recent install should be first")
        XCTAssertEqual(records.last?.projectName, "First", "Oldest install should be last")
    }

    // MARK: - Limit Parameter

    func testLimitParameterRestrictsResults() async {
        for i in 0..<5 {
            await sut.recordInstall(projectName: "App\(i)", sourceIP: "10.0.0.\(i)", userAgent: "UA")
        }

        let records = await sut.recentInstalls(limit: 3)

        XCTAssertEqual(records.count, 3, "Should return at most 'limit' records")
    }

    func testLimitLargerThanRecordCountReturnsAll() async {
        await sut.recordInstall(projectName: "App1", sourceIP: "1.1.1.1", userAgent: "UA")
        await sut.recordInstall(projectName: "App2", sourceIP: "2.2.2.2", userAgent: "UA")

        let records = await sut.recentInstalls(limit: 100)

        XCTAssertEqual(records.count, 2, "Should return all records when limit exceeds count")
    }

    func testLimitOfZeroReturnsEmpty() async {
        await sut.recordInstall(projectName: "App", sourceIP: "1.1.1.1", userAgent: "UA")

        let records = await sut.recentInstalls(limit: 0)

        XCTAssertTrue(records.isEmpty, "Limit of 0 should return empty array")
    }

    // MARK: - Max Records Trimming

    func testTrimsToMaxRecordsWhenExceeded() async {
        // Record 1005 installs (exceeds 1000 max)
        for i in 0..<1005 {
            await sut.recordInstall(projectName: "App\(i)", sourceIP: "10.0.0.1", userAgent: "UA")
        }

        let records = await sut.recentInstalls(limit: 2000)

        XCTAssertEqual(records.count, 1000, "Should trim to 1000 records max")
    }

    func testTrimmingKeepsNewestRecords() async {
        // Record 1002 installs
        for i in 0..<1002 {
            await sut.recordInstall(projectName: "App\(i)", sourceIP: "10.0.0.1", userAgent: "UA")
        }

        let records = await sut.recentInstalls(limit: 2000)

        // The first 2 records (App0, App1) should have been trimmed
        let projectNames = Set(records.map { $0.projectName })
        XCTAssertFalse(projectNames.contains("App0"), "Oldest records should be trimmed")
        XCTAssertFalse(projectNames.contains("App1"), "Oldest records should be trimmed")
        XCTAssertTrue(projectNames.contains("App1001"), "Newest records should be kept")
    }

    // MARK: - Empty State

    func testRecentInstallsReturnsEmptyWhenNoRecords() async {
        let records = await sut.recentInstalls(limit: 10)

        XCTAssertTrue(records.isEmpty, "Should return empty array when no installs recorded")
    }

    // MARK: - Persistence

    func testRecordsPersistedToDisk() async {
        await sut.recordInstall(projectName: "PersistApp", sourceIP: "5.5.5.5", userAgent: "TestAgent")

        // Create a new tracker pointing to the same directory
        let newTracker = ServerInstallTracker(directory: tempDirectory)
        let records = await newTracker.recentInstalls(limit: 10)

        XCTAssertEqual(records.count, 1, "Records should persist across tracker instances")
        XCTAssertEqual(records.first?.projectName, "PersistApp")
    }

    // MARK: - Unique IDs

    func testEachRecordGetsUniqueID() async {
        await sut.recordInstall(projectName: "App", sourceIP: "1.1.1.1", userAgent: "UA")
        await sut.recordInstall(projectName: "App", sourceIP: "1.1.1.1", userAgent: "UA")

        let records = await sut.recentInstalls(limit: 10)

        XCTAssertEqual(records.count, 2)
        XCTAssertNotEqual(records[0].id, records[1].id, "Each record should have a unique ID")
    }

    // MARK: - Delete Single

    func testDeleteInstallRemovesCorrectRecord() async {
        await sut.recordInstall(projectName: "Keep1", sourceIP: "1.1.1.1", userAgent: "UA")
        await sut.recordInstall(projectName: "Remove", sourceIP: "2.2.2.2", userAgent: "UA")
        await sut.recordInstall(projectName: "Keep2", sourceIP: "3.3.3.3", userAgent: "UA")

        let allRecords = await sut.recentInstalls(limit: 10)
        let targetID = allRecords.first { $0.projectName == "Remove" }!.id

        let result = await sut.deleteInstall(id: targetID)

        XCTAssertTrue(result, "Should return true when record exists")
        let remaining = await sut.recentInstalls(limit: 10)
        XCTAssertEqual(remaining.count, 2)
        XCTAssertFalse(remaining.contains { $0.id == targetID }, "Deleted record should not be present")
    }

    func testDeleteInstallReturnsFalseForUnknownID() async {
        await sut.recordInstall(projectName: "App", sourceIP: "1.1.1.1", userAgent: "UA")

        let result = await sut.deleteInstall(id: UUID())

        XCTAssertFalse(result, "Should return false when no record matches")
        let records = await sut.recentInstalls(limit: 10)
        XCTAssertEqual(records.count, 1, "No records should be removed")
    }

    func testDeleteInstallPersistsToDisk() async {
        await sut.recordInstall(projectName: "App", sourceIP: "1.1.1.1", userAgent: "UA")
        let records = await sut.recentInstalls(limit: 10)
        let targetID = records[0].id

        let deleted = await sut.deleteInstall(id: targetID)
        XCTAssertTrue(deleted)

        // Create a new tracker pointing to the same directory to verify persistence
        let newTracker = ServerInstallTracker(directory: tempDirectory)
        let remaining = await newTracker.recentInstalls(limit: 10)
        XCTAssertTrue(remaining.isEmpty, "Deletion should persist across tracker instances")
    }

    // MARK: - Delete All

    func testDeleteAllInstallsEmptiesTheStore() async {
        await sut.recordInstall(projectName: "App1", sourceIP: "1.1.1.1", userAgent: "UA")
        await sut.recordInstall(projectName: "App2", sourceIP: "2.2.2.2", userAgent: "UA")
        await sut.recordInstall(projectName: "App3", sourceIP: "3.3.3.3", userAgent: "UA")

        await sut.deleteAllInstalls()

        let records = await sut.recentInstalls(limit: 10)
        XCTAssertTrue(records.isEmpty, "All records should be deleted")
    }

    func testDeleteAllInstallsPersistsToDisk() async {
        await sut.recordInstall(projectName: "App", sourceIP: "1.1.1.1", userAgent: "UA")

        await sut.deleteAllInstalls()

        let newTracker = ServerInstallTracker(directory: tempDirectory)
        let records = await newTracker.recentInstalls(limit: 10)
        XCTAssertTrue(records.isEmpty, "Delete-all should persist across tracker instances")
    }

    func testDeleteAllInstallsOnEmptyStoreSucceeds() async {
        await sut.deleteAllInstalls()

        let records = await sut.recentInstalls(limit: 10)
        XCTAssertTrue(records.isEmpty, "Delete-all on empty store should not error")
    }
}
