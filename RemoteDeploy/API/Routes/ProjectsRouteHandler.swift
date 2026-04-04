// Handles CRUD operations for project configurations via the API.
// Maps to GET/POST/PUT/DELETE /api/v1/projects endpoints.
import Foundation
import RemoteDeployShared

/// Handles project listing, creation, update, and deletion.
final class ProjectsRouteHandler: @unchecked Sendable {

    private let projectStore: ProjectStoring

    /// Creates a new projects route handler.
    ///
    /// - Parameter projectStore: The store for persisting project configurations.
    init(projectStore: ProjectStoring) {
        self.projectStore = projectStore
    }

    /// GET /api/v1/projects — List all projects.
    func list(_ request: APIRequest) -> APIResponse {
        do {
            let projects = try projectStore.loadProjects()
            return .json(projects)
        } catch {
            return .error(status: .internalServerError, message: "Failed to load projects: \(error.localizedDescription)")
        }
    }

    /// GET /api/v1/projects/:id — Get a single project.
    func get(_ request: APIRequest, projectID: UUID) -> APIResponse {
        guard let project = projectStore.project(withID: projectID) else {
            return .error(status: .notFound, message: "Project not found")
        }
        return .json(project)
    }

    /// POST /api/v1/projects — Create a new project.
    func create(_ request: APIRequest) -> APIResponse {
        guard let project = try? request.decodeBody(ProjectConfig.self) else {
            return .error(status: .badRequest, message: "Invalid project configuration")
        }

        do {
            try projectStore.save(project: project)
            return .json(project, status: .created)
        } catch {
            return .error(status: .internalServerError, message: "Failed to save project: \(error.localizedDescription)")
        }
    }

    /// PUT /api/v1/projects/:id — Update an existing project.
    func update(_ request: APIRequest, projectID: UUID) -> APIResponse {
        guard projectStore.project(withID: projectID) != nil else {
            return .error(status: .notFound, message: "Project not found")
        }

        guard var project = try? request.decodeBody(ProjectConfig.self) else {
            return .error(status: .badRequest, message: "Invalid project configuration")
        }

        // Ensure the ID matches the URL
        project.id = projectID

        do {
            try projectStore.save(project: project)
            return .json(project)
        } catch {
            return .error(status: .internalServerError, message: "Failed to update project: \(error.localizedDescription)")
        }
    }

    /// DELETE /api/v1/projects/:id — Delete a project.
    func delete(_ request: APIRequest, projectID: UUID) -> APIResponse {
        do {
            try projectStore.delete(projectID: projectID)
            return .json(["deleted": true])
        } catch {
            return .error(status: .notFound, message: "Project not found")
        }
    }
}
