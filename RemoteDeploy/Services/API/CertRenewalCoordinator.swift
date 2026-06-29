// Decides whether the server's configured TLS certificate needs renewing and, if
// so, kicks off re-provisioning. TKT-071.
//
// The renewal *capability* already existed -- `CertificateProviding.needsRenewal`
// and `CertProvisioning.provision()` -- but nothing ever connected them, so the
// 90-day Tailscale Let's Encrypt cert silently expired and the iOS companion
// (which does strict system-trust TLS validation) could no longer pair. This
// coordinator is the missing link; it is a plain value type so the decision is
// unit-testable with mock provider/provisioner, separate from `ServerLifecycle`'s
// timer plumbing.
import Foundation
import os

struct CertRenewalCoordinator {

    private let certificateProvider: any CertificateProviding
    private let provisioner: any CertProvisioning

    init(certificateProvider: any CertificateProviding, provisioner: any CertProvisioning) {
        self.certificateProvider = certificateProvider
        self.provisioner = provisioner
    }

    /// Checks the certificate at `certPath` and, if it is expired or within the
    /// provider's renewal window, asks the provisioner to mint a fresh one.
    ///
    /// Provisioning runs in the background (the provisioner writes the new cert and
    /// updates the settings store, which `ServerLifecycle` observes to reload
    /// HTTPS), so this returns as soon as the decision is made.
    ///
    /// - Parameter certPath: Absolute path to the configured cert PEM. Empty when
    ///   no cert has been provisioned yet.
    /// - Returns: `true` if renewal was triggered; `false` if the cert is still
    ///   valid, unconfigured, or could not be read.
    @discardableResult
    func renewIfNeeded(certPath: String) -> Bool {
        guard !certPath.isEmpty else { return false }

        let needsRenewal: Bool
        do {
            needsRenewal = try certificateProvider.needsRenewal(certPath: certPath)
        } catch {
            // A read/parse failure must not wedge the server; log and let the next
            // tick retry. (An expired cert parses fine and returns true, so this
            // path is genuinely "couldn't read it," not "it's expired.")
            Logger.server.error("Cert renewal check failed: \(error.localizedDescription, privacy: .public)")
            return false
        }

        guard needsRenewal else { return false }

        Logger.server.info("TLS cert is expired or near expiry; provisioning a fresh Tailscale cert")
        _ = provisioner.provision()
        return true
    }
}
