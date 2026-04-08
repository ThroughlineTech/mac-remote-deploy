// Unit tests for JSONBuildHistoryStore (TKT-008 cleanup via TKT-024).
// Exercises the on-disk JSON store in an isolated temp directory.
@testable import RemoteDeploy
import XCTest
import Foundation
import RemoteDeployShared

final class JSONBuildHistoryStoreTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("JSONBuildHistoryStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        tempDir = nil
        try super.tearDownWithError()
    }

    // Helper to build a BuildResult with a given start time for ordering assertions.
    private func makeResult(success: Bool = true, startTime: Date = Date()) -> BuildResult {
        BuildResult(
            projectID: UUID(),
            success: success,
            ipaPath: success ? "/tmp/app.ipa" : nil,
            errorSummary: success ? nil : "boom",
            buildLog: "log output",
            startTime: startTime,
            endTime: startTime.addingTimeInterval(5),
            version: "1.0.0",
            buildNumber: "1"
        )
    }

    // MARK: - Append + load round trip

    func test_append_thenLoad_roundTrips() {
        let store = JSONBuildHistoryStore(directory: tempDir)
        let result = makeResult()

        store.append(result)

        // New store instance forces a read from disk (bypasses in-memory cache).
        let freshStore = JSONBuildHistoryStore(directory: tempDir)
        let loaded = freshStore.recentBuilds()

        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.id, result.id)
        XCTAssertEqual(loaded.first?.success, true)
    }

    // MARK: - Cap / trim

    func test_append_trimsToMaxRecords() {
        let store = JSONBuildHistoryStore(directory: tempDir)

        // Append 105 results — store is capped at 100.
        for i in 0..<105 {
            store.append(makeResult(startTime: Date(timeIntervalSince1970: TimeInterval(i))))
        }

        let records = JSONBuildHistoryStore(directory: tempDir).recentBuilds()
        XCTAssertEqual(records.count, 100)
    }

    // MARK: - Load with missing file

    func test_load_missingFile_returnsEmpty() {
        // Fresh tempDir has no build-history.json.
        let store = JSONBuildHistoryStore(directory: tempDir)
        XCTAssertTrue(store.recentBuilds().isEmpty)
    }

    // MARK: - Load with corrupt file

    func test_load_corruptFile_returnsEmpty() throws {
        let fileURL = tempDir.appendingPathComponent("build-history.json")
        try Data("this is not valid json".utf8).write(to: fileURL)

        let store = JSONBuildHistoryStore(directory: tempDir)
        XCTAssertTrue(store.recentBuilds().isEmpty)
    }

    // MARK: - Query-style: recentBuilds returns newest first

    func test_recentBuilds_returnsNewestFirst() {
        let store = JSONBuildHistoryStore(directory: tempDir)

        let oldest = makeResult(startTime: Date(timeIntervalSince1970: 1000))
        let middle = makeResult(startTime: Date(timeIntervalSince1970: 2000))
        let newest = makeResult(startTime: Date(timeIntervalSince1970: 3000))

        store.append(oldest)
        store.append(middle)
        store.append(newest)

        let records = JSONBuildHistoryStore(directory: tempDir).recentBuilds()
        XCTAssertEqual(records.count, 3)
        // JSONBuildHistoryStore.append inserts at index 0, so the most recently
        // appended record is first.
        XCTAssertEqual(records[0].id, newest.id)
        XCTAssertEqual(records[1].id, middle.id)
        XCTAssertEqual(records[2].id, oldest.id)
    }
}
