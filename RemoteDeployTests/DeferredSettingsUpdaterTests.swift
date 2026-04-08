// Tests for the real DeferredSettingsUpdater from TKT-009. Covers port
// validation, cert/key path validation, and the happy path through the
// applyOnMain callback.
@testable import RemoteDeploy
import XCTest
import Foundation
import RemoteDeployShared

final class DeferredSettingsUpdaterTests: XCTestCase {

    // MARK: - Port validation

    func test_update_rejectsPortBelow1024() {
        let updater = DeferredSettingsUpdater.noop()
        let settings = SettingsData(serverPort: 80, hostname: "", certPath: "", keyPath: "")
        let err = updater.updateSettings(settings)
        XCTAssertNotNil(err)
        XCTAssertTrue(err?.contains("out of range") ?? false)
    }

    func test_update_rejectsPortAbove65535() {
        let updater = DeferredSettingsUpdater.noop()
        let settings = SettingsData(serverPort: 99999, hostname: "", certPath: "", keyPath: "")
        let err = updater.updateSettings(settings)
        XCTAssertNotNil(err)
        XCTAssertTrue(err?.contains("out of range") ?? false)
    }

    func test_update_acceptsValidPort() {
        let updater = DeferredSettingsUpdater.noop()
        let settings = SettingsData(serverPort: 8443, hostname: "", certPath: "", keyPath: "")
        XCTAssertNil(updater.updateSettings(settings))
    }

    // MARK: - Cert/key path validation

    func test_update_rejectsMissingCertPath() {
        let updater = DeferredSettingsUpdater.noop()
        let settings = SettingsData(serverPort: 8443, hostname: "", certPath: "/nonexistent/cert.pem", keyPath: "")
        let err = updater.updateSettings(settings)
        XCTAssertNotNil(err)
        XCTAssertTrue(err?.contains("Certificate file not found") ?? false)
    }

    func test_update_rejectsMissingKeyPath() {
        let updater = DeferredSettingsUpdater.noop()
        let settings = SettingsData(serverPort: 8443, hostname: "", certPath: "", keyPath: "/nonexistent/key.pem")
        let err = updater.updateSettings(settings)
        XCTAssertNotNil(err)
        XCTAssertTrue(err?.contains("Key file not found") ?? false)
    }

    func test_update_acceptsEmptyCertAndKey() {
        // Empty paths mean "not configured yet" — should validate cleanly.
        let updater = DeferredSettingsUpdater.noop()
        let settings = SettingsData(serverPort: 8443, hostname: "", certPath: "", keyPath: "")
        XCTAssertNil(updater.updateSettings(settings))
    }

    func test_update_acceptsExistingCertAndKey() throws {
        // Create temp files and verify the updater accepts them.
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeferredSettingsUpdaterTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let certURL = tempDir.appendingPathComponent("cert.pem")
        let keyURL = tempDir.appendingPathComponent("key.pem")
        try Data("fake cert".utf8).write(to: certURL)
        try Data("fake key".utf8).write(to: keyURL)

        let updater = DeferredSettingsUpdater.noop()
        let settings = SettingsData(
            serverPort: 8443,
            hostname: "test.tailnet.ts.net",
            certPath: certURL.path,
            keyPath: keyURL.path
        )
        XCTAssertNil(updater.updateSettings(settings))
    }

    // MARK: - Apply callback

    @MainActor
    func test_update_invokesApplyOnMainCallbackOnSuccess() async {
        // Use the full init to exercise the apply path.
        // Need an AppStateBridge — construct via AppState.
        let appState = AppState()
        let buildManager = BuildManager()
        let bridge = AppStateBridge(appState: appState, buildManager: buildManager)

        let expectation = XCTestExpectation(description: "applyOnMain invoked")
        let updater = DeferredSettingsUpdater(bridge: bridge) { _ in
            expectation.fulfill()
        }

        let settings = SettingsData(serverPort: 8443, hostname: "host", certPath: "", keyPath: "")
        let err = updater.updateSettings(settings)
        XCTAssertNil(err)
        await fulfillment(of: [expectation], timeout: 1.0)
    }
}
