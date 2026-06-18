// Tests for the Phase 6 (TKT-060) server endpoints that let the menu bar drive
// pairing, cert provisioning, and IPA import over the API after the process
// split: POST /api/v1/pair/pending, POST/GET /api/v1/tailscale/cert, and
// POST /api/v1/projects/:id/ipa.
@testable import RemoteDeploy
import XCTest
import Foundation
import NIOHTTP1
import RemoteDeployShared

@MainActor
final class Phase6EndpointsTests: XCTestCase {

    // MARK: - Router builder

    private func makeRouter(
        deviceStore: MockPairedDeviceStore = MockPairedDeviceStore(),
        projectStore: MockProjectStore = MockProjectStore(),
        certProvisioner: any CertProvisioning = NoopCertProvisioner(),
        serveDirectory: String = NSTemporaryDirectory() + "RemoteDeployTests-serve"
    ) -> APIRouter {
        let deps = APIRouterFactory.Dependencies(
            deviceStore: deviceStore,
            projectStore: projectStore,
            installTracker: MockInstallTracker(),
            schemeDetector: MockSchemeDetector(),
            statusProvider: MockStatusProvider(),
            buildTrigger: MockBuildTrigger(),
            buildStatus: MockBuildStatusProvider(),
            buildCanceler: MockBuildCanceler(),
            buildHistory: MockBuildHistoryProvider(),
            settingsProvider: MockSettingsProvider(),
            settingsUpdater: MockSettingsUpdater(),
            serverName: "TestMac",
            certProvisioner: certProvisioner,
            serveDirectory: serveDirectory
        )
        return APIRouterFactory.make(deps: deps).router
    }

    // MARK: - Pairing: mint pending token

    func test_mintPairingToken_returnsTokenAndIsClaimable() throws {
        let deviceStore = MockPairedDeviceStore()
        let router = makeRouter(deviceStore: deviceStore)
        let bearer = APITestSupport.pairDevice(in: deviceStore, name: "Menu bar (local)")

        let mintReq = APITestSupport.makeRequest(method: .POST, uri: "/api/v1/pair/pending", bearerToken: bearer)
        let mintResp = router.handle(mintReq)
        XCTAssertEqual(mintResp.status, .created)
        let pending = try APITestSupport.decoder().decode(PendingPairingResponse.self, from: mintResp.body)
        XCTAssertFalse(pending.token.isEmpty)
        XCTAssertEqual(pending.expiresInSeconds, 600)

        // The minted token must be claimable via the (unauthenticated) pair endpoint.
        let body = try APITestSupport.encoder().encode(PairRequest(token: pending.token, deviceName: "Browser"))
        let pairReq = APITestSupport.makeRequest(method: .POST, uri: "/api/v1/pair", body: body)
        let pairResp = router.handle(pairReq)
        XCTAssertEqual(pairResp.status, .created)
        XCTAssertTrue(deviceStore.devices.contains { $0.name == "Browser" })
    }

    func test_mintPairingToken_requiresAuth() {
        let router = makeRouter()
        let req = APITestSupport.makeRequest(method: .POST, uri: "/api/v1/pair/pending")
        XCTAssertEqual(router.handle(req).status, .unauthorized)
    }

    func test_mintPairingToken_rejectsWrongMethod() {
        let deviceStore = MockPairedDeviceStore()
        let router = makeRouter(deviceStore: deviceStore)
        let bearer = APITestSupport.pairDevice(in: deviceStore)
        let req = APITestSupport.makeRequest(method: .GET, uri: "/api/v1/pair/pending", bearerToken: bearer)
        XCTAssertEqual(router.handle(req).status, .methodNotAllowed)
    }

    // MARK: - Tailscale cert endpoint contract

    func test_provisionCertificate_returns202AndState() throws {
        let stub = StubCertProvisioner()
        stub.stateToReturn = CertProvisioningState(inProgress: true, certConfigured: false, lastError: nil)
        let deviceStore = MockPairedDeviceStore()
        let router = makeRouter(deviceStore: deviceStore, certProvisioner: stub)
        let bearer = APITestSupport.pairDevice(in: deviceStore)

        let resp = router.handle(APITestSupport.makeRequest(method: .POST, uri: "/api/v1/tailscale/cert", bearerToken: bearer))
        XCTAssertEqual(resp.status, .accepted)
        XCTAssertEqual(stub.provisionCallCount, 1)
        let state = try APITestSupport.decoder().decode(CertProvisioningState.self, from: resp.body)
        XCTAssertTrue(state.inProgress)
    }

    func test_certificateStatus_returnsState() throws {
        let stub = StubCertProvisioner()
        stub.stateToReturn = CertProvisioningState(inProgress: false, certConfigured: true, lastError: nil)
        let deviceStore = MockPairedDeviceStore()
        let router = makeRouter(deviceStore: deviceStore, certProvisioner: stub)
        let bearer = APITestSupport.pairDevice(in: deviceStore)

        let resp = router.handle(APITestSupport.makeRequest(method: .GET, uri: "/api/v1/tailscale/cert", bearerToken: bearer))
        XCTAssertEqual(resp.status, .ok)
        let state = try APITestSupport.decoder().decode(CertProvisioningState.self, from: resp.body)
        XCTAssertTrue(state.certConfigured)
        XCTAssertEqual(stub.provisionCallCount, 0)
    }

    func test_certEndpoint_rejectsWrongMethod() {
        let deviceStore = MockPairedDeviceStore()
        let router = makeRouter(deviceStore: deviceStore)
        let bearer = APITestSupport.pairDevice(in: deviceStore)
        let req = APITestSupport.makeRequest(method: .DELETE, uri: "/api/v1/tailscale/cert", bearerToken: bearer)
        XCTAssertEqual(router.handle(req).status, .methodNotAllowed)
    }

    // MARK: - TailscaleCertProvisioner logic

    func test_certProvisioner_writesCertPathsToSettings() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("rd-cert-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let certURL = tmp.appendingPathComponent("cert.pem")
        let keyURL = tmp.appendingPathComponent("key.pem")
        try Data("cert".utf8).write(to: certURL)
        try Data("key".utf8).write(to: keyURL)

        let settingsStore = SettingsStore(directory: tmp)
        var s = settingsStore.current(); s.hostname = "host.tail.ts.net"; settingsStore.update(s)

        let tailscale = MockTailscaleProvider()
        tailscale.generateCertificateResult = (certPath: certURL.path, keyPath: keyURL.path)
        let provisioner = TailscaleCertProvisioner(tailscaleProvider: tailscale, settingsStore: settingsStore, outputDir: tmp.path)

        let started = provisioner.provision()
        XCTAssertTrue(started.inProgress)
        try await waitUntil { !provisioner.state().inProgress }

        let final = provisioner.state()
        XCTAssertTrue(final.certConfigured)
        XCTAssertNil(final.lastError)
        XCTAssertEqual(settingsStore.current().certPath, certURL.path)
        XCTAssertEqual(settingsStore.current().keyPath, keyURL.path)
        XCTAssertEqual(tailscale.lastGenerateCertHostname, "host.tail.ts.net")
    }

    func test_certProvisioner_failsWithoutHostname() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("rd-cert-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let settingsStore = SettingsStore(directory: tmp) // default settings: empty hostname

        let provisioner = TailscaleCertProvisioner(
            tailscaleProvider: MockTailscaleProvider(),
            settingsStore: settingsStore,
            outputDir: tmp.path
        )
        _ = provisioner.provision()
        try await waitUntil { !provisioner.state().inProgress }

        let final = provisioner.state()
        XCTAssertNotNil(final.lastError)
        XCTAssertFalse(final.certConfigured)
    }

    // MARK: - IPA upload

    func test_uploadIPA_unknownProject_returns404() {
        let deviceStore = MockPairedDeviceStore()
        let router = makeRouter(deviceStore: deviceStore)
        let bearer = APITestSupport.pairDevice(in: deviceStore)
        let req = APITestSupport.makeRequest(
            method: .POST,
            uri: "/api/v1/projects/\(UUID().uuidString)/ipa",
            body: Data("x".utf8),
            bearerToken: bearer
        )
        XCTAssertEqual(router.handle(req).status, .notFound)
    }

    func test_uploadIPA_emptyBody_returns400() {
        let deviceStore = MockPairedDeviceStore()
        let projectStore = MockProjectStore()
        let project = APITestSupport.makeProject(name: "Demo")
        projectStore.projects = [project]
        let router = makeRouter(deviceStore: deviceStore, projectStore: projectStore)
        let bearer = APITestSupport.pairDevice(in: deviceStore)
        let req = APITestSupport.makeRequest(
            method: .POST,
            uri: "/api/v1/projects/\(project.id.uuidString)/ipa",
            body: Data(),
            bearerToken: bearer
        )
        XCTAssertEqual(router.handle(req).status, .badRequest)
    }

    func test_uploadIPA_validIPA_copiesToServeDirAndReturnsMetadata() throws {
        let deviceStore = MockPairedDeviceStore()
        let projectStore = MockProjectStore()
        let project = APITestSupport.makeProject(name: "Demo")
        projectStore.projects = [project]
        let serveDir = FileManager.default.temporaryDirectory.appendingPathComponent("rd-serve-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: serveDir) }

        let router = makeRouter(deviceStore: deviceStore, projectStore: projectStore, serveDirectory: serveDir.path)
        let bearer = APITestSupport.pairDevice(in: deviceStore)

        let ipaData = try Self.makeMinimalIPA(bundleID: "com.example.Demo", version: "1.2.3", build: "42")
        let req = APITestSupport.makeRequest(
            method: .POST,
            uri: "/api/v1/projects/\(project.id.uuidString)/ipa?filename=Demo.ipa",
            body: ipaData,
            bearerToken: bearer
        )
        let resp = router.handle(req)
        XCTAssertEqual(resp.status, .created, String(data: resp.body, encoding: .utf8) ?? "")
        let info = try APITestSupport.decoder().decode(IPAUploadResponse.self, from: resp.body)
        XCTAssertEqual(info.bundleID, "com.example.Demo")
        XCTAssertEqual(info.version, "1.2.3")
        XCTAssertEqual(info.buildNumber, "42")
        XCTAssertEqual(info.slug, project.urlSlug)

        let served = serveDir.appendingPathComponent(project.urlSlug).appendingPathComponent("Demo.ipa")
        XCTAssertTrue(FileManager.default.fileExists(atPath: served.path))
    }

    // MARK: - Helpers

    /// Polls `condition` until it returns true or the timeout elapses.
    private func waitUntil(timeout: TimeInterval = 3, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { XCTFail("Timed out waiting for condition"); return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// Builds a minimal valid .ipa (a zip containing Payload/Demo.app/Info.plist)
    /// in memory so the upload happy path exercises real IPAImporter parsing.
    private static func makeMinimalIPA(bundleID: String, version: String, build: String) throws -> Data {
        let fm = FileManager.default
        let stage = fm.temporaryDirectory.appendingPathComponent("rd-ipa-\(UUID().uuidString)")
        let appDir = stage.appendingPathComponent("Payload/Demo.app")
        try fm.createDirectory(at: appDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: stage) }

        let info: [String: Any] = [
            "CFBundleIdentifier": bundleID,
            "CFBundleShortVersionString": version,
            "CFBundleVersion": build,
            "CFBundleName": "Demo"
        ]
        let plistData = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try plistData.write(to: appDir.appendingPathComponent("Info.plist"))

        let ipaURL = fm.temporaryDirectory.appendingPathComponent("rd-\(UUID().uuidString).ipa")
        defer { try? fm.removeItem(at: ipaURL) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        // --keepParent keeps "Payload" as the archive's top-level entry.
        process.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent",
                             stage.appendingPathComponent("Payload").path, ipaURL.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "Phase6EndpointsTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "ditto failed to build IPA fixture"])
        }
        return try Data(contentsOf: ipaURL)
    }
}

/// Deterministic CertProvisioning stub for endpoint-contract tests.
final class StubCertProvisioner: CertProvisioning, @unchecked Sendable {
    var provisionCallCount = 0
    var stateToReturn = CertProvisioningState(inProgress: false, certConfigured: false, lastError: nil)

    func provision() -> CertProvisioningState {
        provisionCallCount += 1
        return stateToReturn
    }

    func state() -> CertProvisioningState {
        stateToReturn
    }
}
