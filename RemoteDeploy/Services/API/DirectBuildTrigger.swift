// Triggers builds by calling BuildCoordinator directly -- no view, no
// NotificationCenter in the path. Replaces NotificationBuildTrigger so that
// API-triggered builds no longer depend on the menu bar popover having been
// opened (TKT-054, Phase 1).
import Foundation

/// Triggers a build for a project ID by driving the BuildCoordinator.
final class DirectBuildTrigger: BuildTriggering, @unchecked Sendable {

    private let projectStore: any ProjectStoring
    private let coordinator: BuildCoordinator

    /// Creates a new direct build trigger.
    ///
    /// - Parameter projectStore: Used to validate that the requested project
    ///   exists before kicking off the build.
    /// - Parameter coordinator: The view-independent build owner.
    init(projectStore: any ProjectStoring, coordinator: BuildCoordinator) {
        self.projectStore = projectStore
        self.coordinator = coordinator
    }

    func triggerBuild(projectID: UUID, configuration: String?) -> String? {
        // Validate synchronously so the HTTP response is accurate. projectStore is
        // thread-safe and callable straight from the server's event loop.
        guard projectStore.project(withID: projectID) != nil else {
            return "Project not found"
        }
        // Hop to the main actor to drive the coordinator (it reads AppState and
        // delegates to the @MainActor BuildManager).
        Task { @MainActor in
            coordinator.triggerBuild(projectID: projectID, configuration: configuration)
        }
        return nil
    }
}
