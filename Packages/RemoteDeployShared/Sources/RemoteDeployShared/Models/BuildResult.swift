import Foundation

/// Represents the outcome of a single project build attempt.
/// Created after each build completes (successfully or not) and stored for history.
public struct BuildResult: Codable, Identifiable, Sendable, Equatable {
    /// Unique identifier for this build result.
    public var id: UUID

    /// The project configuration ID that was built.
    public var projectID: UUID

    /// Whether the build and archive succeeded without errors.
    public var success: Bool

    /// Absolute path to the exported .ipa file. Nil if the build failed.
    public var ipaPath: String?

    /// Short human-readable error description. Nil if the build succeeded.
    public var errorSummary: String?

    /// Full xcodebuild log output captured during the build.
    public var buildLog: String

    /// Timestamp when the build process started.
    public var startTime: Date

    /// Timestamp when the build process finished.
    public var endTime: Date

    /// Marketing version string from the built app (e.g., "1.2.0"). Nil if unavailable.
    public var version: String?

    /// Build number string from the built app (e.g., "42"). Nil if unavailable.
    public var buildNumber: String?

    /// Elapsed wall-clock time of the build in seconds.
    public var duration: TimeInterval {
        endTime.timeIntervalSince(startTime)
    }

    public init(id: UUID = UUID(), projectID: UUID, success: Bool, ipaPath: String? = nil, errorSummary: String? = nil, buildLog: String, startTime: Date, endTime: Date, version: String? = nil, buildNumber: String? = nil) {
        self.id = id
        self.projectID = projectID
        self.success = success
        self.ipaPath = ipaPath
        self.errorSummary = errorSummary
        self.buildLog = buildLog
        self.startTime = startTime
        self.endTime = endTime
        self.version = version
        self.buildNumber = buildNumber
    }
}
