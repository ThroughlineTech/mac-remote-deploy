// Protocol for wrapping xcodebuild archive + export operations.
// Implementations handle the full build pipeline: archive → export IPA → copy to serve directory.
import Foundation

/// Represents the current state of a build operation.
/// Equatable for SwiftUI observation; Sendable for safe passage across concurrency boundaries.
enum BuildStatus: Equatable, Sendable {
    case idle
    case building(progress: String)
    case success(ipaPath: String)
    case failure(error: String)
}

protocol BuildEngineProtocol: AnyObject, Sendable {

    /// Runs the full build pipeline for a project: archive with xcodebuild, export the IPA,
    /// and copy it to the server's serve directory.
    ///
    /// - Parameter project: A `ProjectConfig` containing the .xcodeproj/.xcworkspace path,
    ///   scheme name, team ID, and other build settings.
    /// - Returns: The absolute file path to the exported `.ipa` file.
    /// - Throws: If archiving, exporting, or copying the IPA fails for any reason
    ///   (missing scheme, code-sign error, disk full, etc.).
    func build(project: ProjectConfig) async throws -> String

    /// Cancels any in-progress build by terminating the underlying xcodebuild process.
    /// No-op if no build is running.
    func cancelBuild() async

    /// An async stream that emits individual lines of xcodebuild stdout/stderr output
    /// as they arrive. Consumers (e.g. a log view) can iterate this to show real-time
    /// build output.
    var buildLogStream: AsyncStream<String> { get }

    /// The current build status (idle, building, success, or failure).
    /// Implementations should update this as the build progresses so the UI can observe it.
    var status: BuildStatus { get }

    /// Asks xcodebuild to list the schemes available in a project or workspace.
    ///
    /// - Parameter projectPath: Absolute path to a `.xcodeproj` or `.xcworkspace` bundle.
    /// - Returns: An array of scheme name strings found in the project (e.g. ["MyApp", "MyAppTests"]).
    /// - Throws: If xcodebuild fails to parse the project or the path is invalid.
    func detectSchemes(at projectPath: String) async throws -> [String]
}
