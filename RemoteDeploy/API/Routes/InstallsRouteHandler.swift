// Handles the GET /api/v1/installs endpoint.
// Returns recent IPA download records from the install tracker.
import Foundation
import RemoteDeployShared

/// Provides install history to companion devices.
final class InstallsRouteHandler: @unchecked Sendable {

    private let installTracker: InstallTracking

    /// Creates a new installs route handler.
    ///
    /// - Parameter installTracker: The tracker that records IPA downloads.
    init(installTracker: InstallTracking) {
        self.installTracker = installTracker
    }

    /// GET /api/v1/installs — List recent installs.
    func list(_ request: APIRequest) -> APIResponse {
        // This needs to be async, but our router is sync.
        // Use a semaphore to bridge async -> sync (acceptable for a low-traffic local API).
        let semaphore = DispatchSemaphore(value: 0)
        var records: [InstallRecord] = []

        let limit = Int(request.queryParameters["limit"] ?? "50") ?? 50

        Task {
            records = await installTracker.recentInstalls(limit: limit)
            semaphore.signal()
        }
        semaphore.wait()

        return .json(records)
    }

    /// DELETE /api/v1/installs/:id — Delete a single install record.
    func delete(_ request: APIRequest, installID: UUID) -> APIResponse {
        let semaphore = DispatchSemaphore(value: 0)
        var found = false

        Task {
            found = await installTracker.deleteInstall(id: installID)
            semaphore.signal()
        }
        semaphore.wait()

        if found {
            return .json(["deleted": true])
        } else {
            return .error(status: .notFound, message: "Install record not found")
        }
    }

    /// DELETE /api/v1/installs — Delete all install records.
    func deleteAll(_ request: APIRequest) -> APIResponse {
        let semaphore = DispatchSemaphore(value: 0)

        Task {
            await installTracker.deleteAllInstalls()
            semaphore.signal()
        }
        semaphore.wait()

        return .json(["deleted": true])
    }
}
