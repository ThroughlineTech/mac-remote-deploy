// Real implementation of BuildTriggering that posts an .apiBuildRequested
// notification on the main queue. The MenuBarView listens for this and runs
// the same build flow as the manual UI button, ensuring API-triggered builds
// behave identically to UI-triggered builds.
import Foundation

/// Triggers builds by posting a NotificationCenter notification handled by the menu bar UI.
final class NotificationBuildTrigger: BuildTriggering, @unchecked Sendable {

    private let projectStore: any ProjectStoring

    /// Creates a new notification-based build trigger.
    ///
    /// - Parameter projectStore: Used to validate that the requested project exists before posting.
    init(projectStore: any ProjectStoring) {
        self.projectStore = projectStore
    }

    func triggerBuild(projectID: UUID, configuration: String?) -> String? {
        guard projectStore.project(withID: projectID) != nil else {
            return "Project not found"
        }
        // Post on main thread so the MenuBarView listener fires the same flow as the UI button.
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .apiBuildRequested,
                object: nil,
                userInfo: ["projectID": projectID, "configuration": configuration as Any]
            )
        }
        return nil
    }
}
