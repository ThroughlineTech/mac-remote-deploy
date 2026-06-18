// Tests for NIODeployServer.syncProjects, the replace-all slug registry sync
// that keeps install routes current after any project store change. TKT-055.
import XCTest
@testable import RemoteDeploy
import RemoteDeployShared

final class NIODeployServerSyncProjectsTests: XCTestCase {

    private func makeServer() -> NIODeployServer {
        NIODeployServer(
            manifestGenerator: ManifestGenerator(),
            installPageGenerator: InstallPageGenerator()
        )
    }

    func testSyncProjectsRegistersAllBySlug() {
        let server = makeServer()
        let p1 = ProjectConfig(name: "Alpha", projectPath: "/a")
        let p2 = ProjectConfig(name: "Beta", projectPath: "/b")

        server.syncProjects([p1, p2])

        let registered = server.registeredProjects()
        XCTAssertEqual(registered.count, 2)
        XCTAssertEqual(registered[p1.urlSlug]?.name, "Alpha")
        XCTAssertEqual(registered[p2.urlSlug]?.name, "Beta")
    }

    func testSyncProjectsDropsRemovedSlugs() {
        let server = makeServer()
        let keep = ProjectConfig(name: "Keep", projectPath: "/keep")
        let drop = ProjectConfig(name: "Drop", projectPath: "/drop")

        server.syncProjects([keep, drop])
        XCTAssertEqual(server.registeredProjects().count, 2)

        // Re-sync without `drop` -- its slug must be gone (the bug this fixes:
        // stale routes lingering after a delete via the API).
        server.syncProjects([keep])

        let registered = server.registeredProjects()
        XCTAssertEqual(registered.count, 1)
        XCTAssertNotNil(registered[keep.urlSlug])
        XCTAssertNil(registered[drop.urlSlug])
    }

    func testSyncProjectsReflectsEdits() {
        let server = makeServer()
        var project = ProjectConfig(name: "Original", projectPath: "/p")
        server.syncProjects([project])

        project.scheme = "NewScheme"
        server.syncProjects([project])

        XCTAssertEqual(server.registeredProjects()[project.urlSlug]?.scheme, "NewScheme")
    }

    func testSyncProjectsEmptyClearsRegistry() {
        let server = makeServer()
        server.syncProjects([ProjectConfig(name: "X", projectPath: "/x")])
        XCTAssertEqual(server.registeredProjects().count, 1)

        server.syncProjects([])
        XCTAssertTrue(server.registeredProjects().isEmpty)
    }
}
