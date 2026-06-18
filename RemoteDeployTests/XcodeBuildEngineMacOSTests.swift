// Tests for macOS build path in XcodeBuildEngine. Verifies that macOS
// projects trigger the zip path and iOS projects still use the IPA export path.
// TKT-051.
import XCTest
@testable import RemoteDeployServer

final class XcodeBuildEngineMacOSTests: XCTestCase {

    // MARK: - Install Page Generator (macOS download page)

    func testDownloadPageContainsDownloadButton() {
        let sut = InstallPageGenerator()
        let html = sut.generateDownloadPage(
            appName: "TestMacApp",
            version: "1.0.0",
            build: "1",
            buildTime: "2026-04-13 10:00",
            downloadURL: "https://example.com/testmacapp/app.zip"
        )

        XCTAssertTrue(html.contains("Download</a>"), "macOS page should have a Download button")
        XCTAssertFalse(html.contains("itms-services://"), "macOS page should NOT contain itms-services link")
    }

    func testDownloadPageContainsAppName() {
        let sut = InstallPageGenerator()
        let html = sut.generateDownloadPage(
            appName: "MyMacApp",
            version: "2.0.0",
            build: "5",
            buildTime: "2026-04-13 10:00",
            downloadURL: "https://example.com/mymacapp/app.zip"
        )

        XCTAssertTrue(html.contains("MyMacApp"), "macOS page should contain the app name")
    }

    func testDownloadPageContainsDownloadURL() {
        let sut = InstallPageGenerator()
        let downloadURL = "https://example.com/slug/app.zip"
        let html = sut.generateDownloadPage(
            appName: "App",
            version: "1.0",
            build: "1",
            buildTime: "now",
            downloadURL: downloadURL
        )

        XCTAssertTrue(html.contains(downloadURL), "macOS page should contain the download URL")
    }

    func testDownloadPageContainsPlatformBadge() {
        let sut = InstallPageGenerator()
        let html = sut.generateDownloadPage(
            appName: "App",
            version: "1.0",
            build: "1",
            buildTime: "now",
            downloadURL: "https://example.com/app.zip"
        )

        XCTAssertTrue(html.contains("macOS"), "macOS page should contain a macOS platform badge")
    }

    func testDownloadPageIsValidHTML() {
        let sut = InstallPageGenerator()
        let html = sut.generateDownloadPage(
            appName: "App",
            version: "1.0",
            build: "1",
            buildTime: "now",
            downloadURL: "https://example.com/app.zip"
        )

        XCTAssertTrue(html.contains("<!DOCTYPE html>"), "Page should start with DOCTYPE")
        XCTAssertTrue(html.contains("</html>"), "Page should close html tag")
    }

    func testDownloadPageEscapesHTML() {
        let sut = InstallPageGenerator()
        let html = sut.generateDownloadPage(
            appName: "<script>alert('xss')</script>",
            version: "1.0",
            build: "1",
            buildTime: "now",
            downloadURL: "https://example.com/app.zip"
        )

        XCTAssertFalse(html.contains("<script>alert"), "Page should escape HTML in app name")
        XCTAssertTrue(html.contains("&lt;script&gt;"), "HTML special characters should be escaped")
    }

    // MARK: - Build Engine Router (macOS vs iOS dispatch)

    func testMacOSProjectStillRoutesToXcodeEngine() async throws {
        let xcodeEngine = MockBuildEngine()
        let expoEngine = MockExpoBuildEngine()
        let router = MockableBuildEngineRouter(xcodeEngine: xcodeEngine, expoEngine: expoEngine)

        var project = ProjectConfig(name: "MacApp", projectPath: "/tmp/mac")
        project.projectType = .xcode
        project.platform = "macOS"
        project.scheme = "MacApp"
        project.teamID = "ABCDE12345"

        _ = try await router.build(project: project)

        XCTAssertEqual(xcodeEngine.buildCallCount, 1, "macOS .xcode project should route to Xcode engine")
        XCTAssertEqual(expoEngine.buildCallCount, 0, "Expo engine should not be called for macOS project")
    }

    func testIOSProjectStillRoutesToXcodeEngine() async throws {
        let xcodeEngine = MockBuildEngine()
        let expoEngine = MockExpoBuildEngine()
        let router = MockableBuildEngineRouter(xcodeEngine: xcodeEngine, expoEngine: expoEngine)

        var project = ProjectConfig(name: "IOSApp", projectPath: "/tmp/ios")
        project.projectType = .xcode
        project.platform = "iOS"
        project.scheme = "IOSApp"
        project.teamID = "ABCDE12345"

        _ = try await router.build(project: project)

        XCTAssertEqual(xcodeEngine.buildCallCount, 1, "iOS .xcode project should route to Xcode engine")
    }
}
