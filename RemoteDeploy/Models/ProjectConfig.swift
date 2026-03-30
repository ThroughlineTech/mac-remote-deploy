import Foundation

/// Configuration for a single iOS project that can be built and deployed.
/// Stored persistently and displayed in the menu bar project list.
struct ProjectConfig: Codable, Identifiable, Sendable, Equatable {
    /// Unique identifier for this project configuration.
    var id: UUID

    /// Human-readable project name (e.g., "rejog-ios").
    var name: String

    /// Absolute path to the directory containing .xcodeproj or .xcworkspace.
    var projectPath: String

    /// Name of the .xcodeproj file (e.g., "rejog-ios.xcodeproj"). Nil if using workspace.
    var projectFile: String?

    /// Name of the .xcworkspace file. Nil if using project file directly.
    var workspaceFile: String?

    /// Xcode scheme to build (e.g., "rejog-ios").
    var scheme: String

    /// iOS bundle identifier (e.g., "net.rejog.voicememo").
    var bundleID: String

    /// Apple Developer Team ID (e.g., "RDJQ523WP4").
    var teamID: String

    /// Provisioning profile name or UUID. Nil for automatic signing.
    var provisioningProfile: String?

    /// Build configuration: "Debug" or "Release".
    var buildConfiguration: String

    /// URL path slug for multi-project serving (e.g., "rejog").
    /// Used to serve at https://hostname:port/rejog/
    var urlSlug: String

    /// Export method for code signing: "ad-hoc", "development", etc.
    var exportMethod: String

    /// Creates a new project config with sensible defaults.
    init(name: String, projectPath: String) {
        self.id = UUID()
        self.name = name
        self.projectPath = projectPath
        self.projectFile = nil
        self.workspaceFile = nil
        self.scheme = ""
        self.bundleID = ""
        self.teamID = ""
        self.provisioningProfile = nil
        self.buildConfiguration = "Release"
        self.urlSlug = name.lowercased().replacingOccurrences(of: " ", with: "-")
        self.exportMethod = "ad-hoc"
    }
}
