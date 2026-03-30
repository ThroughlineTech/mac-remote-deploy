import XCTest
@testable import RemoteDeploy

final class ProjectStoreTests: XCTestCase {

    private var tempDirectory: URL!
    private var sut: UserDefaultsProjectStore!

    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProjectStoreTests-\(UUID().uuidString)")
        sut = UserDefaultsProjectStore(directory: tempDirectory)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDirectory)
        sut = nil
        tempDirectory = nil
        super.tearDown()
    }

    // MARK: - Save and Load

    func testSaveAndLoadProject() throws {
        var project = ProjectConfig(name: "TestApp", projectPath: "/path/to/project")
        project.scheme = "TestApp"
        project.bundleID = "com.test.app"

        try sut.save(project: project)
        let loaded = try sut.loadProjects()

        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.name, "TestApp")
        XCTAssertEqual(loaded.first?.scheme, "TestApp")
        XCTAssertEqual(loaded.first?.bundleID, "com.test.app")
    }

    func testSaveMultipleProjects() throws {
        let project1 = ProjectConfig(name: "App1", projectPath: "/path1")
        let project2 = ProjectConfig(name: "App2", projectPath: "/path2")
        let project3 = ProjectConfig(name: "App3", projectPath: "/path3")

        try sut.save(project: project1)
        try sut.save(project: project2)
        try sut.save(project: project3)

        let loaded = try sut.loadProjects()

        XCTAssertEqual(loaded.count, 3)
    }

    // MARK: - Load When File Doesn't Exist

    func testLoadReturnsEmptyWhenNoFileExists() throws {
        let loaded = try sut.loadProjects()

        XCTAssertTrue(loaded.isEmpty, "Should return empty array when no projects file exists")
    }

    // MARK: - Delete

    func testDeleteRemovesProject() throws {
        let project = ProjectConfig(name: "ToDelete", projectPath: "/path")

        try sut.save(project: project)
        try sut.delete(projectID: project.id)

        let loaded = try sut.loadProjects()

        XCTAssertTrue(loaded.isEmpty, "Deleted project should not be in the loaded list")
    }

    func testDeleteNonexistentProjectThrows() throws {
        let nonexistentID = UUID()

        XCTAssertThrowsError(try sut.delete(projectID: nonexistentID)) { error in
            XCTAssertTrue(error is ProjectStoreError, "Should throw ProjectStoreError")
        }
    }

    func testDeleteOnlyRemovesTargetProject() throws {
        let project1 = ProjectConfig(name: "Keep", projectPath: "/path1")
        let project2 = ProjectConfig(name: "Delete", projectPath: "/path2")

        try sut.save(project: project1)
        try sut.save(project: project2)
        try sut.delete(projectID: project2.id)

        let loaded = try sut.loadProjects()

        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.name, "Keep")
    }

    // MARK: - Find by ID

    func testFindByIDReturnsMatchingProject() throws {
        let project = ProjectConfig(name: "FindMe", projectPath: "/path")

        try sut.save(project: project)
        let found = sut.project(withID: project.id)

        XCTAssertNotNil(found)
        XCTAssertEqual(found?.name, "FindMe")
    }

    func testFindByIDReturnsNilForUnknownID() {
        let found = sut.project(withID: UUID())

        XCTAssertNil(found, "Should return nil for unknown ID")
    }

    func testFindByIDReturnsCorrectProjectAmongMany() throws {
        let project1 = ProjectConfig(name: "Alpha", projectPath: "/a")
        let project2 = ProjectConfig(name: "Beta", projectPath: "/b")
        let project3 = ProjectConfig(name: "Gamma", projectPath: "/c")

        try sut.save(project: project1)
        try sut.save(project: project2)
        try sut.save(project: project3)

        let found = sut.project(withID: project2.id)

        XCTAssertEqual(found?.name, "Beta")
    }

    // MARK: - Update Existing Project

    func testUpdateExistingProject() throws {
        var project = ProjectConfig(name: "Original", projectPath: "/path")
        try sut.save(project: project)

        project.name = "Updated"
        project.scheme = "NewScheme"
        try sut.save(project: project)

        let loaded = try sut.loadProjects()

        XCTAssertEqual(loaded.count, 1, "Updating should not create a duplicate")
        XCTAssertEqual(loaded.first?.name, "Updated")
        XCTAssertEqual(loaded.first?.scheme, "NewScheme")
    }

    func testUpdatePreservesOtherProjects() throws {
        let project1 = ProjectConfig(name: "Static", projectPath: "/path1")
        var project2 = ProjectConfig(name: "Dynamic", projectPath: "/path2")

        try sut.save(project: project1)
        try sut.save(project: project2)

        project2.name = "Changed"
        try sut.save(project: project2)

        let loaded = try sut.loadProjects()

        XCTAssertEqual(loaded.count, 2)
        let names = loaded.map { $0.name }
        XCTAssertTrue(names.contains("Static"), "Unchanged project should remain")
        XCTAssertTrue(names.contains("Changed"), "Updated project should reflect new name")
        XCTAssertFalse(names.contains("Dynamic"), "Old name should be gone")
    }

    // MARK: - Persistence Across Instances

    func testDataPersistsAcrossStoreInstances() throws {
        let project = ProjectConfig(name: "Persistent", projectPath: "/path")
        try sut.save(project: project)

        // Create a new store pointing to the same directory
        let newStore = UserDefaultsProjectStore(directory: tempDirectory)
        let loaded = try newStore.loadProjects()

        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.name, "Persistent")
    }

    // MARK: - ID Preservation

    func testSavedProjectRetainsOriginalID() throws {
        let project = ProjectConfig(name: "IDCheck", projectPath: "/path")
        let originalID = project.id

        try sut.save(project: project)
        let loaded = try sut.loadProjects()

        XCTAssertEqual(loaded.first?.id, originalID, "Saved project should retain its original ID")
    }
}
