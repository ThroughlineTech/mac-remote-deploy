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
    /// Stable per-install identifier for the device being paired. Lets the Mac tell
    /// a reinstall of THIS device apart from a genuinely different device when
    /// deciding whether to collapse duplicate records. Optional: browser/PWA clients
    /// and older companion builds omit it (and are then never auto-deduplicated).
    public var installID: String?

    public init(token: String, deviceName: String, pushEndpoint: String? = nil, installID: String? = nil) {
        self.token = token
        self.deviceName = deviceName
        self.pushEndpoint = pushEndpoint
        self.installID = installID
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

/// Returned when an authenticated client (e.g. the menu bar) mints a one-time
/// pairing token on the server for another device (a browser or the iOS app)
/// to claim via POST /api/v1/pair. TKT-060 (Phase 6): replaces the menu bar's
/// in-process `pairingHandler.registerPendingToken` call so the menu bar can be
/// a pure client process.
public struct PendingPairingResponse: Codable, Sendable {
    /// The raw one-time token the new device submits to POST /api/v1/pair.
    public var token: String
    /// Seconds until the pending token expires.
    public var expiresInSeconds: Int

    public init(token: String, expiresInSeconds: Int) {
        self.token = token
        self.expiresInSeconds = expiresInSeconds
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

// MARK: - Certificate provisioning

/// State of server-side Tailscale TLS certificate provisioning. TKT-060
/// (Phase 6): the server owns `tailscale cert`; clients POST to start it and
/// poll this state, replacing the menu bar's in-process cert generation.
public struct CertProvisioningState: Codable, Sendable {
    /// True while `tailscale cert` is running in the background.
    public var inProgress: Bool
    /// True once cert + key paths are configured on disk (HTTPS can bind).
    public var certConfigured: Bool
    /// Error message from the most recent provisioning attempt, if it failed.
    public var lastError: String?

    public init(inProgress: Bool, certConfigured: Bool, lastError: String? = nil) {
        self.inProgress = inProgress
        self.certConfigured = certConfigured
        self.lastError = lastError
    }
}

// MARK: - IPA upload

/// Returned after a prebuilt .ipa is uploaded and copied into the serve
/// directory. TKT-060 (Phase 6): replaces the menu bar's in-process IPA import
/// so the menu bar can upload over the API instead of writing the serve dir.
public struct IPAUploadResponse: Codable, Sendable {
    /// The app's CFBundleIdentifier read from the IPA.
    public var bundleID: String
    /// The app's CFBundleShortVersionString.
    public var version: String
    /// The app's CFBundleVersion build number.
    public var buildNumber: String
    /// The project URL slug the IPA was served under.
    public var slug: String

    public init(bundleID: String, version: String, buildNumber: String, slug: String) {
        self.bundleID = bundleID
        self.version = version
        self.buildNumber = buildNumber
        self.slug = slug
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
