// Server-side Tailscale TLS certificate provisioning seam. TKT-060 (Phase 6):
// the server owns `tailscale cert` (it binds HTTPS with the result), so clients
// (the menu bar setup wizard, after the process split) ask the server to
// provision a cert rather than running the CLI in-process. Work runs in the
// background; callers poll `state()` for completion.
import Foundation
import RemoteDeployShared

/// Provisions a Tailscale HTTPS certificate for the server's hostname.
protocol CertProvisioning: Sendable {
    /// Starts provisioning if idle; a no-op if already running. Returns the
    /// current state (so the POST handler can echo it).
    func provision() -> CertProvisioningState

    /// Returns the current provisioning state.
    func state() -> CertProvisioningState
}

/// Inert provisioner used as the `APIRouterFactory.Dependencies` default and by
/// tests that don't exercise cert provisioning. Reports an idle, unconfigured
/// state and never runs the CLI.
struct NoopCertProvisioner: CertProvisioning {
    func provision() -> CertProvisioningState {
        CertProvisioningState(inProgress: false, certConfigured: false, lastError: nil)
    }

    func state() -> CertProvisioningState {
        CertProvisioningState(inProgress: false, certConfigured: false, lastError: nil)
    }
}
