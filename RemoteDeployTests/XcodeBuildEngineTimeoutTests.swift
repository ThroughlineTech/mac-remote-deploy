// Tests for the build watchdog timeout added in TKT-075.
//
// -allowProvisioningUpdates (on by default since TKT-072) makes xcodebuild block
// on a network round-trip to Apple to mint a managed profile. With an invalid
// team it does not fail fast -- it hangs, pinning the build to "building" forever.
// XcodeBuildEngine now arms a per-invocation watchdog that terminates xcodebuild
// once it runs past a configurable timeout and surfaces BuildError.timedOut.
//
// These tests drive a real `xcodebuild` against this repo's own .xcodeproj. The
// timeout test injects a tiny timeout so the watchdog fires during xcodebuild's
// "load and validate the project" phase (empirically 1-3s; see
// XcodeBuildEngineFailureTests) -- the process is killed within a fraction of a
// second, so no meaningful compilation starts.
@testable import RemoteDeployServer
import RemoteDeployShared
import XCTest
import Foundation

final class XcodeBuildEngineTimeoutTests: XCTestCase {

    /// Locates this repo's RemoteDeploy.xcodeproj relative to this test file so
    /// the test is robust against the runner's working directory. Walks up from
    /// `#filePath` until it finds the directory containing the .xcodeproj.
    private func locateRepoXcodeproj(file: StaticString = #filePath) throws -> String {
        let testFile = URL(fileURLWithPath: "\(file)")
        var dir = testFile.deletingLastPathComponent()
        let fm = FileManager.default
        for _ in 0..<6 {
            let candidate = dir.appendingPathComponent("RemoteDeploy.xcodeproj").path
            if fm.fileExists(atPath: candidate) {
                return candidate
            }
            dir = dir.deletingLastPathComponent()
        }
        throw XCTSkip("Could not find RemoteDeploy.xcodeproj relative to \(file)")
    }

    /// A `ProjectConfig` pointing at this repo's xcodeproj. `-allowProvisioningUpdates`
    /// is disabled so the build path stays offline and deterministic; the watchdog
    /// is what we're exercising, not Apple's signing service.
    private func makeRepoProject(scheme: String, platform: String) throws -> ProjectConfig {
        let xcodeprojPath = try locateRepoXcodeproj()
        var project = ProjectConfig(name: "TKT075-Test", projectPath: xcodeprojPath)
        project.scheme = scheme
        project.platform = platform
        project.teamID = "ZZZZZZZZZZ"
        project.buildConfiguration = "Debug"
        project.exportMethod = "development"
        project.allowProvisioningUpdates = false
        return project
    }

    /// With a tiny timeout, the watchdog terminates xcodebuild before it can
    /// finish (here it's still validating the project), and `build(project:)`
    /// throws `BuildError.timedOut` rather than hanging or reporting a build error.
    /// Uses the repo's valid macOS scheme so xcodebuild would otherwise run for
    /// minutes -- guaranteeing the timeout wins regardless of machine speed.
    func test_build_exceedingTimeout_throwsTimedOut() async throws {
        let engine = XcodeBuildEngine(timeout: 0.5)
        let project = try makeRepoProject(scheme: "RemoteDeploy", platform: "macOS")

        do {
            _ = try await engine.build(project: project)
            XCTFail("Expected build(project:) to time out and throw")
        } catch let error as BuildError {
            guard case .timedOut(let seconds) = error else {
                XCTFail("Expected BuildError.timedOut, got \(error)")
                return
            }
            XCTAssertEqual(seconds, 0.5, accuracy: 0.0001)
            XCTAssertTrue(
                (error.errorDescription ?? "").lowercased().contains("timed out"),
                "Expected a 'timed out' description, got: \(error.errorDescription ?? "")"
            )
            // The watchdog set the engine's terminal status to a timeout failure.
            if case .failure(let msg) = engine.status {
                XCTAssertTrue(msg.lowercased().contains("timed out"),
                              "Expected timeout failure status, got: \(msg)")
            } else {
                XCTFail("Expected .failure status after a timeout, got \(engine.status)")
            }
        } catch {
            XCTFail("Expected BuildError, got \(type(of: error)): \(error)")
        }
    }

    /// A generous timeout must NOT misfire: a build that fails on its own (invalid
    /// scheme, ~1-3s) before the timeout should surface `BuildError.xcodebuildFailed`,
    /// proving the watchdog is cancelled when the process exits normally rather
    /// than spuriously reporting a timeout.
    func test_build_failingBeforeTimeout_throwsXcodebuildFailedNotTimedOut() async throws {
        let engine = XcodeBuildEngine(timeout: 30)
        let project = try makeRepoProject(scheme: "DoesNotExistScheme", platform: "macOS")

        do {
            _ = try await engine.build(project: project)
            XCTFail("Expected build(project:) to throw for an invalid scheme")
        } catch let error as BuildError {
            if case .timedOut = error {
                XCTFail("Watchdog misfired: build failed fast but was reported as a timeout")
                return
            }
            guard case .xcodebuildFailed(let code, _) = error else {
                XCTFail("Expected BuildError.xcodebuildFailed, got \(error)")
                return
            }
            XCTAssertNotEqual(code, 0, "Expected a non-zero exit code from xcodebuild")
        } catch {
            XCTFail("Expected BuildError, got \(type(of: error)): \(error)")
        }
    }

    /// The thrown error's description reports the timeout in whole seconds.
    func test_timedOutError_descriptionIncludesSeconds() {
        let error = BuildError.timedOut(1200)
        XCTAssertEqual(error.errorDescription, "Build timed out after 1200s.")
    }
}
