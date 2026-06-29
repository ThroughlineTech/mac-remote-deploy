// Tests for the XcodeGen support added in TKT-072: spec detection, repo-root
// project resolution, the scheme detector's project/workspace argument
// resolution, and ProjectConfig's backward-compatible decoding of the new
// signing/toolchain fields.
@testable import RemoteDeployServer
import XCTest
import Foundation
import RemoteDeployShared

final class XcodeGenSupportTests: XCTestCase {

    private var tmp: String!

    override func setUpWithError() throws {
        tmp = (NSTemporaryDirectory() as NSString).appendingPathComponent("xcgs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: tmp)
    }

    @discardableResult
    private func mkdir(_ rel: String) throws -> String {
        let p = (tmp as NSString).appendingPathComponent(rel)
        try FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
        return p
    }

    private func touch(_ dir: String, _ name: String) {
        FileManager.default.createFile(atPath: (dir as NSString).appendingPathComponent(name), contents: Data())
    }

    // MARK: - spec detection

    func test_specName_findsYmlAndYaml() throws {
        let dir = try mkdir("a")
        XCTAssertNil(XcodeGenSupport.specName(inDirectory: dir))
        touch(dir, "project.yml")
        XCTAssertEqual(XcodeGenSupport.specName(inDirectory: dir), "project.yml")
    }

    func test_specDirectory_forBundleReturnsParent() {
        XCTAssertEqual(XcodeGenSupport.specDirectory(for: "/x/y/App.xcodeproj"), "/x/y")
        XCTAssertEqual(XcodeGenSupport.specDirectory(for: "/x/y/App.xcworkspace"), "/x/y")
        XCTAssertEqual(XcodeGenSupport.specDirectory(for: "/x/y"), "/x/y")
    }

    func test_isBuildableDirectory() throws {
        let plain = try mkdir("plain")
        XCTAssertFalse(XcodeGenSupport.isBuildableDirectory(plain))

        let specDir = try mkdir("spec")
        touch(specDir, "project.yaml")
        XCTAssertTrue(XcodeGenSupport.isBuildableDirectory(specDir))

        let projDir = try mkdir("proj")
        try mkdir("proj/App.xcodeproj")
        XCTAssertTrue(XcodeGenSupport.isBuildableDirectory(projDir))
    }

    // MARK: - repo-root resolution (Phase 3)

    func test_resolveProjectDirectory_directSpecDir() throws {
        let dir = try mkdir("ios")
        touch(dir, "project.yml")
        XCTAssertEqual(XcodeGenSupport.resolveProjectDirectory(dir), dir)
    }

    func test_resolveProjectDirectory_repoRootToSingleSubdir() throws {
        let root = try mkdir("repo")
        let ios = try mkdir("repo/repo-ios")
        touch(ios, "project.yml")
        try mkdir("repo/repo-web")       // no spec/project -> not buildable
        try mkdir("repo/repo-android")
        XCTAssertEqual(XcodeGenSupport.resolveProjectDirectory(root), ios)
    }

    func test_resolveProjectDirectory_ambiguousReturnsInput() throws {
        let root = try mkdir("repo2")
        let a = try mkdir("repo2/a"); touch(a, "project.yml")
        let b = try mkdir("repo2/b"); touch(b, "project.yml")
        // Two buildable subdirs -> ambiguous -> leave the path alone so the
        // caller's "no project found" error surfaces rather than guessing.
        XCTAssertEqual(XcodeGenSupport.resolveProjectDirectory(root), root)
    }

    func test_resolveProjectDirectory_skipsPods() throws {
        let root = try mkdir("repo3")
        try mkdir("repo3/Pods/Pods.xcodeproj")     // ignored
        let app = try mkdir("repo3/App")
        try mkdir("repo3/App/App.xcodeproj")
        XCTAssertEqual(XcodeGenSupport.resolveProjectDirectory(root), app)
    }

    func test_regenerateIfNeeded_noSpecIsNoop() throws {
        let dir = try mkdir("nospec")
        XCTAssertNoThrow(try XcodeGenSupport.regenerateIfNeeded(inDirectory: dir))
    }

    // MARK: - scheme detector argument resolution (Phase 1)

    func test_resolveProjectArgument_bundlePaths() throws {
        let ws = try XcodebuildSchemeDetector.resolveProjectArgument(
            path: "/x/App.xcworkspace", projectDir: "/x", isBundle: true)
        XCTAssertEqual(ws.flag, "-workspace")
        XCTAssertEqual(ws.path, "/x/App.xcworkspace")

        let proj = try XcodebuildSchemeDetector.resolveProjectArgument(
            path: "/x/App.xcodeproj", projectDir: "/x", isBundle: true)
        XCTAssertEqual(proj.flag, "-project")
        XCTAssertEqual(proj.path, "/x/App.xcodeproj")
    }

    func test_resolveProjectArgument_directoryPrefersWorkspace() throws {
        let dir = try mkdir("wsdir")
        try mkdir("wsdir/App.xcodeproj")
        try mkdir("wsdir/App.xcworkspace")
        let r = try XcodebuildSchemeDetector.resolveProjectArgument(path: dir, projectDir: dir, isBundle: false)
        XCTAssertEqual(r.flag, "-workspace")
        XCTAssertTrue(r.path.hasSuffix("App.xcworkspace"))
    }

    func test_resolveProjectArgument_noProjectThrows() throws {
        let dir = try mkdir("emptydir")
        XCTAssertThrowsError(
            try XcodebuildSchemeDetector.resolveProjectArgument(path: dir, projectDir: dir, isBundle: false)
        ) { error in
            guard case SchemeDetectionError.noProjectFound = error else {
                return XCTFail("expected .noProjectFound, got \(error)")
            }
        }
    }

    // MARK: - ProjectConfig back-compat (Phases 2/4)

    func test_projectConfig_decodesLegacyJSONWithDefaults() throws {
        // A config saved before TKT-072 has neither field.
        let legacy = """
        {
          "id": "11111111-2222-3333-4444-555555555555",
          "name": "Rejog",
          "projectPath": "/p",
          "scheme": "Rejog",
          "bundleID": "net.rejog.stash",
          "teamID": "ABCDE12345",
          "buildConfiguration": "Release",
          "urlSlug": "rejog",
          "exportMethod": "development"
        }
        """
        let config = try JSONDecoder().decode(ProjectConfig.self, from: Data(legacy.utf8))
        XCTAssertTrue(config.allowProvisioningUpdates, "legacy configs must default to automatic signing")
        XCTAssertNil(config.developerDir, "legacy configs must default to auto-resolved toolchain")
    }

    func test_projectConfig_newFieldsRoundTrip() throws {
        var config = ProjectConfig(name: "X", projectPath: "/p")
        config.allowProvisioningUpdates = false
        config.developerDir = "/Applications/Xcode-beta.app/Contents/Developer"
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(ProjectConfig.self, from: data)
        XCTAssertFalse(decoded.allowProvisioningUpdates)
        XCTAssertEqual(decoded.developerDir, "/Applications/Xcode-beta.app/Contents/Developer")
    }

    func test_projectConfig_defaultInitEnablesProvisioning() {
        let config = ProjectConfig(name: "X", projectPath: "/p")
        XCTAssertTrue(config.allowProvisioningUpdates)
        XCTAssertNil(config.developerDir)
    }
}
