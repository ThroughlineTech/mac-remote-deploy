// Concrete implementation of DeployServerProtocol using SwiftNIO + NIOSSL.
// Serves HTTPS install pages, OTA manifests, and IPA files for over-the-air iOS deployment.
// Each project is served under its own URL slug: /<slug>/, /<slug>/manifest.plist, /<slug>/app.ipa.
//
// The HTTP request handling lives in HTTPHandler.swift; the response generators
// (install page, manifest, IPA serving, PWA static files) live in NIOResponseGenerator.swift.
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
        /// Whether the HTTPS install server is bound. This is what "server
        /// running" means to the user (devices can install).
        var isRunning = false
        /// Whether the plain-HTTP API listener (:8080) is bound. TKT-056 split
        /// this from `isRunning` so the loopback API can be up before TLS certs
        /// are configured.
        var httpRunning = false
        var port: Int = 8443
        var httpPort: Int = 8080
    }

    /// Lock protecting server lifecycle state.
    private let lockedState = OSAllocatedUnfairLock(initialState: ServerState())

    /// The registered project configurations, keyed by URL slug. Protected by lock.
    private let lockedProjectsBySlug = OSAllocatedUnfairLock<[String: ProjectConfig]>(initialState: [:])

    /// Generator for OTA manifest.plist responses. Read by HTTPHandler from NIOResponseGenerator.swift.
    let manifestGenerator: ManifestGenerating

    /// Generator for HTML install page responses. Read by HTTPHandler from NIOResponseGenerator.swift.
    let installPageGenerator: InstallPageGenerating

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

    /// Optional authenticator for WebSocket upgrade requests at `/api/v1/ws`.
    /// Set by `AppDelegate.configureAPIRouter` alongside `apiRouter`. The
    /// closure receives the HTTP request headers as (name, value) pairs and
    /// returns `true` if the request carries a valid bearer token. Nil or
    /// false rejects the upgrade, letting the HTTP pipeline fall through to
    /// `HTTPHandler`, which returns 401 for `/api/v1/ws`. TKT-011 / TKT-024.
    var webSocketAuthenticator: (@Sendable ([(String, String)]) -> Bool)?

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

    /// Replaces the entire slug registry so it exactly matches `projects`. Adds
    /// new slugs, updates changed ones, and drops slugs no longer present. Called
    /// whenever the project store changes via any path so create/edit/delete take
    /// effect immediately. TKT-055 (Phase 2).
    ///
    /// - Parameter projects: The full, authoritative set of projects to serve.
    func syncProjects(_ projects: [ProjectConfig]) {
        let bySlug = Dictionary(projects.map { ($0.urlSlug, $0) }, uniquingKeysWith: { _, latest in latest })
        lockedProjectsBySlug.withLock { $0 = bySlug }
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

    /// Protocol entry point: starts the HTTPS install server (and, for callers
    /// that want both at once, the plain-HTTP API listener on :8080).
    ///
    /// TKT-056 (Phase 3) split the two listeners -- see `startAPIListener` and
    /// `startHTTPS` -- so the loopback API the menu bar talks to can be up
    /// before TLS certs are configured. This combined entry point is preserved
    /// for the protocol and for integration tests that exercise both at once.
    func start(port: Int, certPath: String, keyPath: String) async throws {
        try await start(port: port, httpPort: 8080, certPath: certPath, keyPath: keyPath)
    }

    /// - Parameter port: The TCP port for the HTTPS listener (e.g. 8443).
    /// - Parameter httpPort: The TCP port for the plain-HTTP API listener.
    ///   Production uses 8080; integration tests pass a random ephemeral port to
    ///   avoid collisions with any running RemoteDeploy host. TKT-028.
    /// - Parameter certPath: Absolute path to the PEM-encoded TLS certificate file.
    /// - Parameter keyPath: Absolute path to the PEM-encoded TLS private key file.
    /// - Throws: If the HTTPS port is already in use, the cert/key files are
    ///   invalid or unreadable, or the HTTPS listener otherwise fails to bind.
    func start(port: Int, httpPort: Int, certPath: String, keyPath: String) async throws {
        // HTTPS first so a bad cert/in-use port throws before the HTTP listener
        // binds, preserving the original all-or-nothing failure semantics.
        try await startHTTPS(port: port, certPath: certPath, keyPath: keyPath)
        await startAPIListener(httpPort: httpPort)
    }

    /// Binds the plain-HTTP API listener on `httpPort` (default 8080), serving
    /// the REST API + WebSocket fan-out. Safe to call regardless of TLS config:
    /// this is the loopback surface the menu bar uses, and the same listener
    /// local-WiFi companions reach. The pairing endpoint is rejected over plain
    /// HTTP (tokens would be cleartext). Best-effort: a bind failure is logged,
    /// not thrown. Idempotent -- a no-op if the HTTP listener is already bound.
    func startAPIListener(httpPort: Int) async {
        let needsBind = lockedState.withLock { state -> Bool in
            if state.httpRunning { return false }
            state.httpPort = httpPort
            return true
        }
        guard needsBind else { return }

        let group = ensureGroup()
        let httpChannel = await bindHTTPListener(group: group, httpPort: httpPort)
        lockedState.withLock { state in
            state.httpChannel = httpChannel
            state.httpRunning = (httpChannel != nil)
        }
    }

    /// Binds the HTTPS install server on `port` using the given TLS cert/key.
    /// Idempotent -- a no-op if HTTPS is already running. Throws if the port is
    /// in use or the cert/key are invalid/unreadable (the `isRunning` flag is
    /// left false so a later retry with a valid cert proceeds).
    func startHTTPS(port: Int, certPath: String, keyPath: String) async throws {
        let needsBind = lockedState.withLock { state -> Bool in
            if state.isRunning { return false }
            state.port = port
            return true
        }
        guard needsBind else { return }

        let group = ensureGroup()
        let channel = try await bindHTTPSListener(group: group, port: port, certPath: certPath, keyPath: keyPath)
        lockedState.withLock { state in
            state.serverChannel = channel
            state.isRunning = true
        }
    }

    /// Returns the shared event-loop group, creating it on first use. Both
    /// listeners share one group so a full `stop()` tears everything down.
    private func ensureGroup() -> MultiThreadedEventLoopGroup {
        lockedState.withLock { state in
            if let group = state.group { return group }
            let group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
            state.group = group
            return group
        }
    }

    /// Builds and binds the TLS-terminated HTTPS listener. Installs a
    /// NIOWebSocketServerUpgrader so authenticated /api/v1/ws requests upgrade
    /// to WebSocket; everything else flows through a per-channel HTTPHandler.
    private func bindHTTPSListener(group: MultiThreadedEventLoopGroup, port: Int, certPath: String, keyPath: String) async throws -> Channel {
        // -- TLS Configuration --
        let cert = try NIOSSLCertificate.fromPEMFile(certPath)
        let privateKey = try NIOSSLPrivateKey(file: keyPath, format: .pem)

        var tlsConfig = TLSConfiguration.makeServerConfiguration(
            certificateChain: cert.map { .certificate($0) },
            privateKey: .privateKey(privateKey)
        )
        tlsConfig.minimumTLSVersion = .tlsv12

        let sslContext = try NIOSSLContext(configuration: tlsConfig)

        // TKT-011 / TKT-024 Commit 6: capture authenticator + manager + a server
        // reference by value so the @Sendable childChannelInitializer can build
        // per-channel handlers without retaining `self` implicitly.
        let wsAuth = self.webSocketAuthenticator
        let wsManager = self.webSocketManager
        let serverRef = self
        let capturedAPIRouter = self.apiRouter

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(.backlog, value: 256)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                let sslHandler = NIOSSLServerHandler(context: sslContext)
                // TKT-011 / TKT-024 Commit 6: construct a fresh HTTPHandler
                // per channel. Previously we shared a single instance across
                // all connections, which was latently unsafe because
                // HTTPHandler stores mutable per-request state (requestHead,
                // requestBody). Per-channel instances also let us remove
                // the handler from the pipeline cleanly on WS upgrade so it
                // does not attempt to decode WebSocket frames as HTTP parts.
                let perChannelHandler = HTTPHandler(server: serverRef)
                perChannelHandler.apiRouter = capturedAPIRouter

                let wsUpgrader = NIOWebSocketServerUpgrader(
                    maxFrameSize: 16 * 1024,
                    shouldUpgrade: { (ch: Channel, head: HTTPRequestHead) -> EventLoopFuture<HTTPHeaders?> in
                        // Only upgrade the WebSocket endpoint.
                        let path = head.uri.split(separator: "?").first.map(String.init) ?? head.uri
                        guard path == "/api/v1/ws" else {
                            return ch.eventLoop.makeSucceededFuture(nil)
                        }
                        // Enforce bearer token auth using the same authenticator
                        // the REST routes use.
                        let headers = head.headers.map { ($0.name, $0.value) }
                        if wsAuth?(headers) == true {
                            return ch.eventLoop.makeSucceededFuture(HTTPHeaders())
                        }
                        return ch.eventLoop.makeSucceededFuture(nil)
                    },
                    upgradePipelineHandler: { (ch: Channel, _: HTTPRequestHead) -> EventLoopFuture<Void> in
                        // NIO's HTTPServerUpgradeHandler automatically removes
                        // the HTTP decoder/encoder/upgrader after a successful
                        // upgrade, but NOT any handler we added after it —
                        // so perChannelHandler must be removed explicitly
                        // or it will crash trying to decode WS frames.
                        ch.pipeline.removeHandler(perChannelHandler).flatMap {
                            ch.pipeline.addHandler(WebSocketChannelHandler(manager: wsManager))
                        }
                    }
                )
                let upgradeConfig: NIOHTTPServerUpgradeConfiguration = (upgraders: [wsUpgrader], completionHandler: { _ in })
                return channel.pipeline.addHandler(sslHandler as RemovableChannelHandler).flatMap {
                    channel.pipeline.configureHTTPServerPipeline(withServerUpgrade: upgradeConfig).flatMap {
                        channel.pipeline.addHandler(perChannelHandler)
                    }
                }
            }
            .childChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(.maxMessagesPerRead, value: 1)

        return try await bootstrap.bind(host: "0.0.0.0", port: port).get()
    }

    /// Builds and binds the plain-HTTP API listener. Best-effort: returns nil
    /// (logging) if the port is already in use. No TLS; the pairing endpoint is
    /// rejected so raw tokens never travel in cleartext.
    private func bindHTTPListener(group: MultiThreadedEventLoopGroup, httpPort: Int) async -> Channel? {
        let serverRef = self
        let capturedAPIRouter = self.apiRouter

        let httpBootstrap = ServerBootstrap(group: group)
            .serverChannelOption(.backlog, value: 256)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                // No TLS — plain HTTP for loopback + local WiFi
                let perChannelHTTPHandler = HTTPHandler(server: serverRef)
                perChannelHTTPHandler.apiRouter = capturedAPIRouter
                perChannelHTTPHandler.rejectPairingOverHTTP = true
                return channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(perChannelHTTPHandler)
                }
            }
            .childChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(.maxMessagesPerRead, value: 1)

        // TKT-028: log (rather than silently swallow) any bind failure. HTTP is
        // best-effort — if the port is already in use, the HTTPS listener still
        // runs and companions can reach the Mac over Tailscale.
        do {
            return try await httpBootstrap.bind(host: "0.0.0.0", port: httpPort).get()
        } catch {
            Logger.server.error("HTTP listener failed to bind on port \(httpPort, privacy: .public): \(error.localizedDescription, privacy: .public). Local API/WiFi discovery will be unavailable; HTTPS still works.")
            return nil
        }
    }

    /// Stops only the HTTPS install server, leaving the HTTP API listener up.
    /// Used to (re)start HTTPS after a cert/port change without dropping the
    /// loopback API the menu bar depends on. TKT-056 (Phase 3).
    func stopHTTPS() async {
        let channel = lockedState.withLock { state -> Channel? in
            guard state.isRunning else { return nil }
            let ch = state.serverChannel
            state.serverChannel = nil
            state.isRunning = false
            return ch
        }
        try? await channel?.close().get()
    }

    /// Stops both the HTTPS and HTTP servers and releases listening sockets.
    /// Shuts down the event loop group gracefully. No-op if neither is running.
    func stop() async {
        let (channel, httpCh, group) = lockedState.withLock { state -> (Channel?, Channel?, MultiThreadedEventLoopGroup?) in
            guard state.isRunning || state.httpRunning else { return (nil, nil, nil) }
            let ch = state.serverChannel
            let http = state.httpChannel
            let gr = state.group
            state.serverChannel = nil
            state.httpChannel = nil
            state.isRunning = false
            state.httpRunning = false
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
