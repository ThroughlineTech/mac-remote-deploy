// Shared build state manager used by both the Build tab and ProjectDetailView.
// Ensures only one build runs at a time and both views show consistent status.
import Foundation
import RemoteDeployShared

/// Manages build state across the companion app. Both the Build tab and
/// ProjectDetailView observe this object for consistent build status.
@MainActor
final class BuildManager: ObservableObject {

    /// Current build status from the server.
    @Published var buildStatus: BuildStatusInfo?

    /// Whether a build is currently in progress.
    @Published var isBuilding = false

    /// Error message from the last build attempt.
    @Published var error: String?

    /// The project ID currently being built.
    @Published var buildingProjectID: UUID?

    private var pollTask: Task<Void, Never>?
    private weak var apiClient: APIClient?

    /// Sets the API client. Called when the connection is established.
    func setClient(_ client: APIClient?) {
        self.apiClient = client
    }

    /// Triggers a build for the given project.
    func triggerBuild(projectID: UUID) {
        guard let client = apiClient else { return }
        guard !isBuilding else {
            error = "A build is already in progress"
            return
        }

        isBuilding = true
        buildingProjectID = projectID
        error = nil
        buildStatus = BuildStatusInfo(state: "building", message: "Submitting...")

        Task {
            do {
                _ = try await client.triggerBuild(projectID: projectID)
                startPolling()
            } catch {
                self.error = error.localizedDescription
                isBuilding = false
                buildStatus = BuildStatusInfo(state: "failure", message: error.localizedDescription)
            }
        }
    }

    /// Cancels the current build.
    func cancelBuild() {
        guard let client = apiClient, let projectID = buildingProjectID else { return }
        Task {
            try? await client.cancelBuild(projectID: projectID)
            pollTask?.cancel()
            isBuilding = false
            buildStatus = BuildStatusInfo(state: "idle", message: "Canceled")
        }
    }

    /// Polls the server every 2 seconds for build status until the build finishes.
    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task {
            guard let client = apiClient else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                if Task.isCancelled { break }

                do {
                    let status = try await client.getStatus()
                    buildStatus = status.buildStatus

                    switch status.buildStatus.state {
                    case "success":
                        isBuilding = false
                        return
                    case "failure":
                        isBuilding = false
                        return
                    case "idle":
                        if isBuilding {
                            isBuilding = false
                            buildStatus = BuildStatusInfo(state: "success", message: "Build complete")
                        }
                        return
                    default:
                        break
                    }
                } catch {
                    // Transient network error — keep polling
                }
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
    }
}
