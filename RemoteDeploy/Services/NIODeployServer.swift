// Concrete implementation of DeployServerProtocol using SwiftNIO + NIOSSL.
// Serves HTTPS install pages, OTA manifests, and IPA files for over-the-air iOS deployment.
// Each project is served under its own URL slug: /<slug>/, /<slug>/manifest.plist, /<slug>/app.ipa.
import Foundation
import NIO
import NIOHTTP1
import NIOSSL
import NIOFoundationCompat

final class NIODeployServer: DeployServerProtocol, @unchecked Sendable {

    // MARK: - Private State

    /// Lock protecting mutable state.
    private let lock = NSLock()

    /// The SwiftNIO event loop group powering the server.
    private var group: MultiThreadedEventLoopGroup?

    /// The bound server channel. Nil when not running.
    private var serverChannel: Channel?

    /// Backing storage for `isRunning`.
    private var _isRunning = false

    /// Backing storage for `port`.
    private var _port: Int = 8443

    /// The registered project configurations, keyed by URL slug.
    /// Used to determine which slugs are valid and to look up project metadata.
    fileprivate var projectsBySlug: [String: ProjectConfig] = [:]

    /// Generator for OTA manifest.plist responses.
    fileprivate let manifestGenerator: ManifestGenerating

    /// Generator for HTML install page responses.
    fileprivate let installPageGenerator: InstallPageGenerating

    /// The base HTTPS URL (e.g. "https://macbook.tail1234.ts.net:8443") used to construct
    /// absolute URLs in manifests and install pages.
    fileprivate var baseURL: String = ""

    /// Callback invoked when an IPA is downloaded. Arguments: (projectSlug, sourceIP, userAgent).
    var onIPADownload: ((String, String, String) -> Void)?

    // MARK: - Protocol Properties

    /// Whether the server is currently listening for connections.
    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isRunning
    }

    /// The TCP port the server is currently configured to use.
    var port: Int {
        lock.lock()
        defer { lock.unlock() }
        return _port
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
        lock.lock()
        projectsBySlug[project.urlSlug] = project
        lock.unlock()
    }

    /// Removes a project configuration so its routes are no longer served.
    ///
    /// - Parameter slug: The URL slug of the project to unregister.
    func unregisterProject(slug: String) {
        lock.lock()
        projectsBySlug.removeValue(forKey: slug)
        lock.unlock()
    }

    /// Updates the base URL used when generating absolute URLs in manifests and install pages.
    ///
    /// This should be called whenever the hostname or port changes (e.g. when the Tailscale
    /// IP is resolved). Example: "https://macbook.tail1234.ts.net:8443".
    ///
    /// - Parameter url: The base HTTPS URL (no trailing slash).
    func setBaseURL(_ url: String) {
        lock.lock()
        baseURL = url
        lock.unlock()
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
        lock.lock()
        guard !_isRunning else {
            lock.unlock()
            return
        }
        _port = port
        lock.unlock()

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
        self.group = group

        let handler = HTTPHandler(server: self)

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(.backlog, value: 256)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                let sslHandler = NIOSSLServerHandler(context: sslContext)
                return channel.pipeline.addHandler(sslHandler).flatMap {
                    channel.pipeline.configureHTTPServerPipeline().flatMap {
                        channel.pipeline.addHandler(handler)
                    }
                }
            }
            .childChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(.maxMessagesPerRead, value: 1)

        let channel = try await bootstrap.bind(host: "0.0.0.0", port: port).get()

        lock.lock()
        serverChannel = channel
        _isRunning = true
        lock.unlock()
    }

    /// Stops the server and releases the listening socket.
    /// Shuts down the event loop group gracefully. No-op if the server is not running.
    func stop() async {
        lock.lock()
        guard _isRunning else {
            lock.unlock()
            return
        }
        let channel = serverChannel
        let group = self.group
        serverChannel = nil
        _isRunning = false
        lock.unlock()

        try? await channel?.close().get()
        try? await group?.shutdownGracefully()

        lock.lock()
        self.group = nil
        lock.unlock()
    }

    // MARK: - Internal Accessors (used by HTTPHandler)

    /// Returns a snapshot of all registered project configs.
    /// Called by the HTTP handler to build the index page and validate routes.
    func registeredProjects() -> [String: ProjectConfig] {
        lock.lock()
        defer { lock.unlock() }
        return projectsBySlug
    }

    /// Returns the current base URL string.
    /// Called by the HTTP handler to construct absolute manifest and IPA URLs.
    func currentBaseURL() -> String {
        lock.lock()
        defer { lock.unlock() }
        return baseURL
    }
}

// MARK: - HTTP Handler

/// Channel handler that processes incoming HTTP/1.1 requests and routes them to the
/// appropriate response: index page, project install page, OTA manifest, or IPA download.
///
/// This handler accumulates the full request (head + body + end) before responding,
/// since all routes produce complete responses (no streaming request bodies needed).
final class HTTPHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    /// Reference to the owning server, used to access project configs, generators, and callbacks.
    private let server: NIODeployServer

    /// Accumulated request head for the current request being processed.
    private var requestHead: HTTPRequestHead?

    init(server: NIODeployServer) {
        self.server = server
    }

    /// Called by SwiftNIO when an HTTP request part arrives on the channel.
    ///
    /// HTTP/1.1 requests arrive in three parts: `.head` (method, URI, headers),
    /// `.body` (optional payload), and `.end` (trailing headers). We buffer the head
    /// and process the full request once `.end` is received.
    ///
    /// - Parameter context: The channel handler context for writing responses.
    /// - Parameter data: The inbound HTTP request part (head, body, or end).
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = unwrapInboundIn(data)

        switch part {
        case .head(let head):
            requestHead = head

        case .body:
            // We don't need request bodies for any of our routes.
            break

        case .end:
            guard let head = requestHead else { return }
            requestHead = nil
            handleRequest(context: context, head: head)
        }
    }

    /// Routes the fully-received HTTP request to the appropriate handler method.
    ///
    /// Route table:
    /// - `GET /`                      → Index page listing all registered projects
    /// - `GET /<slug>/`               → Install page for the given project
    /// - `GET /<slug>/manifest.plist` → OTA manifest XML for the given project
    /// - `GET /<slug>/app.ipa`        → Binary IPA file download
    /// - Everything else              → 404 Not Found
    ///
    /// - Parameter context: The channel handler context for writing the response.
    /// - Parameter head: The HTTP request head containing method, URI, and headers.
    private func handleRequest(context: ChannelHandlerContext, head: HTTPRequestHead) {
        guard head.method == .GET else {
            sendResponse(context: context, status: .methodNotAllowed, contentType: "text/plain", body: "Method Not Allowed")
            return
        }

        let path = head.uri.split(separator: "?").first.map(String.init) ?? head.uri
        let projects = server.registeredProjects()

        // GET / → Index page
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
        case "", _ where path.hasSuffix("/") && components.count == 1:
            // GET /<slug>/ → Install page
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
            // GET /<slug>/manifest.plist → OTA manifest
            let ipaURL = "\(baseURL)/\(slug)/app.ipa"
            let xml = server.manifestGenerator.generateManifest(
                bundleID: project.bundleID,
                version: "1.0.0",
                appName: project.name,
                ipaURL: ipaURL
            )
            sendResponse(context: context, status: .ok, contentType: "application/xml", body: xml)

        case "app.ipa":
            // GET /<slug>/app.ipa → IPA file download
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
    /// - Parameter projects: Dictionary of slug → ProjectConfig for all registered projects.
    /// - Returns: A complete HTML string for the index page.
    private func buildIndexPage(projects: [String: ProjectConfig]) -> String {
        var rows = ""
        for (slug, project) in projects.sorted(by: { $0.key < $1.key }) {
            rows += "<li><a href=\"/\(slug)/\">\(project.name)</a> — \(project.bundleID)</li>\n"
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
}
