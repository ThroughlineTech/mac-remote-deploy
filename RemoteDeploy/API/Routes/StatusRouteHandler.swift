// Handles the GET /api/v1/status endpoint.
// Returns a snapshot of the server's current state including Tailscale
// connection, build status, and server port.
import Foundation
import RemoteDeployShared

/// Provides server status information to companion devices.
final class StatusRouteHandler: @unchecked Sendable {

    private let statusProvider: any StatusProviding

    /// Creates a new status route handler.
    ///
    /// - Parameter statusProvider: Source of the current server status snapshot.
    init(statusProvider: any StatusProviding) {
        self.statusProvider = statusProvider
    }

    /// GET /api/v1/status — Returns server and build status.
    func getStatus(_ request: APIRequest) -> APIResponse {
        let status = statusProvider.currentStatus()
        return .json(status)
    }
}
