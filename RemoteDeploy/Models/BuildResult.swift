import Foundation

/// Represents the outcome of a single project build attempt.
/// Created after each build completes (successfully or not) and stored for history.
struct BuildResult: Codable, Identifiable, Sendable {
    /// Unique identifier for this build result.
    var id: UUID

    /// The project configuration ID that was built.
    var projectID: UUID

    /// Whether the build and archive succeeded without errors.
    var success: Bool

    /// Absolute path to the exported .ipa file. Nil if the build failed.
    var ipaPath: String?

    /// Short human-readable error description. Nil if the build succeeded.
    var errorSummary: String?

    /// Full xcodebuild log output captured during the build.
    var buildLog: String

    /// Timestamp when the build process started.
    var startTime: Date

    /// Timestamp when the build process finished.
    var endTime: Date

    /// Marketing version string from the built app (e.g., "1.2.0"). Nil if unavailable.
    var version: String?

    /// Build number string from the built app (e.g., "42"). Nil if unavailable.
    var buildNumber: String?

    /// Elapsed wall-clock time of the build in seconds.
    var duration: TimeInterval {
        endTime.timeIntervalSince(startTime)
    }
}
