import XCTest
@testable import RemoteDeployServer

final class InstallPageGeneratorTests: XCTestCase {

    private var sut: InstallPageGenerator!

    override func setUp() {
        super.setUp()
        sut = InstallPageGenerator()
    }

    override func tearDown() {
        sut = nil
        super.tearDown()
    }

    // MARK: - Install Page Content

    func testGeneratedPageContainsAppName() {
        let html = sut.generatePage(
            appName: "MyApp",
            version: "1.0.0",
            build: "42",
            buildTime: "2026-03-30 10:00",
            manifestURL: "https://example.com/manifest.plist"
        )

        XCTAssertTrue(html.contains("MyApp"), "Page should contain the app name")
    }

    func testGeneratedPageContainsVersion() {
        let html = sut.generatePage(
            appName: "MyApp",
            version: "2.5.0",
            build: "99",
            buildTime: "2026-03-30 10:00",
            manifestURL: "https://example.com/manifest.plist"
        )

        XCTAssertTrue(html.contains("2.5.0"), "Page should contain the version")
    }

    func testGeneratedPageContainsBuildNumber() {
        let html = sut.generatePage(
            appName: "MyApp",
            version: "1.0.0",
            build: "137",
            buildTime: "2026-03-30 10:00",
            manifestURL: "https://example.com/manifest.plist"
        )

        XCTAssertTrue(html.contains("137"), "Page should contain the build number")
    }

    func testGeneratedPageContainsBuildTime() {
        let html = sut.generatePage(
            appName: "MyApp",
            version: "1.0.0",
            build: "42",
            buildTime: "2026-03-30 14:30:00",
            manifestURL: "https://example.com/manifest.plist"
        )

        XCTAssertTrue(html.contains("2026-03-30 14:30:00"), "Page should contain the build time")
    }

    func testGeneratedPageContainsItmsServicesLink() {
        let manifestURL = "https://deploy.example.com/myapp/manifest.plist"
        let html = sut.generatePage(
            appName: "MyApp",
            version: "1.0.0",
            build: "42",
            buildTime: "2026-03-30 10:00",
            manifestURL: manifestURL
        )

        let expectedLink = "itms-services://?action=download-manifest&url=\(manifestURL)"
        XCTAssertTrue(html.contains(expectedLink), "Page should contain itms-services link with manifest URL. Got: \(html)")
    }

    func testGeneratedPageContainsInstallButton() {
        let html = sut.generatePage(
            appName: "MyApp",
            version: "1.0.0",
            build: "42",
            buildTime: "2026-03-30 10:00",
            manifestURL: "https://example.com/manifest.plist"
        )

        XCTAssertTrue(html.contains("Install</a>"), "Page should contain an Install button/link")
    }

    func testGeneratedPageIsValidHTML() {
        let html = sut.generatePage(
            appName: "MyApp",
            version: "1.0.0",
            build: "42",
            buildTime: "2026-03-30 10:00",
            manifestURL: "https://example.com/manifest.plist"
        )

        XCTAssertTrue(html.contains("<!DOCTYPE html>"), "Page should start with DOCTYPE")
        XCTAssertTrue(html.contains("<html"), "Page should contain html tag")
        XCTAssertTrue(html.contains("</html>"), "Page should close html tag")
    }

    func testGeneratedPageContainsAppNameInTitle() {
        let html = sut.generatePage(
            appName: "SuperApp",
            version: "1.0.0",
            build: "1",
            buildTime: "now",
            manifestURL: "https://example.com/manifest.plist"
        )

        XCTAssertTrue(html.contains("<title>Install SuperApp</title>"), "Page title should include the app name")
    }

    func testGeneratedPageEscapesHTMLInAppName() {
        let html = sut.generatePage(
            appName: "<script>alert('xss')</script>",
            version: "1.0.0",
            build: "1",
            buildTime: "now",
            manifestURL: "https://example.com/manifest.plist"
        )

        XCTAssertFalse(html.contains("<script>alert"), "Page should escape HTML in app name to prevent injection")
        XCTAssertTrue(html.contains("&lt;script&gt;"), "HTML special characters should be escaped")
    }

    func testGeneratedPageEscapesAmpersandInVersion() {
        let html = sut.generatePage(
            appName: "MyApp",
            version: "1.0 & beta",
            build: "1",
            buildTime: "now",
            manifestURL: "https://example.com/manifest.plist"
        )

        XCTAssertTrue(html.contains("1.0 &amp; beta"), "Ampersand in version should be HTML-escaped")
    }

    // MARK: - Index Page

    func testIndexPageContainsProjectName() {
        let projects: [(name: String, slug: String, version: String?)] = [
            (name: "MyApp", slug: "myapp", version: "1.0.0")
        ]

        let html = sut.generateIndexPage(projects: projects)

        XCTAssertTrue(html.contains("MyApp"), "Index page should contain the project name")
    }

    func testIndexPageContainsProjectVersion() {
        let projects: [(name: String, slug: String, version: String?)] = [
            (name: "MyApp", slug: "myapp", version: "2.3.0")
        ]

        let html = sut.generateIndexPage(projects: projects)

        XCTAssertTrue(html.contains("v2.3.0"), "Index page should show the version prefixed with 'v'")
    }

    func testIndexPageLinksToProjectSlug() {
        let projects: [(name: String, slug: String, version: String?)] = [
            (name: "MyApp", slug: "my-app", version: "1.0.0")
        ]

        let html = sut.generateIndexPage(projects: projects)

        XCTAssertTrue(html.contains("href=\"/my-app/\""), "Index page should link to the project slug path")
    }

    func testIndexPageWithMultipleProjects() {
        let projects: [(name: String, slug: String, version: String?)] = [
            (name: "Alpha", slug: "alpha", version: "1.0"),
            (name: "Beta", slug: "beta", version: "2.0"),
            (name: "Gamma", slug: "gamma", version: nil)
        ]

        let html = sut.generateIndexPage(projects: projects)

        XCTAssertTrue(html.contains("Alpha"), "Index page should contain first project")
        XCTAssertTrue(html.contains("Beta"), "Index page should contain second project")
        XCTAssertTrue(html.contains("Gamma"), "Index page should contain third project")
        XCTAssertTrue(html.contains("href=\"/alpha/\""), "Index page should link to first project slug")
        XCTAssertTrue(html.contains("href=\"/beta/\""), "Index page should link to second project slug")
        XCTAssertTrue(html.contains("href=\"/gamma/\""), "Index page should link to third project slug")
    }

    func testIndexPageWithNilVersionOmitsVersionLabel() {
        let projects: [(name: String, slug: String, version: String?)] = [
            (name: "MyApp", slug: "myapp", version: nil)
        ]

        let html = sut.generateIndexPage(projects: projects)

        XCTAssertTrue(html.contains("MyApp"), "Index page should show the project name")
        XCTAssertFalse(html.contains(" v"), "Index page should not show a version label when version is nil")
    }

    func testIndexPageWithEmptyProjectsListRendersTemplate() {
        let projects: [(name: String, slug: String, version: String?)] = []

        let html = sut.generateIndexPage(projects: projects)

        XCTAssertTrue(html.contains("RemoteDeploy"), "Index page should still contain the heading")
        XCTAssertTrue(html.contains("<!DOCTYPE html>"), "Index page should be valid HTML")
    }

    func testIndexPageEscapesHTMLInProjectName() {
        let projects: [(name: String, slug: String, version: String?)] = [
            (name: "App<script>", slug: "app", version: "1.0")
        ]

        let html = sut.generateIndexPage(projects: projects)

        XCTAssertFalse(html.contains("App<script>"), "Index page should escape HTML in project names")
        XCTAssertTrue(html.contains("App&lt;script&gt;"), "HTML special characters should be escaped")
    }

    func testIndexPageContainsProjectCards() {
        let projects: [(name: String, slug: String, version: String?)] = [
            (name: "MyApp", slug: "myapp", version: "1.0.0")
        ]

        let html = sut.generateIndexPage(projects: projects)

        XCTAssertTrue(html.contains("project-card"), "Index page should use project-card class")
    }
}
