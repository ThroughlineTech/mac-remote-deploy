import Foundation

/// Configuration for a single iOS project that can be built and deployed.
/// Stored persistently and displayed in the menu bar project list.
public struct ProjectConfig: Codable, Identifiable, Sendable, Equatable, Hashable {
    /// Unique identifier for this project configuration.
    public var id: UUID

    /// Human-readable project name (e.g., "rejog-ios").
    public var name: String

    /// Absolute path to the directory containing .xcodeproj or .xcworkspace.
    public var projectPath: String

    /// Name of the .xcodeproj file (e.g., "rejog-ios.xcodeproj"). Nil if using workspace.
    public var projectFile: String?

    /// Name of the .xcworkspace file. Nil if using project file directly.
    public var workspaceFile: String?

    /// Xcode scheme to build (e.g., "rejog-ios").
    public var scheme: String

    /// iOS bundle identifier (e.g., "com.example.myapp").
    public var bundleID: String

    /// Apple Developer Team ID (e.g., "ABCDE12345").
    public var teamID: String

    /// Provisioning profile name or UUID. Nil for automatic signing.
    public var provisioningProfile: String?

    /// Build configuration: "Debug" or "Release".
    public var buildConfiguration: String

    /// URL path slug for multi-project serving (e.g., "rejog").
    /// Used to serve at https://hostname:port/rejog/
    public var urlSlug: String

    /// Export method for code signing: "ad-hoc", "development", etc.
    public var exportMethod: String

    /// Target platform: "iOS", "macOS", "tvOS", "watchOS". Defaults to "iOS".
    public var platform: String

    /// The type of project: `.xcode` (native) or `.expo` (React Native).
    /// Determines which build engine is used. Defaults to `.xcode`.
    public var projectType: ProjectType

    /// Relative path from `projectPath` to the Expo app directory within a
    /// monorepo (e.g. `"app"`). Nil for single-app repos or Xcode projects.
    public var expoAppDirectory: String?

    /// Creates a new project config with sensible defaults.
    public init(name: String, projectPath: String) {
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
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
        self.urlSlug = name.lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .unicodeScalars.filter { allowed.contains($0) }
            .map { String($0) }.joined()
        self.exportMethod = "development"
        self.platform = "iOS"
        self.projectType = .xcode
        self.expoAppDirectory = nil
    }

    /// Decodes with backward compatibility — older saved configs without a platform field default to "iOS".
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        projectPath = try container.decode(String.self, forKey: .projectPath)
        projectFile = try container.decodeIfPresent(String.self, forKey: .projectFile)
        workspaceFile = try container.decodeIfPresent(String.self, forKey: .workspaceFile)
        scheme = try container.decode(String.self, forKey: .scheme)
        bundleID = try container.decode(String.self, forKey: .bundleID)
        teamID = try container.decode(String.self, forKey: .teamID)
        provisioningProfile = try container.decodeIfPresent(String.self, forKey: .provisioningProfile)
        buildConfiguration = try container.decode(String.self, forKey: .buildConfiguration)
        urlSlug = try container.decode(String.self, forKey: .urlSlug)
        exportMethod = try container.decode(String.self, forKey: .exportMethod)
        platform = try container.decodeIfPresent(String.self, forKey: .platform) ?? "iOS"
        projectType = try container.decodeIfPresent(ProjectType.self, forKey: .projectType) ?? .xcode
        expoAppDirectory = try container.decodeIfPresent(String.self, forKey: .expoAppDirectory)
    }
}
