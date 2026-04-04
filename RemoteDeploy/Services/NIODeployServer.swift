// Concrete implementation of DeployServerProtocol using SwiftNIO + NIOSSL.
// Serves HTTPS install pages, OTA manifests, and IPA files for over-the-air iOS deployment.
// Each project is served under its own URL slug: /<slug>/, /<slug>/manifest.plist, /<slug>/app.ipa.
import Foundation
import NIO
import NIOHTTP1
import NIOWebSocket
@preconcurrency import NIOSSL
import NIOFoundationCompat
import os

final class NIODeployServer: DeployServerProtocol, @unchecked Sendable {

    // MARK: - Private State

    /// Grouped server lifecycle state protected by a single lock.
    private struct ServerState {
        var group: MultiThreadedEventLoopGroup?
        var serverChannel: Channel?
        var httpChannel: Channel?
        var isRunning = false
        var port: Int = 8443
        var httpPort: Int = 8080
    }

    /// Lock protecting server lifecycle state.
    private let lockedState = OSAllocatedUnfairLock(initialState: ServerState())

    /// The registered project configurations, keyed by URL slug. Protected by lock.
    private let lockedProjectsBySlug = OSAllocatedUnfairLock<[String: ProjectConfig]>(initialState: [:])

    /// Generator for OTA manifest.plist responses.
    fileprivate let manifestGenerator: ManifestGenerating

    /// Generator for HTML install page responses.
    fileprivate let installPageGenerator: InstallPageGenerating

    /// The base HTTPS URL (e.g. "https://macbook.tail1234.ts.net:8443") used to construct
    /// absolute URLs in manifests and install pages. Protected by lock.
    private let lockedBaseURL = OSAllocatedUnfairLock<String>(initialState: "")

    /// Callback invoked when an IPA is downloaded. Arguments: (projectSlug, sourceIP, userAgent).
    var onIPADownload: ((String, String, String) -> Void)?

    /// Optional API router for handling /api/v1/ endpoints from companion devices.
    /// Set this before calling `start` to enable the REST API.
    var apiRouter: APIRouter?

    /// WebSocket manager for live build log and status streaming.
    let webSocketManager = WebSocketManager()

    /// The plain HTTP port for local WiFi API access (no TLS).
    var httpPort: Int {
        lockedState.withLock { $0.httpPort }
    }

    // MARK: - Protocol Properties

    /// Whether the server is currently listening for connections.
    var isRunning: Bool {
        lockedState.withLock { $0.isRunning }
    }

    /// The TCP port the server is currently configured to use.
    var port: Int {
        lockedState.withLock { $0.port }
    }

    /// Delegate that receives callbacks when IPA files are downloaded.
    /// Set this before calling `start` to receive install-tracking events.
    weak var delegate: DeployServerDelegate?

    /// The root directory where per-project serve directories live.
    /// Each project's IPA is at `<serveRoot>/<slug>/app.ipa`.
    let serveRoot: String

    // MARK: - Init

    /// Creates a new NIODeployServer.
    ///
    /// - Parameter manifestGenerator: The object used to generate OTA manifest plist XML.
    /// - Parameter installPageGenerator: The object used to generate HTML install pages.
    /// - Parameter serveRoot: The root directory containing per-slug subdirectories with IPA files.
    ///   Defaults to `~/Library/Application Support/RemoteDeploy/serve/`.
    init(
        manifestGenerator: ManifestGenerating,
        installPageGenerator: InstallPageGenerating,
        serveRoot: String? = nil
    ) {
        self.manifestGenerator = manifestGenerator
        self.installPageGenerator = installPageGenerator

        if let root = serveRoot {
            self.serveRoot = root
        } else {
            let appSupport = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first!.path
            self.serveRoot = "\(appSupport)/RemoteDeploy/serve"
        }
    }

    // MARK: - Project Registration

    /// Registers a project configuration so the server knows which URL slugs are valid.
    ///
    /// Call this for each project before or after starting the server. The slug from
    /// `project.urlSlug` becomes a valid route prefix (e.g. `/<slug>/`).
    ///
    /// - Parameter project: The project configuration to register.
    func registerProject(_ project: ProjectConfig) {
        lockedProjectsBySlug.withLock { $0[project.urlSlug] = project }
    }

    /// Removes a project configuration so its routes are no longer served.
    ///
    /// - Parameter slug: The URL slug of the project to unregister.
    func unregisterProject(slug: String) {
        lockedProjectsBySlug.withLock { _ = $0.removeValue(forKey: slug) }
    }

    /// Updates the base URL used when generating absolute URLs in manifests and install pages.
    ///
    /// This should be called whenever the hostname or port changes (e.g. when the Tailscale
    /// IP is resolved). Example: "https://macbook.tail1234.ts.net:8443".
    ///
    /// - Parameter url: The base HTTPS URL (no trailing slash).
    func setBaseURL(_ url: String) {
        lockedBaseURL.withLock { $0 = url }
    }

    // MARK: - Server Lifecycle

    /// Starts the HTTPS server, binding to the given port with the provided TLS certificate.
    ///
    /// This method configures a SwiftNIO `ServerBootstrap` with NIOSSL for TLS termination,
    /// sets up the HTTP/1.1 pipeline, and installs the `HTTPHandler` to route requests.
    /// The server listens on all interfaces (0.0.0.0) so it is reachable from the tailnet.
    ///
    /// - Parameter port: The TCP port to listen on (e.g. 8443).
    /// - Parameter certPath: Absolute path to the PEM-encoded TLS certificate file.
    /// - Parameter keyPath: Absolute path to the PEM-encoded TLS private key file.
    /// - Throws: If the port is already in use, the cert/key files are invalid or unreadable,
    ///   or the server otherwise fails to bind.
    func start(port: Int, certPath: String, keyPath: String) async throws {
        let alreadyRunning = lockedState.withLock { state -> Bool in
            if state.isRunning { return true }
            state.port = port
            return false
        }
        guard !alreadyRunning else { return }

        // -- TLS Configuration --
        let cert = try NIOSSLCertificate.fromPEMFile(certPath)
        let privateKey = try NIOSSLPrivateKey(file: keyPath, format: .pem)

        var tlsConfig = TLSConfiguration.makeServerConfiguration(
            certificateChain: cert.map { .certificate($0) },
            privateKey: .privateKey(privateKey)
        )
        tlsConfig.minimumTLSVersion = .tlsv12

        let sslContext = try NIOSSLContext(configuration: tlsConfig)

        // -- Bootstrap --
        let group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)

        let handler = HTTPHandler(server: self)
        handler.apiRouter = self.apiRouter

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(.backlog, value: 256)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                let sslHandler = NIOSSLServerHandler(context: sslContext)
                return channel.pipeline.addHandler(sslHandler as RemovableChannelHandler).flatMap {
                    channel.pipeline.configureHTTPServerPipeline().flatMap {
                        channel.pipeline.addHandler(handler)
                    }
                }
            }
            .childChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(.maxMessagesPerRead, value: 1)

        let channel = try await bootstrap.bind(host: "0.0.0.0", port: port).get()

        // -- Secondary plain-HTTP listener for local WiFi API access --
        let httpHandler = HTTPHandler(server: self)
        httpHandler.apiRouter = self.apiRouter

        let httpBootstrap = ServerBootstrap(group: group)
            .serverChannelOption(.backlog, value: 256)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                // No TLS — plain HTTP for local WiFi
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(httpHandler)
                }
            }
            .childChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(.maxMessagesPerRead, value: 1)

        let httpChannel = try? await httpBootstrap.bind(host: "0.0.0.0", port: 8080).get()

        lockedState.withLock { state in
            state.serverChannel = channel
            state.httpChannel = httpChannel
            state.group = group
            state.isRunning = true
        }
    }

    /// Stops both the HTTPS and HTTP servers and releases listening sockets.
    /// Shuts down the event loop group gracefully. No-op if the server is not running.
    func stop() async {
        let (channel, httpCh, group) = lockedState.withLock { state -> (Channel?, Channel?, MultiThreadedEventLoopGroup?) in
            guard state.isRunning else { return (nil, nil, nil) }
            let ch = state.serverChannel
            let http = state.httpChannel
            let gr = state.group
            state.serverChannel = nil
            state.httpChannel = nil
            state.isRunning = false
            return (ch, http, gr)
        }

        guard channel != nil || httpCh != nil || group != nil else { return }

        try? await channel?.close().get()
        try? await httpCh?.close().get()
        try? await group?.shutdownGracefully()

        lockedState.withLock { $0.group = nil }
    }

    // MARK: - Internal Accessors (used by HTTPHandler)

    /// Returns a snapshot of all registered project configs.
    /// Called by the HTTP handler to build the index page and validate routes.
    func registeredProjects() -> [String: ProjectConfig] {
        lockedProjectsBySlug.withLock { $0 }
    }

    /// Returns the current base URL string.
    /// Called by the HTTP handler to construct absolute manifest and IPA URLs.
    func currentBaseURL() -> String {
        lockedBaseURL.withLock { $0 }
    }
}

// MARK: - HTTP Handler

/// Channel handler that processes incoming HTTP/1.1 requests and routes them to the
/// appropriate response: API endpoints, index page, project install page, OTA manifest,
/// or IPA download.
///
/// This handler accumulates the full request (head + body + end) before responding.
/// API requests under /api/ are delegated to the APIRouter. All other requests
/// are handled as OTA deployment routes.
final class HTTPHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    /// Reference to the owning server, used to access project configs, generators, and callbacks.
    private let server: NIODeployServer

    /// Accumulated request head for the current request being processed.
    private var requestHead: HTTPRequestHead?

    /// Accumulated request body bytes for the current request.
    private var requestBody: Data = Data()

    /// Maximum request body size (1 MB) to prevent abuse.
    private static let maxBodySize = 1_048_576

    /// Optional API router for handling /api/ endpoints.
    var apiRouter: APIRouter?

    init(server: NIODeployServer) {
        self.server = server
    }

    /// Called by SwiftNIO when an HTTP request part arrives on the channel.
    ///
    /// HTTP/1.1 requests arrive in three parts: `.head` (method, URI, headers),
    /// `.body` (optional payload), and `.end` (trailing headers). We buffer the head
    /// and body, then process the full request once `.end` is received.
    ///
    /// - Parameter context: The channel handler context for writing responses.
    /// - Parameter data: The inbound HTTP request part (head, body, or end).
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = unwrapInboundIn(data)

        switch part {
        case .head(let head):
            requestHead = head
            requestBody = Data()

        case .body(let buffer):
            // Accumulate request body bytes for API endpoints.
            if requestBody.count + buffer.readableBytes <= Self.maxBodySize {
                var buf = buffer
                if let bytes = buf.readBytes(length: buf.readableBytes) {
                    requestBody.append(contentsOf: bytes)
                }
            }

        case .end:
            guard let head = requestHead else { return }
            requestHead = nil
            let body = requestBody
            requestBody = Data()
            handleRequest(context: context, head: head, body: body)
        }
    }

    /// Routes the fully-received HTTP request to the appropriate handler.
    ///
    /// Requests to /api/ are dispatched to the APIRouter. All other requests
    /// are handled as OTA deployment routes (GET-only).
    ///
    /// - Parameter context: The channel handler context for writing the response.
    /// - Parameter head: The HTTP request head containing method, URI, and headers.
    /// - Parameter body: The accumulated request body.
    private func handleRequest(context: ChannelHandlerContext, head: HTTPRequestHead, body: Data) {
        let path = head.uri.split(separator: "?").first.map(String.init) ?? head.uri

        // Delegate API requests to the router
        if let router = apiRouter, router.shouldHandle(path: path) {
            // Handle CORS preflight requests
            if head.method == .OPTIONS {
                sendDataResponse(context: context, status: .noContent, contentType: "text/plain", data: Data())
                return
            }
            let apiRequest = APIRequest(head: head, body: body)
            let apiResponse = router.handle(apiRequest)
            sendDataResponse(context: context, status: apiResponse.status, contentType: apiResponse.contentType, data: apiResponse.body)
            return
        }

        // Serve PWA static files at /app/
        if path.hasPrefix("/app/") || path == "/app" {
            servePWAFile(context: context, path: path)
            return
        }

        // OTA routes are GET-only
        guard head.method == .GET else {
            sendResponse(context: context, status: .methodNotAllowed, contentType: "text/plain", body: "Method Not Allowed")
            return
        }
        let projects = server.registeredProjects()

        // GET / -> Index page
        if path == "/" {
            let html = buildIndexPage(projects: projects)
            sendResponse(context: context, status: .ok, contentType: "text/html", body: html)
            return
        }

        // Parse /<slug>/... pattern
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard let slugSubstring = components.first else {
            sendNotFound(context: context)
            return
        }
        let slug = String(slugSubstring)

        guard let project = projects[slug] else {
            sendNotFound(context: context)
            return
        }

        let subpath = components.count > 1 ? String(components[1]) : ""
        let baseURL = server.currentBaseURL()

        switch subpath {
        case _ where subpath.isEmpty,
             _ where path.hasSuffix("/") && components.count == 1:
            // GET /<slug>/ -> Install page
            let manifestURL = "\(baseURL)/\(slug)/manifest.plist"
            let ipaPath = "\(server.serveRoot)/\(slug)/app.ipa"

            // Read version/build from the IPA's Info.plist if available, otherwise use defaults
            let version = "1.0.0"
            let build = "1"
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH:mm z"
            let buildTime: String
            if let attrs = try? FileManager.default.attributesOfItem(atPath: ipaPath),
               let modDate = attrs[.modificationDate] as? Date {
                buildTime = formatter.string(from: modDate)
            } else {
                buildTime = formatter.string(from: Date())
            }

            let html = server.installPageGenerator.generatePage(
                appName: project.name,
                version: version,
                build: build,
                buildTime: buildTime,
                manifestURL: manifestURL
            )
            sendResponse(context: context, status: .ok, contentType: "text/html", body: html)

        case "manifest.plist":
            // GET /<slug>/manifest.plist -> OTA manifest
            let ipaURL = "\(baseURL)/\(slug)/app.ipa"
            let xml = server.manifestGenerator.generateManifest(
                bundleID: project.bundleID,
                version: "1.0.0",
                appName: project.name,
                ipaURL: ipaURL
            )
            sendResponse(context: context, status: .ok, contentType: "application/xml", body: xml)

        case "app.ipa":
            // GET /<slug>/app.ipa -> IPA file download
            let ipaPath = "\(server.serveRoot)/\(slug)/app.ipa"
            guard FileManager.default.fileExists(atPath: ipaPath) else {
                sendNotFound(context: context)
                return
            }

            // Notify delegate/callback about the download
            let sourceIP = head.headers["X-Forwarded-For"].first
                ?? context.remoteAddress?.description
                ?? "unknown"
            let userAgent = head.headers["User-Agent"].first ?? "unknown"

            server.onIPADownload?(slug, sourceIP, userAgent)

            // Notify delegate asynchronously
            if let delegate = server.delegate {
                let projectName = project.name
                Task {
                    await delegate.serverDidServeIPA(
                        projectName: projectName,
                        sourceIP: sourceIP,
                        userAgent: userAgent
                    )
                }
            }

            sendFileResponse(context: context, filePath: ipaPath)
            return

        default:
            sendNotFound(context: context)
        }
    }

    /// Builds a simple HTML index page listing all registered projects with links to their
    /// install pages.
    ///
    /// - Parameter projects: Dictionary of slug -> ProjectConfig for all registered projects.
    /// - Returns: A complete HTML string for the index page.
    private func buildIndexPage(projects: [String: ProjectConfig]) -> String {
        var rows = ""
        for (slug, project) in projects.sorted(by: { $0.key < $1.key }) {
            rows += "<li><a href=\"/\(slug)/\">\(project.name)</a> -- \(project.bundleID)</li>\n"
        }

        if rows.isEmpty {
            rows = "<li>No projects configured.</li>"
        }

        return """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <title>RemoteDeploy</title>
            <style>
                body { font-family: -apple-system, sans-serif; max-width: 600px; margin: 40px auto; padding: 0 20px; }
                h1 { color: #333; }
                ul { list-style: none; padding: 0; }
                li { padding: 12px 0; border-bottom: 1px solid #eee; }
                a { color: #007AFF; text-decoration: none; font-weight: 500; }
                a:hover { text-decoration: underline; }
            </style>
        </head>
        <body>
            <h1>RemoteDeploy</h1>
            <p>Available projects:</p>
            <ul>
                \(rows)
            </ul>
        </body>
        </html>
        """
    }

    /// Sends an HTTP response with raw Data body.
    ///
    /// Used by the API router to send JSON responses.
    ///
    /// - Parameter context: The channel handler context to write the response to.
    /// - Parameter status: The HTTP status code.
    /// - Parameter contentType: The Content-Type header value.
    /// - Parameter data: The response body as raw bytes.
    private func sendDataResponse(
        context: ChannelHandlerContext,
        status: HTTPResponseStatus,
        contentType: String,
        data: Data
    ) {
        var buffer = context.channel.allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)

        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: contentType)
        headers.add(name: "Content-Length", value: "\(data.count)")
        headers.add(name: "Connection", value: "close")
        headers.add(name: "X-Content-Type-Options", value: "nosniff")
        headers.add(name: "Access-Control-Allow-Origin", value: "*")
        headers.add(name: "Access-Control-Allow-Headers", value: "Authorization, Content-Type")
        headers.add(name: "Access-Control-Allow-Methods", value: "GET, POST, PUT, DELETE, OPTIONS")

        let responseHead = HTTPResponseHead(version: .http1_1, status: status, headers: headers)
        context.write(wrapOutboundOut(.head(responseHead)), promise: nil)
        context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
    }

    /// Sends an HTTP response with a string body.
    ///
    /// Writes the full HTTP response (head + body + end) to the channel and flushes.
    /// The connection is closed after the response via the `close` header.
    ///
    /// - Parameter context: The channel handler context to write the response to.
    /// - Parameter status: The HTTP status code (e.g. .ok, .notFound).
    /// - Parameter contentType: The Content-Type header value (e.g. "text/html").
    /// - Parameter body: The response body as a UTF-8 string.
    private func sendResponse(
        context: ChannelHandlerContext,
        status: HTTPResponseStatus,
        contentType: String,
        body: String
    ) {
        let bodyData = Data(body.utf8)
        var buffer = context.channel.allocator.buffer(capacity: bodyData.count)
        buffer.writeBytes(bodyData)

        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: contentType)
        headers.add(name: "Content-Length", value: "\(bodyData.count)")
        headers.add(name: "Connection", value: "close")
        headers.add(name: "X-Content-Type-Options", value: "nosniff")
        headers.add(name: "X-Frame-Options", value: "DENY")

        let responseHead = HTTPResponseHead(version: .http1_1, status: status, headers: headers)
        context.write(wrapOutboundOut(.head(responseHead)), promise: nil)
        context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
    }

    /// Sends a binary file as an HTTP response with `application/octet-stream` content type.
    ///
    /// Reads the entire file into memory and writes it as a single response. For typical
    /// IPA files (10-100 MB), this is acceptable for a local-network deployment tool.
    ///
    /// - Parameter context: The channel handler context to write the response to.
    /// - Parameter filePath: Absolute path to the file to serve.
    private func sendFileResponse(context: ChannelHandlerContext, filePath: String) {
        guard let fileData = FileManager.default.contents(atPath: filePath) else {
            sendNotFound(context: context)
            return
        }

        var buffer = context.channel.allocator.buffer(capacity: fileData.count)
        buffer.writeBytes(fileData)

        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "application/octet-stream")
        headers.add(name: "Content-Length", value: "\(fileData.count)")
        headers.add(name: "Content-Disposition", value: "attachment; filename=\"app.ipa\"")
        headers.add(name: "Connection", value: "close")
        headers.add(name: "X-Content-Type-Options", value: "nosniff")
        headers.add(name: "X-Frame-Options", value: "DENY")

        let responseHead = HTTPResponseHead(version: .http1_1, status: .ok, headers: headers)
        context.write(wrapOutboundOut(.head(responseHead)), promise: nil)
        context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
    }

    /// Sends a 404 Not Found response with a plain-text body.
    ///
    /// - Parameter context: The channel handler context to write the response to.
    private func sendNotFound(context: ChannelHandlerContext) {
        sendResponse(context: context, status: .notFound, contentType: "text/plain", body: "404 Not Found")
    }

    /// Serves PWA static files from the app bundle's Resources/pwa directory.
    ///
    /// Maps /app/ to index.html, /app/style.css to style.css, etc.
    /// Files are loaded from the main bundle's resource path.
    ///
    /// - Parameter context: The channel handler context to write the response to.
    /// - Parameter path: The URL path (e.g., "/app/", "/app/style.css").
    private func servePWAFile(context: ChannelHandlerContext, path: String) {
        // Map the URL path to a filename
        var filename = String(path.dropFirst("/app/".count))
        if filename.isEmpty || filename == "/" {
            filename = "index.html"
        }

        // Security: prevent path traversal
        guard !filename.contains("..") else {
            sendNotFound(context: context)
            return
        }

        // Look for the file in the app bundle's pwa resources
        guard let resourcePath = Bundle.main.resourcePath else {
            sendNotFound(context: context)
            return
        }

        let filePath = "\(resourcePath)/pwa/\(filename)"
        guard let fileData = FileManager.default.contents(atPath: filePath) else {
            sendNotFound(context: context)
            return
        }

        // Determine content type from extension
        let contentType: String
        if filename.hasSuffix(".html") { contentType = "text/html; charset=utf-8" }
        else if filename.hasSuffix(".css") { contentType = "text/css; charset=utf-8" }
        else if filename.hasSuffix(".js") { contentType = "application/javascript; charset=utf-8" }
        else if filename.hasSuffix(".json") { contentType = "application/json" }
        else if filename.hasSuffix(".svg") { contentType = "image/svg+xml" }
        else { contentType = "application/octet-stream" }

        var buffer = context.channel.allocator.buffer(capacity: fileData.count)
        buffer.writeBytes(fileData)

        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: contentType)
        headers.add(name: "Content-Length", value: "\(fileData.count)")
        headers.add(name: "Connection", value: "close")
        headers.add(name: "Cache-Control", value: "public, max-age=3600")

        let responseHead = HTTPResponseHead(version: .http1_1, status: .ok, headers: headers)
        context.write(wrapOutboundOut(.head(responseHead)), promise: nil)
        context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
    }
}
