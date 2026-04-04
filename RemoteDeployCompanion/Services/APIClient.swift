// Async/await HTTP client for communicating with the RemoteDeploy Mac server API.
// All methods map to /api/v1/ endpoints and handle JSON serialization.
import Foundation
import RemoteDeployShared

/// HTTP client for the RemoteDeploy API.
final class APIClient: @unchecked Sendable {

    /// The base URL of the Mac server (e.g., "https://macbook.tail1234.ts.net:8443").
    let baseURL: URL

    /// The bearer token for API authentication.
    let token: String

    /// URLSession with a delegate that accepts Tailscale TLS certificates.
    private let session: URLSession

    /// Delegate that accepts TLS certificates (Tailscale certs are valid but the
    /// phone may not be able to verify them without Tailscale's DNS resolver).
    private let sessionDelegate = TrustingSessionDelegate()

    /// Creates a new API client.
    ///
    /// - Parameter baseURL: The server's base URL.
    /// - Parameter token: The bearer token from QR pairing.
    init(baseURL: URL, token: String) {
        self.baseURL = baseURL
        self.token = token
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: config, delegate: sessionDelegate, delegateQueue: nil)
    }

    // MARK: - Status

    /// Fetches the current server status.
    func getStatus() async throws -> ServerStatus {
        try await get("/api/v1/status")
    }

    // MARK: - Projects

    /// Lists all configured projects.
    func listProjects() async throws -> [ProjectConfig] {
        try await get("/api/v1/projects")
    }

    /// Gets a single project by ID.
    func getProject(_ id: UUID) async throws -> ProjectConfig {
        try await get("/api/v1/projects/\(id.uuidString)")
    }

    /// Creates a new project.
    func createProject(_ project: ProjectConfig) async throws -> ProjectConfig {
        try await post("/api/v1/projects", body: project)
    }

    /// Updates an existing project.
    func updateProject(_ project: ProjectConfig) async throws -> ProjectConfig {
        try await put("/api/v1/projects/\(project.id.uuidString)", body: project)
    }

    /// Deletes a project.
    func deleteProject(_ id: UUID) async throws {
        let _: [String: Bool] = try await delete("/api/v1/projects/\(id.uuidString)")
    }

    // MARK: - Builds

    /// Triggers a build for the given project.
    func triggerBuild(projectID: UUID, configuration: String? = nil) async throws -> BuildStatusInfo {
        let request = BuildRequest(configuration: configuration)
        return try await post("/api/v1/projects/\(projectID.uuidString)/build", body: request)
    }

    /// Gets the current build status for a project.
    func getBuildStatus(projectID: UUID) async throws -> BuildStatusInfo {
        try await get("/api/v1/projects/\(projectID.uuidString)/build")
    }

    /// Cancels the current build.
    func cancelBuild(projectID: UUID) async throws {
        let _: [String: Bool] = try await delete("/api/v1/projects/\(projectID.uuidString)/build")
    }

    /// Gets build history.
    func getBuildHistory() async throws -> [BuildResult] {
        try await get("/api/v1/builds")
    }

    // MARK: - Installs

    /// Gets recent install records.
    func getInstalls(limit: Int = 50) async throws -> [InstallRecord] {
        try await get("/api/v1/installs?limit=\(limit)")
    }

    // MARK: - Settings

    /// Gets the current server settings.
    func getSettings() async throws -> SettingsData {
        try await get("/api/v1/settings")
    }

    /// Updates server settings.
    func updateSettings(_ settings: SettingsData) async throws -> SettingsData {
        try await put("/api/v1/settings", body: settings)
    }

    // MARK: - Filesystem

    /// Browses a directory on the Mac.
    func browseFilesystem(path: String? = nil) async throws -> FilesystemBrowseResponse {
        let encoded = path?.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let query = path != nil ? "?path=\(encoded)" : ""
        return try await get("/api/v1/filesystem/browse\(query)")
    }

    /// Detects Xcode schemes at a path.
    func detectSchemes(path: String) async throws -> SchemesResponse {
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? path
        return try await get("/api/v1/filesystem/schemes?path=\(encoded)")
    }

    // MARK: - Devices

    /// Lists paired devices.
    func listDevices() async throws -> [PairedDevice] {
        try await get("/api/v1/devices")
    }

    // MARK: - Pairing

    /// Completes pairing with the server.
    func completePairing(deviceName: String) async throws -> PairResponse {
        let request = PairRequest(token: token, deviceName: deviceName)
        return try await post("/api/v1/pair", body: request, authenticated: false)
    }

    // MARK: - Private HTTP Methods

    /// Builds a URL by appending the path to the base URL string.
    /// Uses string concatenation instead of appendingPathComponent to avoid
    /// double-encoding issues with URL path components.
    private func buildURL(_ path: String) -> URL {
        let base = baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let cleanPath = path.hasPrefix("/") ? path : "/\(path)"
        return URL(string: base + cleanPath)!
    }

    private func get<T: Decodable>(_ path: String) async throws -> T {
        var request = URLRequest(url: buildURL(path))
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return try await execute(request)
    }

    private func post<B: Encodable, T: Decodable>(_ path: String, body: B, authenticated: Bool = true) async throws -> T {
        var request = URLRequest(url: buildURL(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if authenticated {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONEncoder().encode(body)
        return try await execute(request)
    }

    private func put<B: Encodable, T: Decodable>(_ path: String, body: B) async throws -> T {
        var request = URLRequest(url: buildURL(path))
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(body)
        return try await execute(request)
    }

    private func delete<T: Decodable>(_ path: String) async throws -> T {
        var request = URLRequest(url: buildURL(path))
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return try await execute(request)
    }

    private func execute<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIClientError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let errorBody = try? JSONDecoder().decode(APIError.self, from: data)
            throw APIClientError.httpError(httpResponse.statusCode, errorBody?.message ?? "Unknown error")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(T.self, from: data)
    }
}

/// URLSession delegate that accepts TLS certificates from the RemoteDeploy server.
/// Tailscale issues valid Let's Encrypt certs, but the phone may not be able to
/// verify them if it's not using Tailscale's DNS. This delegate trusts the server
/// for development use.
final class TrustingSessionDelegate: NSObject, URLSessionDelegate {
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            return (.performDefaultHandling, nil)
        }
        return (.useCredential, URLCredential(trust: trust))
    }
}

/// Errors from the API client.
enum APIClientError: LocalizedError {
    case invalidResponse
    case httpError(Int, String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: "Invalid server response"
        case .httpError(let code, let message): "HTTP \(code): \(message)"
        }
    }
}
