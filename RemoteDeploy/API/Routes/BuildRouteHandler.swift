// Handles build-related API endpoints: triggering builds, checking status,
// canceling builds, and retrieving build history.
import Foundation
import RemoteDeployShared

/// Handles build control and status queries from companion devices.
final class BuildRouteHandler: @unchecked Sendable {

    /// Closure that triggers a build for a project. Returns nil on success, error message on failure.
    private let buildTrigger: @Sendable (UUID, String?) -> String?

    /// Closure that returns the current build status info.
    private let buildStatusProvider: @Sendable () -> BuildStatusInfo

    /// Closure that cancels the current build. Returns true if a build was canceled.
    private let buildCanceler: @Sendable () -> Bool

    /// Closure that returns build history.
    private let buildHistoryProvider: @Sendable () -> [BuildResult]

    /// Creates a new build route handler.
    ///
    /// - Parameter buildTrigger: Triggers a build for a project ID with optional config override.
    /// - Parameter buildStatusProvider: Returns current build status.
    /// - Parameter buildCanceler: Cancels the current build.
    /// - Parameter buildHistoryProvider: Returns recent build results.
    init(
        buildTrigger: @escaping @Sendable (UUID, String?) -> String?,
        buildStatusProvider: @escaping @Sendable () -> BuildStatusInfo,
        buildCanceler: @escaping @Sendable () -> Bool,
        buildHistoryProvider: @escaping @Sendable () -> [BuildResult]
    ) {
        self.buildTrigger = buildTrigger
        self.buildStatusProvider = buildStatusProvider
        self.buildCanceler = buildCanceler
        self.buildHistoryProvider = buildHistoryProvider
    }

    /// POST /api/v1/projects/:id/build — Trigger a build.
    func triggerBuild(_ request: APIRequest, projectID: UUID) -> APIResponse {
        let buildRequest = try? request.decodeBody(BuildRequest.self)

        if let errorMessage = buildTrigger(projectID, buildRequest?.configuration) {
            return .error(status: .conflict, message: errorMessage)
        }

        let status = buildStatusProvider()
        return .json(status, status: .accepted)
    }

    /// GET /api/v1/projects/:id/build — Get build status.
    func getBuildStatus(_ request: APIRequest, projectID: UUID) -> APIResponse {
        let status = buildStatusProvider()
        return .json(status)
    }

    /// DELETE /api/v1/projects/:id/build — Cancel the current build.
    func cancelBuild(_ request: APIRequest, projectID: UUID) -> APIResponse {
        if buildCanceler() {
            return .json(["canceled": true])
        }
        return .error(status: .conflict, message: "No build in progress to cancel")
    }

    /// GET /api/v1/builds — Get build history.
    func getBuildHistory(_ request: APIRequest) -> APIResponse {
        let history = buildHistoryProvider()
        return .json(history)
    }
}
