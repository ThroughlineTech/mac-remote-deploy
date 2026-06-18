@testable import RemoteDeployServer
import Foundation

final class MockProjectStore: ProjectStoring, @unchecked Sendable {

    // MARK: - Internal storage

    var projects: [ProjectConfig] = []

    // MARK: - loadProjects()

    var loadProjectsCallCount = 0
    var loadProjectsShouldThrow: Error?

    func loadProjects() throws -> [ProjectConfig] {
        loadProjectsCallCount += 1
        if let error = loadProjectsShouldThrow { throw error }
        return projects
    }

    // MARK: - save(project:)

    var saveCallCount = 0
    var lastSavedProject: ProjectConfig?
    var saveShouldThrow: Error?

    func save(project: ProjectConfig) throws {
        saveCallCount += 1
        lastSavedProject = project
        if let error = saveShouldThrow { throw error }
        if let index = projects.firstIndex(where: { $0.id == project.id }) {
            projects[index] = project
        } else {
            projects.append(project)
        }
    }

    // MARK: - delete(projectID:)

    var deleteCallCount = 0
    var lastDeletedProjectID: UUID?
    var deleteShouldThrow: Error?

    func delete(projectID: UUID) throws {
        deleteCallCount += 1
        lastDeletedProjectID = projectID
        if let error = deleteShouldThrow { throw error }
        projects.removeAll { $0.id == projectID }
    }

    // MARK: - project(withID:)

    var projectWithIDCallCount = 0
    var lastProjectWithIDParam: UUID?

    func project(withID id: UUID) -> ProjectConfig? {
        projectWithIDCallCount += 1
        lastProjectWithIDParam = id
        return projects.first { $0.id == id }
    }
}
