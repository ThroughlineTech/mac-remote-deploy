// Protocol for triggering a build for a project from the API layer.
// The real implementation posts a notification so API-triggered builds
// flow through the same code path as builds initiated from the menu bar UI.
import Foundation

protocol BuildTriggering: Sendable {

    /// Triggers a build for the given project.
    ///
    /// - Parameters:
    ///   - projectID: The UUID of the project to build.
    ///   - configuration: Optional build configuration override (e.g. "Debug", "Release").
    /// - Returns: `nil` on successful trigger, or a human-readable error message on failure
    ///   (e.g. "Project not found").
    func triggerBuild(projectID: UUID, configuration: String?) -> String?
}
