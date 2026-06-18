// Tests for SettingsStore, the thread-safe single source of truth for settings.
// TKT-055 (Phase 2).
import XCTest
@testable import RemoteDeployServer
import RemoteDeployShared

final class SettingsStoreTests: XCTestCase {

    private var tempDirectory: URL!

    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SettingsStoreTests-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDirectory)
        tempDirectory = nil
        super.tearDown()
    }

    func testDefaultsWhenNoFileExists() {
        let store = SettingsStore(directory: tempDirectory)
        XCTAssertEqual(store.current().serverPort, 8443)
        XCTAssertEqual(store.current().hostname, "")
        XCTAssertEqual(store.current().certPath, "")
    }

    func testUpdateIsImmediatelyReadable() {
        let store = SettingsStore(directory: tempDirectory)
        store.update(SettingsData(serverPort: 9443, hostname: "mac.ts.net", certPath: "", keyPath: ""))
        XCTAssertEqual(store.current().serverPort, 9443)
        XCTAssertEqual(store.current().hostname, "mac.ts.net")
    }

    func testDataPersistsAcrossInstances() {
        let store = SettingsStore(directory: tempDirectory)
        store.update(SettingsData(serverPort: 7000, hostname: "host", certPath: "", keyPath: ""))

        let reopened = SettingsStore(directory: tempDirectory)
        XCTAssertEqual(reopened.current().serverPort, 7000)
        XCTAssertEqual(reopened.current().hostname, "host")
    }

    func testUpdatePostsSettingsDidChange() {
        let store = SettingsStore(directory: tempDirectory)
        let expectation = XCTNSNotificationExpectation(name: .settingsDidChange, object: nil)
        store.update(SettingsData(serverPort: 8443, hostname: "", certPath: "", keyPath: ""))
        wait(for: [expectation], timeout: 1.0)
    }

    func testConformsToSettingsProviding() {
        let store = SettingsStore(directory: tempDirectory)
        store.update(SettingsData(serverPort: 8080, hostname: "x", certPath: "", keyPath: ""))
        let provider: any SettingsProviding = store
        XCTAssertEqual(provider.currentSettings().serverPort, 8080)
        XCTAssertEqual(provider.currentSettings().hostname, "x")
    }
}
