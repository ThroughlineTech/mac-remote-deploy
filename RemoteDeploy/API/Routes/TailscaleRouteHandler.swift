// Handles Tailscale certificate provisioning endpoints. TKT-060 (Phase 6):
// POST /api/v1/tailscale/cert starts `tailscale cert` in the background and
// GET /api/v1/tailscale/cert reports progress, so the menu bar setup wizard
// can drive cert generation over the API after the process split instead of
// running the CLI in-process.
import Foundation
import RemoteDeployShared

/// Routes Tailscale cert provisioning requests to the CertProvisioning seam.
final class TailscaleRouteHandler: @unchecked Sendable {

    private let certProvisioner: any CertProvisioning

    init(certProvisioner: any CertProvisioning) {
        self.certProvisioner = certProvisioner
    }

    /// POST /api/v1/tailscale/cert — start provisioning (no-op if already running).
    func provisionCertificate(_ request: APIRequest) -> APIResponse {
        let state = certProvisioner.provision()
        return .json(state, status: .accepted)
    }

    /// GET /api/v1/tailscale/cert — report the current provisioning state.
    func certificateStatus(_ request: APIRequest) -> APIResponse {
        .json(certProvisioner.state())
    }
}
