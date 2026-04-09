// Shared build state manager used by both the Build tab and ProjectDetailView.
// Ensures only one build runs at a time and both views show consistent status.
import Foundation
import Combine
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
    private var webSocketCancellable: AnyCancellable?

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

    /// Observes WebSocket build status for real-time updates, complementing
    /// the REST polling fallback. Gives instant status transitions instead
    /// of waiting for the 2-second poll interval (TKT-040).
    func observeWebSocketStatus(_ webSocketClient: WebSocketClient) {
        webSocketCancellable?.cancel()
        webSocketCancellable = webSocketClient.$latestStatus
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                guard let self else { return }
                self.buildStatus = status

                // If the WebSocket reports a build started that we didn't
                // trigger locally, sync up our state.
                if status.state == "building" && !self.isBuilding {
                    self.isBuilding = true
                    self.buildingProjectID = status.projectID
                }

                // Terminal states stop the build.
                if status.state == "success" || status.state == "failure" {
                    self.isBuilding = false
                    self.pollTask?.cancel()
                }
            }
    }
}
