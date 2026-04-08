// Tests for ProjectsRouteHandler — full CRUD coverage with happy paths and errors.
@testable import RemoteDeploy
import XCTest
import Foundation
import RemoteDeployShared

final class ProjectsRouteHandlerTests: XCTestCase {

    private func makeHandler() -> (handler: ProjectsRouteHandler, store: MockProjectStore) {
        let store = MockProjectStore()
        let handler = ProjectsRouteHandler(projectStore: store)
        return (handler, store)
    }

    // MARK: - list

    func test_list_returnsAllProjectsFromStore() {
        let (handler, store) = makeHandler()
        store.projects = [
            ProjectConfig(name: "Alpha", projectPath: "/Users/me/Alpha.xcodeproj"),
            ProjectConfig(name: "Beta", projectPath: "/Users/me/Beta.xcodeproj")
        ]
        let req = APITestSupport.makeRequest(method: .GET, uri: "/api/v1/projects")
        let response = handler.list(req)
        XCTAssertEqual(response.status, .ok)
        XCTAssertEqual(store.loadProjectsCallCount, 1)
        let decoded = try? APITestSupport.decoder().decode([ProjectConfig].self, from: response.body)
        XCTAssertEqual(decoded?.count, 2)
        XCTAssertEqual(decoded?.map(\.name), ["Alpha", "Beta"])
    }

    func test_list_returnsEmptyArrayWhenNoProjects() {
        let (handler, _) = makeHandler()
        let req = APITestSupport.makeRequest(method: .GET, uri: "/api/v1/projects")
        let response = handler.list(req)
        XCTAssertEqual(response.status, .ok)
        let decoded = try? APITestSupport.decoder().decode([ProjectConfig].self, from: response.body)
        XCTAssertEqual(decoded?.count, 0)
    }

    func test_list_returns500WhenStoreThrows() {
        let (handler, store) = makeHandler()
        struct FakeError: Error {}
        store.loadProjectsShouldThrow = FakeError()
        let req = APITestSupport.makeRequest(method: .GET, uri: "/api/v1/projects")
        let response = handler.list(req)
        XCTAssertEqual(response.status, .internalServerError)
    }

    // MARK: - get

    func test_get_returnsProjectWhenFound() {
        let (handler, store) = makeHandler()
        let project = ProjectConfig(name: "Alpha", projectPath: "/Users/me/Alpha.xcodeproj")
        store.projects = [project]
        let req = APITestSupport.makeRequest(method: .GET, uri: "/api/v1/projects/\(project.id)")
        let response = handler.get(req, projectID: project.id)
        XCTAssertEqual(response.status, .ok)
        let decoded = try? APITestSupport.decoder().decode(ProjectConfig.self, from: response.body)
        XCTAssertEqual(decoded?.id, project.id)
        XCTAssertEqual(decoded?.name, "Alpha")
    }

    func test_get_returns404WhenProjectMissing() {
        let (handler, _) = makeHandler()
        let req = APITestSupport.makeRequest(method: .GET, uri: "/api/v1/projects/\(UUID())")
        let response = handler.get(req, projectID: UUID())
        XCTAssertEqual(response.status, .notFound)
    }

    // MARK: - create

    func test_create_savesNewProjectAndReturns201() {
        let (handler, store) = makeHandler()
        let project = ProjectConfig(name: "NewApp", projectPath: "/Users/me/NewApp.xcodeproj")
        let body = try! APITestSupport.encoder().encode(project)
        let req = APITestSupport.makeRequest(method: .POST, uri: "/api/v1/projects", body: body)
        let response = handler.create(req)
        XCTAssertEqual(response.status, .created)
        XCTAssertEqual(store.saveCallCount, 1)
        XCTAssertEqual(store.lastSavedProject?.name, "NewApp")
    }

    func test_create_returns400ForMalformedBody() {
        let (handler, store) = makeHandler()
        let req = APITestSupport.makeRequest(method: .POST, uri: "/api/v1/projects", body: Data("bogus".utf8))
        let response = handler.create(req)
        XCTAssertEqual(response.status, .badRequest)
        XCTAssertEqual(store.saveCallCount, 0)
    }

    func test_create_returns500WhenStoreThrows() {
        let (handler, store) = makeHandler()
        struct FakeError: Error {}
        store.saveShouldThrow = FakeError()
        let project = ProjectConfig(name: "NewApp", projectPath: "/Users/me/NewApp.xcodeproj")
        let body = try! APITestSupport.encoder().encode(project)
        let req = APITestSupport.makeRequest(method: .POST, uri: "/api/v1/projects", body: body)
        let response = handler.create(req)
        XCTAssertEqual(response.status, .internalServerError)
    }

    // MARK: - update

    func test_update_overwritesExistingProject() {
        let (handler, store) = makeHandler()
        let original = ProjectConfig(name: "Old", projectPath: "/Users/me/Old.xcodeproj")
        store.projects = [original]
        var updated = original
        updated.name = "New"
        let body = try! APITestSupport.encoder().encode(updated)
        let req = APITestSupport.makeRequest(method: .PUT, uri: "/api/v1/projects/\(original.id)", body: body)
        let response = handler.update(req, projectID: original.id)
        XCTAssertEqual(response.status, .ok)
        XCTAssertEqual(store.lastSavedProject?.name, "New")
        XCTAssertEqual(store.lastSavedProject?.id, original.id)
    }

    func test_update_returns404WhenProjectMissing() {
        let (handler, _) = makeHandler()
        let project = ProjectConfig(name: "Ghost", projectPath: "/Users/me/Ghost.xcodeproj")
        let body = try! APITestSupport.encoder().encode(project)
        let req = APITestSupport.makeRequest(method: .PUT, uri: "/api/v1/projects/\(project.id)", body: body)
        let response = handler.update(req, projectID: project.id)
        XCTAssertEqual(response.status, .notFound)
    }

    func test_update_returns400ForMalformedBody() {
        let (handler, store) = makeHandler()
        let existing = ProjectConfig(name: "Existing", projectPath: "/Users/me/Existing.xcodeproj")
        store.projects = [existing]
        let req = APITestSupport.makeRequest(method: .PUT, uri: "/api/v1/projects/\(existing.id)", body: Data("nope".utf8))
        let response = handler.update(req, projectID: existing.id)
        XCTAssertEqual(response.status, .badRequest)
    }

    func test_update_overridesBodyIDWithURLID() {
        // The handler forces project.id = URL-ID even if the body says otherwise.
        let (handler, store) = makeHandler()
        let existing = ProjectConfig(name: "Existing", projectPath: "/Users/me/Existing.xcodeproj")
        store.projects = [existing]
        var bodyProject = ProjectConfig(name: "RenamedInBody", projectPath: "/Users/me/Other.xcodeproj")
        bodyProject.id = UUID() // Different ID in body.
        let body = try! APITestSupport.encoder().encode(bodyProject)
        let req = APITestSupport.makeRequest(method: .PUT, uri: "/api/v1/projects/\(existing.id)", body: body)
        let response = handler.update(req, projectID: existing.id)
        XCTAssertEqual(response.status, .ok)
        XCTAssertEqual(store.lastSavedProject?.id, existing.id, "URL ID should win over body ID")
    }

    func test_update_returns500WhenStoreSaveThrows() {
        let (handler, store) = makeHandler()
        let existing = ProjectConfig(name: "Existing", projectPath: "/Users/me/Existing.xcodeproj")
        store.projects = [existing]
        struct FakeError: Error {}
        store.saveShouldThrow = FakeError()
        let body = try! APITestSupport.encoder().encode(existing)
        let req = APITestSupport.makeRequest(method: .PUT, uri: "/api/v1/projects/\(existing.id)", body: body)
        let response = handler.update(req, projectID: existing.id)
        XCTAssertEqual(response.status, .internalServerError)
    }

    // MARK: - delete

    func test_delete_removesProjectFromStore() {
        let (handler, store) = makeHandler()
        let project = ProjectConfig(name: "ToDelete", projectPath: "/Users/me/ToDelete.xcodeproj")
        store.projects = [project]
        let req = APITestSupport.makeRequest(method: .DELETE, uri: "/api/v1/projects/\(project.id)")
        let response = handler.delete(req, projectID: project.id)
        XCTAssertEqual(response.status, .ok)
        XCTAssertEqual(store.deleteCallCount, 1)
        XCTAssertEqual(store.lastDeletedProjectID, project.id)
    }

    func test_delete_returns404WhenStoreThrows() {
        let (handler, store) = makeHandler()
        struct FakeError: Error {}
        store.deleteShouldThrow = FakeError()
        let req = APITestSupport.makeRequest(method: .DELETE, uri: "/api/v1/projects/\(UUID())")
        let response = handler.delete(req, projectID: UUID())
        XCTAssertEqual(response.status, .notFound)
    }
}
