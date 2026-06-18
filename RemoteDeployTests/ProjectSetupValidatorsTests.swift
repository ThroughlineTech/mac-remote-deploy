// Tests for ProjectSetupValidators extracted from ProjectSetupStep. TKT-014.
@testable import RemoteDeployServer
import XCTest

final class ProjectSetupValidatorsTests: XCTestCase {

    // MARK: - validateBundleID

    func test_validateBundleID_emptyReturnsNil() {
        XCTAssertNil(ProjectSetupValidators.validateBundleID(""))
    }

    func test_validateBundleID_acceptsValidReverseDNS() {
        XCTAssertNil(ProjectSetupValidators.validateBundleID("com.example.app"))
        XCTAssertNil(ProjectSetupValidators.validateBundleID("com.example.sub-app"))
        XCTAssertNil(ProjectSetupValidators.validateBundleID("io.a.b.c"))
    }

    func test_validateBundleID_rejectsSingleSegment() {
        XCTAssertNotNil(ProjectSetupValidators.validateBundleID("com"))
    }

    func test_validateBundleID_rejectsTrailingDot() {
        XCTAssertNotNil(ProjectSetupValidators.validateBundleID("com.example."))
    }

    func test_validateBundleID_rejectsDigitFirstSegment() {
        XCTAssertNotNil(ProjectSetupValidators.validateBundleID("1com.example.app"))
    }

    // MARK: - validateTeamID

    func test_validateTeamID_emptyReturnsNil() {
        XCTAssertNil(ProjectSetupValidators.validateTeamID(""))
    }

    func test_validateTeamID_acceptsTenUppercaseAlnum() {
        XCTAssertNil(ProjectSetupValidators.validateTeamID("ABCD123456"))
    }

    func test_validateTeamID_rejectsWrongLength() {
        XCTAssertNotNil(ProjectSetupValidators.validateTeamID("ABCD12345")) // 9
        XCTAssertNotNil(ProjectSetupValidators.validateTeamID("ABCD1234567")) // 11
    }

    func test_validateTeamID_rejectsLowercase() {
        XCTAssertNotNil(ProjectSetupValidators.validateTeamID("abcd123456"))
    }

    // MARK: - validatePath

    func test_validatePath_emptyReturnsNil() {
        XCTAssertNil(ProjectSetupValidators.validatePath(""))
    }

    func test_validatePath_rejectsNonexistentPath() {
        XCTAssertNotNil(ProjectSetupValidators.validatePath("/absolutely/does/not/exist/\(UUID().uuidString)"))
    }

    func test_validatePath_acceptsExistingPath() {
        // /tmp exists on every macOS system
        XCTAssertNil(ProjectSetupValidators.validatePath("/tmp"))
    }

    // MARK: - validateScheme (TKT-014 — empty is an ERROR here)

    func test_validateScheme_emptyReturnsError() {
        XCTAssertNotNil(
            ProjectSetupValidators.validateScheme(""),
            "TKT-014: empty scheme must be rejected — scheme is required to build"
        )
    }

    func test_validateScheme_nonEmptyReturnsNil() {
        XCTAssertNil(ProjectSetupValidators.validateScheme("MyApp"))
    }

    // MARK: - validateExpoProjectPath (TKT-048)

    func test_validateExpoProjectPath_emptyReturnsNil() {
        XCTAssertNil(ProjectSetupValidators.validateExpoProjectPath(""))
    }

    func test_validateExpoProjectPath_acceptsDirectoryWithPackageJson() {
        let dir = NSTemporaryDirectory() + "ExpoValTest-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let pkgJson = (dir as NSString).appendingPathComponent("package.json")
        try? "{}".data(using: .utf8)?.write(to: URL(fileURLWithPath: pkgJson))

        XCTAssertNil(ProjectSetupValidators.validateExpoProjectPath(dir))
    }

    func test_validateExpoProjectPath_rejectsDirectoryWithoutPackageJson() {
        let dir = NSTemporaryDirectory() + "ExpoValTest-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        XCTAssertNotNil(ProjectSetupValidators.validateExpoProjectPath(dir))
    }

    // MARK: - validateExpoAppDirectory (TKT-048)

    func test_validateExpoAppDirectory_emptyAppDirReturnsNil() {
        XCTAssertNil(ProjectSetupValidators.validateExpoAppDirectory("/tmp", expoAppDirectory: nil))
        XCTAssertNil(ProjectSetupValidators.validateExpoAppDirectory("/tmp", expoAppDirectory: ""))
    }

    func test_validateExpoAppDirectory_acceptsDirectoryWithAppJson() {
        let root = NSTemporaryDirectory() + "ExpoAppDirTest-\(UUID().uuidString)"
        let appDir = (root as NSString).appendingPathComponent("app")
        try? FileManager.default.createDirectory(atPath: appDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }

        let appJson = (appDir as NSString).appendingPathComponent("app.json")
        try? "{}".data(using: .utf8)?.write(to: URL(fileURLWithPath: appJson))

        XCTAssertNil(ProjectSetupValidators.validateExpoAppDirectory(root, expoAppDirectory: "app"))
    }

    func test_validateExpoAppDirectory_acceptsDirectoryWithAppConfigJs() {
        let root = NSTemporaryDirectory() + "ExpoAppDirTest-\(UUID().uuidString)"
        let appDir = (root as NSString).appendingPathComponent("app")
        try? FileManager.default.createDirectory(atPath: appDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }

        let appConfigJs = (appDir as NSString).appendingPathComponent("app.config.js")
        try? "module.exports = {}".data(using: .utf8)?.write(to: URL(fileURLWithPath: appConfigJs))

        XCTAssertNil(ProjectSetupValidators.validateExpoAppDirectory(root, expoAppDirectory: "app"))
    }

    func test_validateExpoAppDirectory_rejectsDirectoryWithoutExpoConfig() {
        let root = NSTemporaryDirectory() + "ExpoAppDirTest-\(UUID().uuidString)"
        let appDir = (root as NSString).appendingPathComponent("app")
        try? FileManager.default.createDirectory(atPath: appDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }

        XCTAssertNotNil(ProjectSetupValidators.validateExpoAppDirectory(root, expoAppDirectory: "app"))
    }
}
