// Handles the GET /api/v1/status endpoint.
// Returns a snapshot of the server's current state including Tailscale
// connection, build status, and server port.
import Foundation
import RemoteDeployShared

/// Provides server status information to companion devices.
final class StatusRouteHandler: @unchecked Sendable {

    /// Closure that returns the current server status snapshot.
    /// This avoids coupling the handler directly to AppState.
    private let statusProvider: @Sendable () -> ServerStatus

    /// Creates a new status route handler.
    ///
    /// - Parameter statusProvider: A closure that returns the current server status.
    init(statusProvider: @escaping @Sendable () -> ServerStatus) {
        self.statusProvider = statusProvider
    }

    /// GET /api/v1/status — Returns server and build status.
    func getStatus(_ request: APIRequest) -> APIResponse {
        let status = statusProvider()
        return .json(status)
    }
}
