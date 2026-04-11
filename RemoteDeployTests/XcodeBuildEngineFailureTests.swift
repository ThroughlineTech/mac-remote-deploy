// Tests for the preflight-failure error path added in TKT-045.
//
// These tests run a real `xcodebuild` against this repo's own .xcodeproj with
// deliberately bogus arguments (invalid scheme, invalid destination) so that
// xcodebuild exits non-zero before any compile work begins. They assert that
// `XcodeBuildEngine.build(project:)` throws `BuildError.xcodebuildFailed` and
// that the thrown error's message contains a substring of the actual
// xcodebuild stderr — proving the stderr ring-buffer is populated and the
// failure message includes the user-facing error rather than just an exit code.
//
// Each test takes 1-3 seconds because xcodebuild has to load and validate the
// project before it can produce a destination/scheme error.
@testable import RemoteDeploy
import RemoteDeployShared
import XCTest
import Foundation

final class XcodeBuildEngineFailureTests: XCTestCase {

    /// Locates this repo's RemoteDeploy.xcodeproj relative to this test file
    /// so the test is robust against the working directory the test runner
    /// chooses. We walk up from `#filePath` (RemoteDeployTests/...) until we
    /// find the directory containing the .xcodeproj.
    private func locateRepoXcodeproj(file: StaticString = #filePath) throws -> String {
        let testFile = URL(fileURLWithPath: "\(file)")
        var dir = testFile.deletingLastPathComponent()
        let fm = FileManager.default
        // Walk up at most 6 levels looking for RemoteDeploy.xcodeproj.
        for _ in 0..<6 {
            let candidate = dir.appendingPathComponent("RemoteDeploy.xcodeproj").path
            if fm.fileExists(atPath: candidate) {
                return candidate
            }
            dir = dir.deletingLastPathComponent()
        }
        throw XCTSkip("Could not find RemoteDeploy.xcodeproj relative to \(file)")
    }

    /// Builds a `ProjectConfig` pointing at this repo's xcodeproj with the
    /// given scheme + platform. teamID is intentionally a placeholder string
    /// because xcodebuild should fail at the destination/scheme stage long
    /// before signing.
    private func makeBogusProject(scheme: String, platform: String) throws -> ProjectConfig {
        let xcodeprojPath = try locateRepoXcodeproj()
        var project = ProjectConfig(name: "TKT045-Test", projectPath: xcodeprojPath)
        project.scheme = scheme
        project.platform = platform
        project.teamID = "ZZZZZZZZZZ"
        project.buildConfiguration = "Debug"
        project.exportMethod = "development"
        return project
    }

    /// Verifies that calling `build(project:)` with a scheme that does not
    /// exist in the project causes the engine to throw `BuildError.xcodebuildFailed`
    /// and that the thrown error's `errorDescription` includes a substring of
    /// the real xcodebuild stderr (proving the stderr ring-buffer is populated
    /// and surfaced in the failure message).
    func test_runXcodebuild_withInvalidScheme_throwsWithStderrInMessage() async throws {
        let engine = XcodeBuildEngine()
        let project = try makeBogusProject(scheme: "DoesNotExistScheme", platform: "macOS")

        do {
            _ = try await engine.build(project: project)
            XCTFail("Expected build(project:) to throw for an invalid scheme")
        } catch let error as BuildError {
            guard case .xcodebuildFailed(let code, let msg) = error else {
                XCTFail("Expected BuildError.xcodebuildFailed, got \(error)")
                return
            }
            XCTAssertNotEqual(code, 0, "Expected a non-zero exit code from xcodebuild")
            // The thrown message should be richer than the bare exit-code
            // string — it should contain a tail of the actual xcodebuild
            // stderr. Look for any of the substrings xcodebuild is known to
            // emit when a scheme cannot be found.
            let description = error.errorDescription ?? ""
            let lower = (description + "\n" + msg).lowercased()
            XCTAssertTrue(
                lower.contains("scheme")
                    || lower.contains("doesnotexistscheme")
                    || lower.contains("not found"),
                "Expected stderr substring in failure message, got: \(description)"
            )
        } catch {
            XCTFail("Expected BuildError, got \(type(of: error)): \(error)")
        }
    }

    /// Verifies the engine throws and surfaces the stderr tail when xcodebuild
    /// fails because the scheme/destination combination is invalid (e.g., the
    /// macOS-only RemoteDeploy scheme targeted at iOS — the exact reproducer
    /// scenario from TKT-045).
    func test_runXcodebuild_withInvalidDestination_throwsWithStderrInMessage() async throws {
        let engine = XcodeBuildEngine()
        let project = try makeBogusProject(scheme: "RemoteDeploy", platform: "iOS")

        do {
            _ = try await engine.build(project: project)
            XCTFail("Expected build(project:) to throw for an invalid destination")
        } catch let error as BuildError {
            guard case .xcodebuildFailed(let code, let msg) = error else {
                XCTFail("Expected BuildError.xcodebuildFailed, got \(error)")
                return
            }
            XCTAssertNotEqual(code, 0, "Expected a non-zero exit code from xcodebuild")
            let description = error.errorDescription ?? ""
            let lower = (description + "\n" + msg).lowercased()
            // xcodebuild emits "Unable to find a destination matching the
            // provided destination specifier" for this case.
            XCTAssertTrue(
                lower.contains("destination")
                    || lower.contains("unable to find")
                    || lower.contains("platform"),
                "Expected destination-related stderr substring in failure message, got: \(description)"
            )
        } catch {
            XCTFail("Expected BuildError, got \(type(of: error)): \(error)")
        }
    }
}
