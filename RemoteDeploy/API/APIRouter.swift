// Routes incoming /api/v1/ HTTP requests to the appropriate handler.
// Handles authentication, JSON request/response serialization, and
// dispatches to specific route handlers for each resource type.
import Foundation
import NIO
import NIOHTTP1
import os
import RemoteDeployShared

/// Represents a parsed API request with accumulated body data.
struct APIRequest {
    /// The HTTP request head (method, URI, headers).
    var head: HTTPRequestHead
    /// The accumulated request body as raw bytes.
    var body: Data
    /// The authenticated device, if authentication succeeded.
    var device: PairedDevice?

    /// The URL path with query string stripped.
    var path: String {
        head.uri.split(separator: "?").first.map(String.init) ?? head.uri
    }

    /// The HTTP method as a string.
    var method: String {
        head.method.rawValue
    }

    /// Decodes the request body as a JSON object.
    func decodeBody<T: Decodable>(_ type: T.Type) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: body)
    }

    /// Returns query parameters as key-value pairs.
    var queryParameters: [String: String] {
        guard let queryString = head.uri.split(separator: "?", maxSplits: 1).last else {
            return [:]
        }
        var params: [String: String] = [:]
        for pair in queryString.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            if parts.count == 2 {
                let key = String(parts[0]).removingPercentEncoding ?? String(parts[0])
                let value = String(parts[1]).removingPercentEncoding ?? String(parts[1])
                params[key] = value
            }
        }
        return params
    }
}

/// Represents an API response to be sent back to the client.
struct APIResponse {
    /// The HTTP status code.
    var status: HTTPResponseStatus
    /// The response body as raw bytes.
    var body: Data
    /// The Content-Type header value.
    var contentType: String

    /// Creates a JSON response from an encodable value.
    static func json<T: Encodable>(_ value: T, status: HTTPResponseStatus = .ok) -> APIResponse {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = (try? encoder.encode(value)) ?? Data("{}".utf8)
        return APIResponse(status: status, body: data, contentType: "application/json")
    }

    /// Creates an error response with a JSON body.
    static func error(status: HTTPResponseStatus, message: String) -> APIResponse {
        let err = APIError(status: Int(status.code), message: message)
        return json(err, status: status)
    }
}

/// Routes API requests to the appropriate handler.
final class APIRouter: @unchecked Sendable {

    private let auth: AuthMiddleware
    private let pairingHandler: PairingRouteHandler
    private let statusHandler: StatusRouteHandler
    private let projectsHandler: ProjectsRouteHandler
    private let buildHandler: BuildRouteHandler
    private let installsHandler: InstallsRouteHandler
    private let settingsHandler: SettingsRouteHandler
    private let filesystemHandler: FilesystemRouteHandler
    private let devicesHandler: DevicesRouteHandler
    private let tailscaleHandler: TailscaleRouteHandler
    private let ipaHandler: IPAUploadRouteHandler

    /// Creates a new API router with all required dependencies.
    init(
        auth: AuthMiddleware,
        pairingHandler: PairingRouteHandler,
        statusHandler: StatusRouteHandler,
        projectsHandler: ProjectsRouteHandler,
        buildHandler: BuildRouteHandler,
        installsHandler: InstallsRouteHandler,
        settingsHandler: SettingsRouteHandler,
        filesystemHandler: FilesystemRouteHandler,
        devicesHandler: DevicesRouteHandler,
        tailscaleHandler: TailscaleRouteHandler,
        ipaHandler: IPAUploadRouteHandler
    ) {
        self.auth = auth
        self.pairingHandler = pairingHandler
        self.statusHandler = statusHandler
        self.projectsHandler = projectsHandler
        self.buildHandler = buildHandler
        self.installsHandler = installsHandler
        self.settingsHandler = settingsHandler
        self.filesystemHandler = filesystemHandler
        self.devicesHandler = devicesHandler
        self.tailscaleHandler = tailscaleHandler
        self.ipaHandler = ipaHandler
    }

    /// Returns true if this path should be handled by the API router.
    func shouldHandle(path: String) -> Bool {
        path.hasPrefix("/api/")
    }

    /// Routes an API request and returns the response.
    ///
    /// - Parameter request: The parsed API request with accumulated body.
    /// - Returns: The API response to send back to the client.
    func handle(_ request: APIRequest) -> APIResponse {
        let path = request.path
        let method = request.method

        // Pairing endpoint is unauthenticated
        if path == "/api/v1/pair" {
            if method == "POST" {
                return pairingHandler.pair(request)
            } else if method == "DELETE" {
                // Unpair requires auth
                guard let authedRequest = authenticate(request) else {
                    Logger.pairing.warning("Auth failed for \(method, privacy: .public) \(path, privacy: .private)")
                    return .error(status: .unauthorized, message: "Invalid or missing bearer token")
                }
                return pairingHandler.unpair(authedRequest)
            }
            return .error(status: .methodNotAllowed, message: "Method not allowed")
        }

        // All other endpoints require authentication
        guard let authedRequest = authenticate(request) else {
            Logger.pairing.warning("Auth failed for \(method, privacy: .public) \(path, privacy: .private)")
            return .error(status: .unauthorized, message: "Invalid or missing bearer token")
        }

        // Pairing: mint a one-time token for another device (auth required).
        // Note: bare "/api/v1/pair" is handled unauthenticated above; this is a
        // distinct sub-path, so it falls through to here. TKT-060 (Phase 6).
        if path == "/api/v1/pair/pending" {
            if method == "POST" { return pairingHandler.mintPending(authedRequest) }
            return .error(status: .methodNotAllowed, message: "Method not allowed")
        }

        // Status
        if path == "/api/v1/status" && method == "GET" {
            return statusHandler.getStatus(authedRequest)
        }

        // Tailscale certificate provisioning. TKT-060 (Phase 6).
        if path == "/api/v1/tailscale/cert" {
            if method == "POST" { return tailscaleHandler.provisionCertificate(authedRequest) }
            if method == "GET" { return tailscaleHandler.certificateStatus(authedRequest) }
            return .error(status: .methodNotAllowed, message: "Method not allowed")
        }

        // Projects
        if path == "/api/v1/projects" {
            if method == "GET" { return projectsHandler.list(authedRequest) }
            if method == "POST" { return projectsHandler.create(authedRequest) }
            return .error(status: .methodNotAllowed, message: "Method not allowed")
        }

        if path.hasPrefix("/api/v1/projects/") {
            let remaining = String(path.dropFirst("/api/v1/projects/".count))
            let parts = remaining.split(separator: "/", maxSplits: 1)
            guard let idString = parts.first, let projectID = UUID(uuidString: String(idString)) else {
                return .error(status: .badRequest, message: "Invalid project ID")
            }

            // /api/v1/projects/:id/build
            if parts.count > 1 && parts[1] == "build" {
                if method == "POST" { return buildHandler.triggerBuild(authedRequest, projectID: projectID) }
                if method == "GET" { return buildHandler.getBuildStatus(authedRequest, projectID: projectID) }
                if method == "DELETE" { return buildHandler.cancelBuild(authedRequest, projectID: projectID) }
                return .error(status: .methodNotAllowed, message: "Method not allowed")
            }

            // /api/v1/projects/:id/ipa — upload a prebuilt IPA. TKT-060 (Phase 6).
            if parts.count > 1 && parts[1] == "ipa" {
                if method == "POST" { return ipaHandler.upload(authedRequest, projectID: projectID) }
                return .error(status: .methodNotAllowed, message: "Method not allowed")
            }

            // /api/v1/projects/:id
            if parts.count == 1 {
                if method == "GET" { return projectsHandler.get(authedRequest, projectID: projectID) }
                if method == "PUT" { return projectsHandler.update(authedRequest, projectID: projectID) }
                if method == "DELETE" { return projectsHandler.delete(authedRequest, projectID: projectID) }
                return .error(status: .methodNotAllowed, message: "Method not allowed")
            }
        }

        // Builds history
        if path == "/api/v1/builds" && method == "GET" {
            return buildHandler.getBuildHistory(authedRequest)
        }

        // Installs
        if path == "/api/v1/installs" {
            if method == "GET" { return installsHandler.list(authedRequest) }
            if method == "DELETE" { return installsHandler.deleteAll(authedRequest) }
            return .error(status: .methodNotAllowed, message: "Method not allowed")
        }

        if path.hasPrefix("/api/v1/installs/") && method == "DELETE" {
            let idString = String(path.dropFirst("/api/v1/installs/".count))
            guard let installID = UUID(uuidString: idString) else {
                return .error(status: .badRequest, message: "Invalid install ID")
            }
            return installsHandler.delete(authedRequest, installID: installID)
        }

        // Settings
        if path == "/api/v1/settings" {
            if method == "GET" { return settingsHandler.get(authedRequest) }
            if method == "PUT" { return settingsHandler.update(authedRequest) }
            return .error(status: .methodNotAllowed, message: "Method not allowed")
        }

        // Filesystem
        if path == "/api/v1/filesystem/browse" && method == "GET" {
            return filesystemHandler.browse(authedRequest)
        }
        if path == "/api/v1/filesystem/schemes" && method == "GET" {
            return filesystemHandler.detectSchemes(authedRequest)
        }

        // Devices
        if path == "/api/v1/devices" && method == "GET" {
            return devicesHandler.list(authedRequest)
        }
        if path.hasPrefix("/api/v1/devices/") && method == "DELETE" {
            let idString = String(path.dropFirst("/api/v1/devices/".count))
            guard let deviceID = UUID(uuidString: idString) else {
                return .error(status: .badRequest, message: "Invalid device ID")
            }
            return devicesHandler.revoke(authedRequest, deviceID: deviceID)
        }

        return .error(status: .notFound, message: "API endpoint not found")
    }

    /// Authenticates a request by extracting and validating the bearer token.
    private func authenticate(_ request: APIRequest) -> APIRequest? {
        let headers = request.head.headers.map { ($0.name, $0.value) }
        guard let device = auth.authenticate(headers: headers) else {
            return nil
        }
        var authed = request
        authed.device = device
        return authed
    }
}
