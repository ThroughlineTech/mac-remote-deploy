// Verifies the renewal decision wired up in TKT-071. The capability
// (`needsRenewal` + `provision()`) already existed but had no caller, so the
// 90-day Tailscale cert silently expired and companions could not pair. These
// tests pin the missing link: renew exactly when (and only when) the cert is due.
@testable import RemoteDeployServer
import XCTest
import Foundation
import RemoteDeployShared

final class CertRenewalCoordinatorTests: XCTestCase {

    /// Stub cert provider with a configurable `needsRenewal` outcome.
    private final class StubCertificateProvider: CertificateProviding, @unchecked Sendable {
        var needsRenewalResult = false
        var errorToThrow: Error?
        private(set) var needsRenewalCalledWith: [String] = []

        func loadCertificate(certPath: String, keyPath: String) throws -> (cert: String, key: String) {
            ("", "")
        }
        func certificateExpiryDate(certPath: String) throws -> Date { .distantFuture }
        func needsRenewal(certPath: String) throws -> Bool {
            needsRenewalCalledWith.append(certPath)
            if let errorToThrow { throw errorToThrow }
            return needsRenewalResult
        }
    }

    /// Spy provisioner that records whether `provision()` was called.
    private final class SpyCertProvisioner: CertProvisioning, @unchecked Sendable {
        private(set) var provisionCallCount = 0
        func provision() -> CertProvisioningState {
            provisionCallCount += 1
            return CertProvisioningState(inProgress: true, certConfigured: false, lastError: nil)
        }
        func state() -> CertProvisioningState {
            CertProvisioningState(inProgress: false, certConfigured: false, lastError: nil)
        }
    }

    func test_renewsWhenCertIsDue() {
        let provider = StubCertificateProvider()
        provider.needsRenewalResult = true
        let spy = SpyCertProvisioner()
        let coordinator = CertRenewalCoordinator(certificateProvider: provider, provisioner: spy)

        let triggered = coordinator.renewIfNeeded(certPath: "/tmp/cert.crt")

        XCTAssertTrue(triggered)
        XCTAssertEqual(spy.provisionCallCount, 1)
        XCTAssertEqual(provider.needsRenewalCalledWith, ["/tmp/cert.crt"])
    }

    func test_doesNotRenewWhenCertStillValid() {
        let provider = StubCertificateProvider()
        provider.needsRenewalResult = false
        let spy = SpyCertProvisioner()
        let coordinator = CertRenewalCoordinator(certificateProvider: provider, provisioner: spy)

        let triggered = coordinator.renewIfNeeded(certPath: "/tmp/cert.crt")

        XCTAssertFalse(triggered)
        XCTAssertEqual(spy.provisionCallCount, 0)
    }

    func test_doesNotRenewWhenCertPathEmpty() {
        let provider = StubCertificateProvider()
        provider.needsRenewalResult = true
        let spy = SpyCertProvisioner()
        let coordinator = CertRenewalCoordinator(certificateProvider: provider, provisioner: spy)

        let triggered = coordinator.renewIfNeeded(certPath: "")

        XCTAssertFalse(triggered)
        XCTAssertEqual(spy.provisionCallCount, 0)
        XCTAssertTrue(provider.needsRenewalCalledWith.isEmpty, "Empty path must short-circuit before touching the provider")
    }

    func test_doesNotRenewWhenCheckThrows() {
        let provider = StubCertificateProvider()
        provider.errorToThrow = CertificateError.fileNotFound("/tmp/cert.crt")
        let spy = SpyCertProvisioner()
        let coordinator = CertRenewalCoordinator(certificateProvider: provider, provisioner: spy)

        let triggered = coordinator.renewIfNeeded(certPath: "/tmp/cert.crt")

        XCTAssertFalse(triggered, "A read/parse failure must not trigger provisioning")
        XCTAssertEqual(spy.provisionCallCount, 0)
    }
}
