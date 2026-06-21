// Tests for FilesystemRouteHandler — directory browsing with path containment
// guards and scheme detection delegation.
@testable import RemoteDeployServer
import XCTest
import Foundation
import RemoteDeployShared

final class FilesystemRouteHandlerTests: XCTestCase {

    private var fixtureDir: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        try super.setUpWithError()
        // Create a fixture directory under the user's home (which lives under /Users/)
        // so it passes the FilesystemRouteHandler's /Users/ prefix guard.
        let home = NSHomeDirectory()
        guard home.hasPrefix("/Users/") else {
            throw XCTSkip("Test environment HOME=\(home) is outside /Users/; skipping browse tests")
        }
        let unique = "RemoteDeployTests-\(UUID().uuidString)"
        fixtureDir = URL(fileURLWithPath: home).appendingPathComponent("Library/Caches").appendingPathComponent(unique)
        try fm.createDirectory(at: fixtureDir, withIntermediateDirectories: true)

        // Seed the fixture: a subdirectory, a hidden file, an .xcodeproj, an .xcworkspace, and a regular file.
        try fm.createDirectory(at: fixtureDir.appendingPathComponent("SubDir"), withIntermediateDirectories: false)
        try Data().write(to: fixtureDir.appendingPathComponent(".hidden"))
        try fm.createDirectory(at: fixtureDir.appendingPathComponent("MyApp.xcodeproj"), withIntermediateDirectories: false)
        try fm.createDirectory(at: fixtureDir.appendingPathComponent("MyApp.xcworkspace"), withIntermediateDirectories: false)
        try Data().write(to: fixtureDir.appendingPathComponent("Readme.md"))
    }

    override func tearDownWithError() throws {
        if let dir = fixtureDir, fm.fileExists(atPath: dir.path) {
            try? fm.removeItem(at: dir)
        }
        try super.tearDownWithError()
    }

    private func makeHandler() -> (handler: FilesystemRouteHandler, detector: MockSchemeDetector) {
        let detector = MockSchemeDetector()
        return (FilesystemRouteHandler(schemeDetector: detector), detector)
    }

    // MARK: - browse happy path

    func test_browse_returnsContentsOfDirectory() {
        let (handler, _) = makeHandler()
        let req = APITestSupport.makeRequest(method: .GET, uri: "/api/v1/filesystem/browse?path=\(fixtureDir.path)")
        let response = handler.browse(req)
        XCTAssertEqual(response.status, .ok)
        let decoded = try? APITestSupport.decoder().decode(FilesystemBrowseResponse.self, from: response.body)
        XCTAssertNotNil(decoded)
        XCTAssertTrue(decoded?.directories.contains("SubDir") ?? false)
        XCTAssertTrue(decoded?.xcodeProjects.contains("MyApp.xcodeproj") ?? false)
        XCTAssertTrue(decoded?.xcodeWorkspaces.contains("MyApp.xcworkspace") ?? false)
        XCTAssertFalse(decoded?.directories.contains(".hidden") ?? true, "Hidden files should be filtered")
        XCTAssertFalse(decoded?.directories.contains("Readme.md") ?? true, "Regular files should not appear in directories")
    }

    func test_browse_includesParentPath() {
        let (handler, _) = makeHandler()
        let req = APITestSupport.makeRequest(method: .GET, uri: "/api/v1/filesystem/browse?path=\(fixtureDir.path)")
        let response = handler.browse(req)
        let decoded = try? APITestSupport.decoder().decode(FilesystemBrowseResponse.self, from: response.body)
        XCTAssertEqual(decoded?.parentPath, fixtureDir.deletingLastPathComponent().path)
    }

    func test_browse_returnsNilParentPathForUsersRoot() {
        let (handler, _) = makeHandler()
        let req = APITestSupport.makeRequest(method: .GET, uri: "/api/v1/filesystem/browse?path=/Users")
        let response = handler.browse(req)
        // /Users itself doesn't start with /Users/ (no trailing slash), so the guard rejects it.
        XCTAssertEqual(response.status, .forbidden, "/Users without trailing slash fails the prefix check — documenting current behavior")
    }

    // MARK: - browse path validation

    func test_browse_returns403ForPathOutsideUsers() {
        let (handler, _) = makeHandler()
        let req = APITestSupport.makeRequest(method: .GET, uri: "/api/v1/filesystem/browse?path=/etc")
        let response = handler.browse(req)
        XCTAssertEqual(response.status, .forbidden)
    }

    func test_browse_returns403ForRootPath() {
        let (handler, _) = makeHandler()
        let req = APITestSupport.makeRequest(method: .GET, uri: "/api/v1/filesystem/browse?path=/")
        let response = handler.browse(req)
        XCTAssertEqual(response.status, .forbidden)
    }

    func test_browse_returns404ForMissingDirectory() {
        let (handler, _) = makeHandler()
        let bogus = fixtureDir.appendingPathComponent("does-not-exist").path
        let req = APITestSupport.makeRequest(method: .GET, uri: "/api/v1/filesystem/browse?path=\(bogus)")
        let response = handler.browse(req)
        XCTAssertEqual(response.status, .notFound)
    }

    func test_browse_returns404ForRegularFile() throws {
        let (handler, _) = makeHandler()
        let filePath = fixtureDir.appendingPathComponent("Readme.md").path
        let req = APITestSupport.makeRequest(method: .GET, uri: "/api/v1/filesystem/browse?path=\(filePath)")
        let response = handler.browse(req)
        XCTAssertEqual(response.status, .notFound, "Regular files are rejected by the isDir guard")
    }

    // MARK: - schemes detection

    func test_detectSchemes_callsMockAndReturnsResult() {
        let (handler, detector) = makeHandler()
        detector.stubbedSchemes = ["AppScheme", "TestsScheme"]
        let path = fixtureDir.appendingPathComponent("MyApp.xcodeproj").path
        let req = APITestSupport.makeRequest(method: .GET, uri: "/api/v1/filesystem/schemes?path=\(path)")
        let response = handler.detectSchemes(req)
        XCTAssertEqual(response.status, .ok)
        XCTAssertEqual(detector.detectSchemesCallCount, 1)
        XCTAssertEqual(detector.lastPath, path)
        let decoded = try? APITestSupport.decoder().decode(SchemesResponse.self, from: response.body)
        XCTAssertEqual(decoded?.schemes, ["AppScheme", "TestsScheme"])
    }

    func test_detectSchemes_returns400ForMissingPath() {
        let (handler, detector) = makeHandler()
        let req = APITestSupport.makeRequest(method: .GET, uri: "/api/v1/filesystem/schemes")
        let response = handler.detectSchemes(req)
        XCTAssertEqual(response.status, .badRequest)
        XCTAssertEqual(detector.detectSchemesCallCount, 0)
    }

    func test_detectSchemes_returns403ForPathOutsideUsers() {
        let (handler, detector) = makeHandler()
        let req = APITestSupport.makeRequest(method: .GET, uri: "/api/v1/filesystem/schemes?path=/etc/passwd")
        let response = handler.detectSchemes(req)
        XCTAssertEqual(response.status, .forbidden)
        XCTAssertEqual(detector.detectSchemesCallCount, 0)
    }

    func test_detectSchemes_returnsEmptyArrayWhenDetectorReturnsNone() {
        let (handler, detector) = makeHandler()
        detector.stubbedSchemes = []
        let path = fixtureDir.appendingPathComponent("MyApp.xcodeproj").path
        let req = APITestSupport.makeRequest(method: .GET, uri: "/api/v1/filesystem/schemes?path=\(path)")
        let response = handler.detectSchemes(req)
        XCTAssertEqual(response.status, .ok)
        let decoded = try? APITestSupport.decoder().decode(SchemesResponse.self, from: response.body)
        XCTAssertEqual(decoded?.schemes.count, 0)
    }

    func test_detectSchemes_returns500WithMessageWhenDetectorThrows() {
        let (handler, detector) = makeHandler()
        detector.stubbedError = NSError(
            domain: "Test", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "xcodebuild failed: boom"]
        )
        let path = fixtureDir.appendingPathComponent("MyApp.xcodeproj").path
        let req = APITestSupport.makeRequest(method: .GET, uri: "/api/v1/filesystem/schemes?path=\(path)")
        let response = handler.detectSchemes(req)
        XCTAssertEqual(response.status, .internalServerError)
        let decoded = try? APITestSupport.decoder().decode(APIError.self, from: response.body)
        XCTAssertEqual(decoded?.message, "xcodebuild failed: boom")
    }
}
