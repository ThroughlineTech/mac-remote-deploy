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

    // MARK: - Bundle ID scope note (TKT-009 / TKT-024)

    /// Regression note — the original TKT-009 acceptance criterion said
    /// `DeferredSettingsUpdater.updateSettings(_:)` should reject malformed
    /// bundle IDs. But `SettingsData` has no `bundleID` field: bundle ID is a
    /// **per-project** value on `ProjectConfig`, and its programmatic entry
    /// point is `ProjectsRouteHandler.create` / `.update`. TKT-024 Commit 5
    /// rescoped the fix there and added a shared `BundleIDValidator` in
    /// `RemoteDeployShared` used by both the UI and the REST boundary.
    ///
    /// This test is deliberately trivial — it asserts that `SettingsData`'s
    /// public surface does not contain a bundle ID, so anyone reading the
    /// DeferredSettingsUpdater tests and looking for bundle-ID coverage gets
    /// pointed at the right place (`ProjectsRouteHandlerTests`).
    func test_settingsData_hasNoBundleIDSurface_regressionOnly() {
        let settings = SettingsData(serverPort: 8443, hostname: "host", certPath: "", keyPath: "")
        let mirror = Mirror(reflecting: settings)
        let propertyNames = mirror.children.compactMap { $0.label }
        XCTAssertFalse(
            propertyNames.contains(where: { $0.localizedCaseInsensitiveContains("bundle") }),
            """
            SettingsData intentionally has no bundle-ID field. If you're here \
            to add bundle-ID validation to settings updates, see \
            ProjectsRouteHandlerTests.test_create_rejectsMalformedBundleID — \
            TKT-024 Commit 5 rescoped TKT-009's AC there.
            """
        )
    }

    // MARK: - Apply through the settings store (TKT-055)

    /// On success the updater writes the validated settings through the
    /// SettingsStore (the single source of truth), so a subsequent read reflects
    /// them. Replaces the pre-TKT-055 applyOnMain/AppStateBridge callback test.
    func test_update_persistsThroughSettingsStoreOnSuccess() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeferredSettingsUpdaterTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = SettingsStore(directory: tempDir)
        let updater = DeferredSettingsUpdater(settingsStore: store)

        let settings = SettingsData(serverPort: 9443, hostname: "mac.tailnet.ts.net", certPath: "", keyPath: "")
        let err = updater.updateSettings(settings)

        XCTAssertNil(err)
        XCTAssertEqual(store.current().serverPort, 9443)
        XCTAssertEqual(store.current().hostname, "mac.tailnet.ts.net")
    }

    /// A validation failure must NOT touch the store.
    func test_update_doesNotPersistWhenValidationFails() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeferredSettingsUpdaterTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = SettingsStore(directory: tempDir)
        let original = store.current().serverPort
        let updater = DeferredSettingsUpdater(settingsStore: store)

        let err = updater.updateSettings(SettingsData(serverPort: 80, hostname: "", certPath: "", keyPath: ""))

        XCTAssertNotNil(err)
        XCTAssertEqual(store.current().serverPort, original, "Store must be untouched on validation failure")
    }
}
