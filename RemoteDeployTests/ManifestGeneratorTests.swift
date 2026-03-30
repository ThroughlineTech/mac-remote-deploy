import XCTest
@testable import RemoteDeploy

final class ManifestGeneratorTests: XCTestCase {

    private var sut: ManifestGenerator!

    override func setUp() {
        super.setUp()
        sut = ManifestGenerator()
    }

    override func tearDown() {
        sut = nil
        super.tearDown()
    }

    // MARK: - Content Tests

    func testGeneratedManifestContainsBundleID() {
        let manifest = sut.generateManifest(
            bundleID: "com.example.MyApp",
            version: "1.0.0",
            appName: "MyApp",
            ipaURL: "https://example.com/app.ipa"
        )

        XCTAssertTrue(manifest.contains("com.example.MyApp"), "Manifest should contain the bundle ID")
    }

    func testGeneratedManifestContainsVersion() {
        let manifest = sut.generateManifest(
            bundleID: "com.example.MyApp",
            version: "2.3.1",
            appName: "MyApp",
            ipaURL: "https://example.com/app.ipa"
        )

        XCTAssertTrue(manifest.contains("2.3.1"), "Manifest should contain the version string")
    }

    func testGeneratedManifestContainsAppName() {
        let manifest = sut.generateManifest(
            bundleID: "com.example.MyApp",
            version: "1.0.0",
            appName: "My Great App",
            ipaURL: "https://example.com/app.ipa"
        )

        XCTAssertTrue(manifest.contains("My Great App"), "Manifest should contain the app name")
    }

    func testGeneratedManifestContainsIPAURL() {
        let manifest = sut.generateManifest(
            bundleID: "com.example.MyApp",
            version: "1.0.0",
            appName: "MyApp",
            ipaURL: "https://deploy.example.com/builds/app.ipa"
        )

        XCTAssertTrue(manifest.contains("https://deploy.example.com/builds/app.ipa"), "Manifest should contain the IPA URL")
    }

    func testGeneratedManifestContainsSoftwarePackageKind() {
        let manifest = sut.generateManifest(
            bundleID: "com.example.MyApp",
            version: "1.0.0",
            appName: "MyApp",
            ipaURL: "https://example.com/app.ipa"
        )

        XCTAssertTrue(manifest.contains("software-package"), "Manifest should specify software-package kind for the asset")
    }

    func testGeneratedManifestContainsSoftwareMetadataKind() {
        let manifest = sut.generateManifest(
            bundleID: "com.example.MyApp",
            version: "1.0.0",
            appName: "MyApp",
            ipaURL: "https://example.com/app.ipa"
        )

        // The metadata section should contain <string>software</string>
        XCTAssertTrue(manifest.contains("<string>software</string>"), "Manifest should specify software kind in metadata")
    }

    // MARK: - XML Validity

    func testGeneratedManifestIsValidXML() {
        let manifest = sut.generateManifest(
            bundleID: "com.example.MyApp",
            version: "1.0.0",
            appName: "MyApp",
            ipaURL: "https://example.com/app.ipa"
        )

        let data = manifest.data(using: .utf8)!
        let parser = XMLParser(data: data)
        let delegate = XMLValidationDelegate()
        parser.delegate = delegate
        let success = parser.parse()

        XCTAssertTrue(success, "Generated manifest should be valid XML. Error: \(delegate.errorDescription ?? "unknown")")
    }

    func testManifestWithSpecialCharactersIsValidXML() {
        let manifest = sut.generateManifest(
            bundleID: "com.example.app",
            version: "1.0.0",
            appName: "Tom & Jerry's <Great> App",
            ipaURL: "https://example.com/app.ipa?token=abc&key=123"
        )

        let data = manifest.data(using: .utf8)!
        let parser = XMLParser(data: data)
        let delegate = XMLValidationDelegate()
        parser.delegate = delegate
        let success = parser.parse()

        XCTAssertTrue(success, "Manifest with special characters should still be valid XML. Error: \(delegate.errorDescription ?? "unknown")")
    }

    // MARK: - Special Characters

    func testAppNameWithAmpersandIsEscaped() {
        let manifest = sut.generateManifest(
            bundleID: "com.example.app",
            version: "1.0.0",
            appName: "Tom & Jerry",
            ipaURL: "https://example.com/app.ipa"
        )

        XCTAssertTrue(manifest.contains("Tom &amp; Jerry"), "Ampersand in app name should be XML-escaped")
        XCTAssertFalse(manifest.contains("<string>Tom & Jerry</string>"), "Raw ampersand should not appear unescaped in XML")
    }

    func testAppNameWithAngleBracketsIsEscaped() {
        let manifest = sut.generateManifest(
            bundleID: "com.example.app",
            version: "1.0.0",
            appName: "App <Beta>",
            ipaURL: "https://example.com/app.ipa"
        )

        XCTAssertTrue(manifest.contains("App &lt;Beta&gt;"), "Angle brackets in app name should be XML-escaped")
    }

    func testAppNameWithQuotesIsEscaped() {
        let manifest = sut.generateManifest(
            bundleID: "com.example.app",
            version: "1.0.0",
            appName: "App \"Pro\"",
            ipaURL: "https://example.com/app.ipa"
        )

        XCTAssertTrue(manifest.contains("App &quot;Pro&quot;"), "Quotes in app name should be XML-escaped")
    }

    func testIPAURLWithQueryParametersIsEscaped() {
        let manifest = sut.generateManifest(
            bundleID: "com.example.app",
            version: "1.0.0",
            appName: "MyApp",
            ipaURL: "https://example.com/app.ipa?a=1&b=2"
        )

        XCTAssertTrue(manifest.contains("a=1&amp;b=2"), "Ampersand in URL should be XML-escaped")
    }

    // MARK: - Structure

    func testManifestStartsWithXMLDeclaration() {
        let manifest = sut.generateManifest(
            bundleID: "com.example.app",
            version: "1.0.0",
            appName: "MyApp",
            ipaURL: "https://example.com/app.ipa"
        )

        XCTAssertTrue(manifest.contains("<?xml version=\"1.0\""), "Manifest should start with XML declaration")
    }

    func testManifestContainsPlistRoot() {
        let manifest = sut.generateManifest(
            bundleID: "com.example.app",
            version: "1.0.0",
            appName: "MyApp",
            ipaURL: "https://example.com/app.ipa"
        )

        XCTAssertTrue(manifest.contains("<plist version=\"1.0\">"), "Manifest should contain plist root element")
        XCTAssertTrue(manifest.contains("</plist>"), "Manifest should close plist root element")
    }

    func testManifestContainsBundleIdentifierKey() {
        let manifest = sut.generateManifest(
            bundleID: "com.example.app",
            version: "1.0.0",
            appName: "MyApp",
            ipaURL: "https://example.com/app.ipa"
        )

        XCTAssertTrue(manifest.contains("<key>bundle-identifier</key>"), "Manifest should contain bundle-identifier key")
    }

    func testManifestContainsBundleVersionKey() {
        let manifest = sut.generateManifest(
            bundleID: "com.example.app",
            version: "1.0.0",
            appName: "MyApp",
            ipaURL: "https://example.com/app.ipa"
        )

        XCTAssertTrue(manifest.contains("<key>bundle-version</key>"), "Manifest should contain bundle-version key")
    }
}

// MARK: - Helpers

private class XMLValidationDelegate: NSObject, XMLParserDelegate {
    var errorDescription: String?

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        errorDescription = parseError.localizedDescription
    }
}
