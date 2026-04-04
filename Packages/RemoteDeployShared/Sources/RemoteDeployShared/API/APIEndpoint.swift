import Foundation

/// All REST API endpoints, shared between Mac server and iOS client.
/// Each case defines the HTTP method, path, and whether authentication is required.
public enum APIEndpoint {
    // Authentication
    case pair
    case unpair

    // Status
    case status

    // Projects
    case listProjects
    case createProject
    case getProject(UUID)
    case updateProject(UUID)
    case deleteProject(UUID)

    // Builds
    case triggerBuild(UUID)
    case buildStatus(UUID)
    case cancelBuild(UUID)
    case buildHistory

    // Installs
    case installHistory

    // Settings
    case getSettings
    case updateSettings

    // Filesystem browsing
    case browseFilesystem
    case detectSchemes

    // Paired devices
    case listDevices
    case revokeDevice(UUID)

    // WebSocket
    case webSocket

    /// The URL path for this endpoint.
    public var path: String {
        switch self {
        case .pair: "/api/v1/pair"
        case .unpair: "/api/v1/pair"
        case .status: "/api/v1/status"
        case .listProjects, .createProject: "/api/v1/projects"
        case .getProject(let id), .updateProject(let id), .deleteProject(let id):
            "/api/v1/projects/\(id.uuidString)"
        case .triggerBuild(let id), .buildStatus(let id), .cancelBuild(let id):
            "/api/v1/projects/\(id.uuidString)/build"
        case .buildHistory: "/api/v1/builds"
        case .installHistory: "/api/v1/installs"
        case .getSettings, .updateSettings: "/api/v1/settings"
        case .browseFilesystem: "/api/v1/filesystem/browse"
        case .detectSchemes: "/api/v1/filesystem/schemes"
        case .listDevices: "/api/v1/devices"
        case .revokeDevice(let id): "/api/v1/devices/\(id.uuidString)"
        case .webSocket: "/api/v1/ws"
        }
    }

    /// The HTTP method for this endpoint.
    public var method: String {
        switch self {
        case .pair, .createProject, .triggerBuild:
            "POST"
        case .unpair, .deleteProject, .cancelBuild, .revokeDevice:
            "DELETE"
        case .updateProject, .updateSettings:
            "PUT"
        default:
            "GET"
        }
    }

    /// Whether this endpoint requires a valid bearer token.
    public var requiresAuth: Bool {
        switch self {
        case .pair: false
        default: true
        }
    }
}
