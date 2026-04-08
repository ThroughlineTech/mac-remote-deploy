// Protocol for providing the current ServerStatus snapshot to API consumers.
// Decouples StatusRouteHandler from AppState, AppStateBridge, and the deploy server.
import Foundation
import RemoteDeployShared

protocol StatusProviding: Sendable {

    /// Returns a snapshot of the current server status.
    ///
    /// - Returns: A fully populated `ServerStatus` reflecting live server, Tailscale,
    ///   and build state at the moment of the call.
    func currentStatus() -> ServerStatus
}
