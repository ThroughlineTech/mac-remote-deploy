// Handles build-related API endpoints: triggering builds, checking status,
// canceling builds, and retrieving build history.
import Foundation
import RemoteDeployShared

/// Handles build control and status queries from companion devices.
final class BuildRouteHandler: @unchecked Sendable {

    private let buildTrigger: any BuildTriggering
    private let buildStatus: any BuildStatusProviding
    private let buildCanceler: any BuildCanceling
    private let buildHistory: any BuildHistoryProviding

    /// Creates a new build route handler.
    ///
    /// - Parameter buildTrigger: Triggers a build for a project ID with optional config override.
    /// - Parameter buildStatus: Returns current build status.
    /// - Parameter buildCanceler: Cancels the current build.
    /// - Parameter buildHistory: Returns recent build results.
    init(
        buildTrigger: any BuildTriggering,
        buildStatus: any BuildStatusProviding,
        buildCanceler: any BuildCanceling,
        buildHistory: any BuildHistoryProviding
    ) {
        self.buildTrigger = buildTrigger
        self.buildStatus = buildStatus
        self.buildCanceler = buildCanceler
        self.buildHistory = buildHistory
    }

    /// POST /api/v1/projects/:id/build — Trigger a build.
    func triggerBuild(_ request: APIRequest, projectID: UUID) -> APIResponse {
        let buildRequest = try? request.decodeBody(BuildRequest.self)

        if let errorMessage = buildTrigger.triggerBuild(projectID: projectID, configuration: buildRequest?.configuration) {
            return .error(status: .conflict, message: errorMessage)
        }

        let status = buildStatus.currentBuildStatus()
        return .json(status, status: .accepted)
    }

    /// GET /api/v1/projects/:id/build — Get build status.
    func getBuildStatus(_ request: APIRequest, projectID: UUID) -> APIResponse {
        let status = buildStatus.currentBuildStatus()
        return .json(status)
    }

    /// DELETE /api/v1/projects/:id/build — Cancel the current build.
    func cancelBuild(_ request: APIRequest, projectID: UUID) -> APIResponse {
        if buildCanceler.cancelCurrentBuild() {
            return .json(["canceled": true])
        }
        return .error(status: .conflict, message: "No build in progress to cancel")
    }

    /// GET /api/v1/builds — Get build history.
    func getBuildHistory(_ request: APIRequest) -> APIResponse {
        let history = buildHistory.recentBuilds()
        return .json(history)
    }
}
