// Protocol for CRUD operations on saved project configurations.
// Implementations persist ProjectConfig values (e.g. to a JSON file or UserDefaults)
// so the user's projects survive app restarts.
import Foundation

protocol ProjectStoring: Sendable {

    /// Loads all saved project configurations from persistent storage.
    ///
    /// - Returns: An array of every `ProjectConfig` that has been saved. Returns an
    ///   empty array if no projects exist yet.
    /// - Throws: If the backing store is corrupt or unreadable.
    func loadProjects() throws -> [ProjectConfig]

    /// Saves a project configuration to persistent storage. If a project with the same
    /// ID already exists, it is overwritten (update); otherwise a new entry is created.
    ///
    /// - Parameter project: The `ProjectConfig` to save. Its `id` field is used as the
    ///   unique key.
    /// - Throws: If writing to the backing store fails.
    func save(project: ProjectConfig) throws

    /// Deletes a project configuration by its unique identifier.
    ///
    /// - Parameter projectID: The UUID of the project to remove.
    /// - Throws: If the project does not exist or the backing store cannot be written.
    func delete(projectID: UUID) throws

    /// Looks up a project configuration by its unique identifier without throwing.
    ///
    /// - Parameter id: The UUID of the project to find.
    /// - Returns: The matching `ProjectConfig`, or `nil` if no project with that ID exists.
    func project(withID id: UUID) -> ProjectConfig?
}
