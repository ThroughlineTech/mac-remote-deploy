// Tests for the XcodeGen auto-generate step added to XcodeBuildEngine.
//
// XcodeGen-managed projects keep the generated .xcodeproj out of source
// control, so detectSchemes(at:)/build(project:) now run `xcodegen generate`
// from a project.yml spec before invoking xcodebuild. These tests build a
// throwaway spec in a temp directory and assert the engine regenerates the
// project and reports its scheme -- proving the regeneration happens and feeds
// scheme detection. They use the real xcodegen + xcodebuild tools and skip when
// either is unavailable (e.g. CI with only the Command Line Tools).
@testable import RemoteDeployServer
import XCTest
import Foundation

final class XcodeBuildEngineXcodeGenTests: XCTestCase {

    /// Skips the test unless both XcodeGen and a full Xcode (with xcodebuild)
    /// are installed, since the engine shells out to both.
    private func skipUnlessToolchainAvailable() throws {
        let fm = FileManager.default
        let xcodegenInstalled = ["/opt/homebrew/bin/xcodegen", "/usr/local/bin/xcodegen"]
            .contains { fm.isExecutableFile(atPath: $0) }
        guard xcodegenInstalled else {
            throw XCTSkip("XcodeGen not installed; skipping XcodeGen integration test.")
        }
        let xcodeInstalled = [
            "/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild",
            "/Applications/Xcode-beta.app/Contents/Developer/usr/bin/xcodebuild",
        ].contains { fm.isExecutableFile(atPath: $0) }
        guard xcodeInstalled else {
            throw XCTSkip("No full Xcode found; skipping XcodeGen integration test.")
        }
    }

    /// Writes a minimal XcodeGen spec (one iOS app target + one source file +
    /// one explicit scheme) into a fresh temp directory and returns its path.
    private func makeFixtureProject() throws -> String {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory
            .appendingPathComponent("RD-XcodeGenTest-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let sources = dir.appendingPathComponent("Sources")
        try fm.createDirectory(at: sources, withIntermediateDirectories: true)
        try "// fixture\n".write(
            to: sources.appendingPathComponent("App.swift"),
            atomically: true,
            encoding: .utf8
        )

        let spec = """
        name: Fixture
        targets:
          FixtureApp:
            type: application
            platform: iOS
            sources: [Sources]
        schemes:
          FixtureApp:
            build:
              targets:
                FixtureApp: all
        """
        try spec.write(
            to: dir.appendingPathComponent("project.yml"),
            atomically: true,
            encoding: .utf8
        )
        return dir.path
    }

    func test_detectSchemes_generatesProjectFromSpec_andReportsScheme() async throws {
        try skipUnlessToolchainAvailable()
        let projectDir = try makeFixtureProject()
        defer { try? FileManager.default.removeItem(atPath: projectDir) }

        // The .xcodeproj does not exist yet -- only project.yml does.
        let xcodeprojPath = (projectDir as NSString).appendingPathComponent("Fixture.xcodeproj")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: xcodeprojPath),
            "Fixture should start without a generated .xcodeproj"
        )

        let engine = XcodeBuildEngine()
        let schemes = try await engine.detectSchemes(at: projectDir)

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: xcodeprojPath),
            "Engine should have generated the .xcodeproj from project.yml"
        )
        XCTAssertTrue(
            schemes.contains("FixtureApp"),
            "Expected the regenerated project's scheme; got \(schemes)"
        )
    }
}
