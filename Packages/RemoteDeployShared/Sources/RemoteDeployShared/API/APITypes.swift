import Foundation

// MARK: - Pairing

/// Sent by the companion app to complete QR code pairing.
public struct PairRequest: Codable, Sendable {
    /// The raw token from the QR code.
    public var token: String
    /// Human-readable name of the device being paired.
    public var deviceName: String
    /// Optional push endpoint for receiving build notifications.
    public var pushEndpoint: String?

    public init(token: String, deviceName: String, pushEndpoint: String? = nil) {
        self.token = token
        self.deviceName = deviceName
        self.pushEndpoint = pushEndpoint
    }
}

/// Returned after successful pairing.
public struct PairResponse: Codable, Sendable {
    /// The server's display name (e.g., "MacBook Pro").
    public var serverName: String
    /// Confirmation that pairing succeeded.
    public var paired: Bool

    public init(serverName: String, paired: Bool) {
        self.serverName = serverName
        self.paired = paired
    }
}

// MARK: - Status

/// Overall server status snapshot.
public struct ServerStatus: Codable, Sendable {
    /// Whether the HTTPS deploy server is running.
    public var serverRunning: Bool
    /// Whether Tailscale is connected.
    public var tailscaleConnected: Bool
    /// The Tailscale hostname (empty if not connected).
    public var hostname: String
    /// The HTTPS server port.
    public var serverPort: Int
    /// Current build status.
    public var buildStatus: BuildStatusInfo

    public init(serverRunning: Bool, tailscaleConnected: Bool, hostname: String, serverPort: Int, buildStatus: BuildStatusInfo) {
        self.serverRunning = serverRunning
        self.tailscaleConnected = tailscaleConnected
        self.hostname = hostname
        self.serverPort = serverPort
        self.buildStatus = buildStatus
    }
}

/// Lightweight build status for API responses.
public struct BuildStatusInfo: Codable, Sendable {
    /// One of: "idle", "building", "success", "failure".
    public var state: String
    /// Progress message when building, error summary on failure.
    public var message: String?
    /// Project ID currently being built, if any.
    public var projectID: UUID?

    public init(state: String, message: String? = nil, projectID: UUID? = nil) {
        self.state = state
        self.message = message
        self.projectID = projectID
    }
}

// MARK: - Build

/// Request to trigger a build.
public struct BuildRequest: Codable, Sendable {
    /// Build configuration override (e.g., "Debug" or "Release"). Nil uses project default.
    public var configuration: String?

    public init(configuration: String? = nil) {
        self.configuration = configuration
    }
}

// MARK: - Filesystem

/// Response from the filesystem browse endpoint.
public struct FilesystemBrowseResponse: Codable, Sendable {
    /// Current directory path being browsed.
    public var currentPath: String
    /// Parent directory path, nil if at root.
    public var parentPath: String?
    /// Subdirectories in the current path.
    public var directories: [String]
    /// Xcode project files (.xcodeproj) found in the current path.
    public var xcodeProjects: [String]
    /// Xcode workspace files (.xcworkspace) found in the current path.
    public var xcodeWorkspaces: [String]

    public init(currentPath: String, parentPath: String? = nil, directories: [String], xcodeProjects: [String], xcodeWorkspaces: [String]) {
        self.currentPath = currentPath
        self.parentPath = parentPath
        self.directories = directories
        self.xcodeProjects = xcodeProjects
        self.xcodeWorkspaces = xcodeWorkspaces
    }
}

/// Response from the scheme detection endpoint.
public struct SchemesResponse: Codable, Sendable {
    /// Available Xcode schemes for the project at the given path.
    public var schemes: [String]

    public init(schemes: [String]) {
        self.schemes = schemes
    }
}

// MARK: - WebSocket Messages

/// Messages sent over the WebSocket connection.
public struct WSMessage: Codable, Sendable {
    /// Message type: "buildlog", "buildstatus", "install", "subscribe".
    public var type: String
    /// Message payload.
    public var payload: String

    public init(type: String, payload: String) {
        self.type = type
        self.payload = payload
    }
}

// MARK: - Generic API Response

/// Wrapper for API error responses.
public struct APIError: Codable, Sendable {
    /// HTTP status code.
    public var status: Int
    /// Human-readable error message.
    public var message: String

    public init(status: Int, message: String) {
        self.status = status
        self.message = message
    }
}
