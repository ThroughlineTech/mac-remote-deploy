// Startup/lifecycle for the headless RemoteDeployServer process. TKT-060 (Phase 6).
//
// This is the server half of what used to be RemoteDeploy/AppDelegate.swift. It
// owns the backend end to end: build manager + coordinator, the stores, push
// notifiers, the Tailscale poll, the NIO API listener (:8080) and HTTPS install
// server (:8443), and Bonjour. It runs as the NSApplicationDelegate of a headless
// (LSUIElement) NSApplication, so the AppKit run loop drives the timers and NIO.
//
// Unlike the old fused delegate it has NO SwiftUI state injection (`register`) and
// NO menu-bar client: it constructs its own AppState (used purely as the build
// config holder), ServiceContainer, and BuildManager, and hands the menu bar a
// loopback bearer token through LoopbackTokenStore instead of an in-process object.
import Foundation
import AppKit
import CryptoKit
import os
import RemoteDeployShared

@MainActor
final class ServerLifecycle: NSObject, NSApplicationDelegate {

    // MARK: - Owned state
    //
    // The server constructs these itself (no SwiftUI). AppState is reused as a
    // plain config holder: BuildCoordinator + startServer read serverPort / cert /
    // key / hostname / serverRunning off it. It is @MainActor ObservableObject but
    // needs no SwiftUI here.
    private let appState = AppState()
    private let serviceContainer = ServiceContainer()
    private let buildManager = BuildManager()

    /// The cert/port HTTPS is currently bound with, so a settings change can tell
    /// whether HTTPS needs to (re)start. Nil when HTTPS is not running. TKT-056.
    private var runningHTTPSConfig: HTTPSConfig?

    private struct HTTPSConfig: Equatable {
        let port: Int
        let certPath: String
        let keyPath: String
        /// SHA-256 of the cert file's contents. TKT-071: lets `reconcileHTTPS`
        /// detect a cert REPLACED in place (e.g. an auto-renewal that rewrites the
        /// same filename) and reload, where comparing the path alone could not.
        /// Empty when the file is absent or unreadable.
        let certFingerprint: String
    }

    /// How often the server re-checks its TLS cert for expiry. TKT-071: the cert is
    /// a 90-day Tailscale Let's Encrypt cert with a 7-day renewal window, so a
    /// twice-daily check is ample headroom while keeping the (synchronous) openssl
    /// inspection rare.
    private static let certRenewalCheckInterval: TimeInterval = 12 * 60 * 60

    // MARK: - Lifecycle guards

    /// Set once performStartup() has run; prevents double-runs.
    /// Exposed `internal` for ServerLifecycleTests.
    internal private(set) var didPerformStartup = false

    /// Test-only override: when non-nil, `performStartup()` invokes this instead
    /// of the real startup body, so ServerLifecycleTests can assert the run-once
    /// guard without touching real services (Tailscale CLI, file I/O, NIO bind).
    internal var performStartupOverrideForTests: (@MainActor () async -> Void)?

    // MARK: - NSApplicationDelegate

    func applicationDidFinishLaunching(_ notification: Notification) {
        // TKT-055 (Phase 2): the stores are the single source of truth. These
        // observers fire entirely within this process -- the project/settings
        // stores post them on every write, INCLUDING writes that arrive over the
        // API on a NIO thread (all menu-bar/web/iOS writes route through the API
        // now). So the reconcilers live here, in the server.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleProjectsDidChange),
            name: .projectsDidChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSettingsDidChange),
            name: .settingsDidChange,
            object: nil
        )

        Task { @MainActor [weak self] in
            await self?.performStartup()
        }
    }

    // MARK: - Termination

    /// Synchronously stop the NIO server and Bonjour advertiser to release ports
    /// before exit, and clear the loopback token so a stale token does not linger
    /// after the server is gone. TKT-050 / TKT-060.
    func applicationWillTerminate(_ notification: Notification) {
        serviceContainer.bonjourAdvertiser.stop()

        let semaphore = DispatchSemaphore(value: 0)
        let server = serviceContainer.deployServer
        Task.detached {
            await server.stop()
            semaphore.signal()
        }
        semaphore.wait(timeout: .now() + 3)

        LoopbackTokenStore.clear()
    }

    // MARK: - Startup

    /// Runs once at launch: configures the build manager + coordinator, loads
    /// settings + projects, configures push notifiers, checks Tailscale, brings up
    /// the API listener and HTTPS, mints the menu bar's loopback token, and begins
    /// periodic status polling.
    func performStartup() async {
        guard !didPerformStartup else { return }
        didPerformStartup = true

        if let override = performStartupOverrideForTests {
            await override()
            return
        }

        // macOS desktop notifications for build events (server-posted).
        serviceContainer.notificationManager.requestPermission()

        // Wire BuildManager's dependencies. TKT-027: the deploy server doubles as
        // the BuildEventBroadcasting sink, so live log lines + status transitions
        // fan out to subscribed WebSocket clients.
        buildManager.configure(
            buildEngine: serviceContainer.buildEngine,
            deployServer: serviceContainer.deployServer,
            notificationManager: serviceContainer.notificationManager,
            ipaImporter: serviceContainer.ipaImporter,
            buildHistoryStore: serviceContainer.buildHistoryStore,
            buildEventBroadcaster: serviceContainer.deployServer as? BuildEventBroadcasting,
            localDeployManager: LocalDeployManager()
        )
        buildManager.sendPushNotification = { [serviceContainer] title, message, priority, url in
            await serviceContainer.sendPushNotification(title: title, message: message, priority: priority, url: url)
        }

        // View-independent build owner. TKT-054.
        serviceContainer.buildCoordinator = BuildCoordinator(
            buildManager: buildManager,
            projectStore: serviceContainer.projectStore,
            config: appState,
            buildEngine: serviceContainer.buildEngine
        )

        loadSettings()
        refreshProjectsFromStore()
        serviceContainer.configurePushNotifiers(from: appState.pushNotificationConfig)
        await checkTailscaleStatus()

        // TKT-056 (Phase 3): always-on plain-HTTP API listener on :8080 so the
        // menu bar (and local-WiFi companions) reach the API even before certs.
        await prepareServer()

        // Start HTTPS if certificates are already configured.
        startServer()

        // TKT-060 (Phase 6): hand the menu bar a loopback bearer token on disk.
        mintLoopbackToken()

        startStatusPolling()
        startCertRenewalPolling()
    }

    // MARK: - NotificationCenter handlers

    /// Re-syncs the deploy server's slug registry (and the server-side projection)
    /// after any writer mutates the project store. Posted from arbitrary threads
    /// (the API runs on a NIO event loop), so hop to the main actor. TKT-055.
    @objc private func handleProjectsDidChange() {
        Task { @MainActor [weak self] in
            self?.refreshProjectsFromStore()
        }
    }

    /// Applies the new settings and brings HTTPS into line after any writer
    /// mutates the settings store. Posted from arbitrary threads; hop to main.
    /// TKT-055 / TKT-056.
    @objc private func handleSettingsDidChange() {
        Task { @MainActor [weak self] in
            self?.applySettingsFromStore()
            // A settings write may have set cert paths or changed the port (e.g.
            // via the menu bar's API client). Bring HTTPS into line so the change
            // takes effect without a relaunch.
            self?.reconcileHTTPS()
        }
    }

    // MARK: - Loaders

    /// Re-syncs the deploy server's slug registry from the authoritative project
    /// store. TKT-055 (Phase 2): the store is the single source of truth.
    private func refreshProjectsFromStore() {
        do {
            let projects = try serviceContainer.projectStore.loadProjects()
            appState.projects = projects
            // Keep the install-page slug registry in sync so a project created or
            // deleted via any path takes effect immediately (no server restart).
            serviceContainer.deployServer.syncProjects(projects)
        } catch {
            let boundaryError = RemoteDeployError(wrapping: error)
            Logger.storage.error("Failed to load projects: \(boundaryError.localizedDescription, privacy: .public)")
        }
    }

    /// Queries Tailscale CLI to update connection status and hostname.
    private func checkTailscaleStatus() async {
        do {
            let connected = await serviceContainer.tailscaleProvider.isConnected()
            appState.tailscaleConnected = connected
            // TKT-055: mirror the live flag into the runtime store the API reads.
            serviceContainer.runtimeStatus.tailscaleConnected = connected

            if connected {
                let hostname = try await serviceContainer.tailscaleProvider.detectHostname()
                appState.hostname = hostname
                let port = appState.serverPort
                appState.serverURL = "https://\(hostname):\(port)"
                // TKT-055: persist a changed hostname through the settings store
                // (the source of truth the status endpoint reports) only when it
                // actually changed, so the 10s poll doesn't rewrite settings.json
                // every tick.
                if serviceContainer.settingsStore.current().hostname != hostname {
                    var settings = serviceContainer.settingsStore.current()
                    settings.hostname = hostname
                    serviceContainer.settingsStore.update(settings)
                }
            } else {
                if let localIP = QRCodeGenerator.localIPAddress() {
                    appState.serverURL = "http://\(localIP):8080"
                }
            }
        } catch {
            appState.tailscaleConnected = false
            serviceContainer.runtimeStatus.tailscaleConnected = false
            if let localIP = QRCodeGenerator.localIPAddress() {
                appState.serverURL = "http://\(localIP):8080"
            }
            let boundaryError = RemoteDeployError.networkError(reason: error.localizedDescription)
            Logger.tailscale.error("Tailscale check failed: \(boundaryError.failureReason ?? "", privacy: .public)")
        }
    }

    /// Polls Tailscale status every 10 seconds.
    private func startStatusPolling() {
        Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                await self?.checkTailscaleStatus()
            }
        }
    }

    /// Renews the TLS cert before it expires. TKT-071: without this the 90-day
    /// Tailscale cert silently expired and companions could no longer pair (the iOS
    /// client rejects an expired cert during the TLS handshake; pairing requires
    /// HTTPS, so there is no working fallback). The first check runs immediately at
    /// startup so a server that booted with an already-expired cert self-heals,
    /// then it re-checks every `certRenewalCheckInterval`.
    private func startCertRenewalPolling() {
        Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await self?.renewCertificateIfNeeded()
                try? await Task.sleep(for: .seconds(Self.certRenewalCheckInterval))
            }
        }
    }

    /// Checks the configured cert and re-provisions if it is expired or within the
    /// renewal window. On renewal the provisioner writes the fresh cert and updates
    /// the settings store, which posts `.settingsDidChange`; `reconcileHTTPS()` then
    /// sees the changed fingerprint and restarts HTTPS with the renewed cert.
    private func renewCertificateIfNeeded() async {
        let certPath = appState.certPath
        let certificateProvider = serviceContainer.certificateProvider
        let provisioner = serviceContainer.certProvisioner
        // `needsRenewal` shells out to `openssl`, so keep it off the main actor.
        await Task.detached {
            CertRenewalCoordinator(certificateProvider: certificateProvider, provisioner: provisioner)
                .renewIfNeeded(certPath: certPath)
        }.value
    }

    // MARK: - Settings

    /// Applies the settings store's current values into the AppState config holder.
    /// TKT-055 (Phase 2): the SettingsStore is the single source of truth; this is
    /// the read side, called at startup and whenever `.settingsDidChange` fires.
    private func applySettingsFromStore() {
        let settings = serviceContainer.settingsStore.current()
        appState.serverPort = settings.serverPort
        appState.hostname = settings.hostname
        appState.certPath = settings.certPath
        appState.keyPath = settings.keyPath
        appState.pushNotificationConfig = settings.pushNotificationConfig
        if !settings.hostname.isEmpty {
            appState.serverURL = "https://\(settings.hostname):\(settings.serverPort)"
        }
        // Keep the deploy server's base URL (install-page + manifest absolute URLs)
        // in sync with the current hostname/port. TKT-056.
        serviceContainer.deployServer.setBaseURL(appState.serverURL)
        // TKT-056: a settings write may have changed push config via the API, so
        // reconfigure the server's push notifiers.
        serviceContainer.configurePushNotifiers(from: settings.pushNotificationConfig)
    }

    /// Startup alias for the settings read side.
    private func loadSettings() {
        applySettingsFromStore()
    }

    // MARK: - Server Lifecycle

    /// Configures the API router and brings up the always-on plain-HTTP API
    /// listener on :8080. Runs once at startup, before HTTPS. TKT-056 (Phase 3).
    private func prepareServer() async {
        guard let nioServer = serviceContainer.deployServer as? NIODeployServer else { return }

        nioServer.syncProjects(appState.projects)
        nioServer.setBaseURL(appState.serverURL)

        configureAPIRouter(on: nioServer, buildManager: buildManager, services: serviceContainer)

        // TKT-027: capture the broadcaster so the onIPADownload closure can fan
        // out install events without reaching back through serviceContainer.
        let broadcaster = nioServer as? any BuildEventBroadcasting

        nioServer.onIPADownload = { [weak appState, serviceContainer] slug, ip, ua in
            Task {
                await serviceContainer.installTracker.recordInstall(
                    projectName: slug,
                    sourceIP: ip,
                    userAgent: ua
                )
                let installs = await serviceContainer.installTracker.recentInstalls(limit: 1)
                await MainActor.run {
                    appState?.lastInstall = installs.first
                }
                broadcaster?.broadcastInstall(slug: slug, sourceIP: ip)
            }
        }

        await nioServer.startAPIListener(httpPort: 8080)
    }

    /// Starts the HTTPS install server if certificates are configured and HTTPS is
    /// not already running. TKT-056 (Phase 3): HTTPS-only.
    private func startServer() {
        guard !appState.certPath.isEmpty, !appState.keyPath.isEmpty else { return }
        guard !appState.serverRunning else { return }
        guard let nioServer = serviceContainer.deployServer as? NIODeployServer else { return }

        let config = currentHTTPSConfig()

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await nioServer.startHTTPS(
                    port: config.port,
                    certPath: config.certPath,
                    keyPath: config.keyPath
                )
                self.appState.serverRunning = true
                self.runningHTTPSConfig = config

                // TKT-021: defer Bonjour by a short interval so the :8080 listener
                // finishes binding before mDNSResponder is told about the service.
                let serverName = Host.current().localizedName ?? "RemoteDeploy"
                let httpsPort = config.port
                let hostname = self.appState.hostname
                let advertiser = self.serviceContainer.bonjourAdvertiser
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    advertiser.start(
                        name: serverName,
                        httpsPort: httpsPort,
                        httpPort: 8080,
                        hostname: hostname
                    )
                }
            } catch {
                let boundaryError = RemoteDeployError.serverStartFailed(reason: error.localizedDescription)
                self.appState.setError(boundaryError)
                Logger.server.error("Server failed to start: \(boundaryError.failureReason ?? "", privacy: .public)")
            }
        }
    }

    /// Brings HTTPS into line with the current settings after a settings write.
    /// TKT-060 (Phase 6): the menu bar used to post `.restartServerRequested`
    /// in-process to rebind on a port/cert change; across processes it can't reach
    /// this server, so reconcile does it: start when certs first appear, and
    /// restart when the bound port or cert/key path actually changed (a no-op write
    /// -- e.g. the hostname poll -- does not churn the listener). TKT-071: the
    /// config now carries a fingerprint of the cert contents, so a cert REPLACED at
    /// the same path (an auto-renewal) is also detected and reloaded without a
    /// manual relaunch.
    private func reconcileHTTPS() {
        let certsPresent = !appState.certPath.isEmpty && !appState.keyPath.isEmpty
        guard certsPresent else { return }

        let desired = currentHTTPSConfig()

        guard appState.serverRunning else {
            startServer()
            return
        }
        guard runningHTTPSConfig != desired else { return }

        guard let nioServer = serviceContainer.deployServer as? NIODeployServer else { return }
        Task { @MainActor [weak self] in
            await nioServer.stopHTTPS()
            self?.appState.serverRunning = false
            self?.runningHTTPSConfig = nil
            self?.startServer()
        }
    }

    /// Snapshots the current HTTPS settings into a config, including a fingerprint of
    /// the cert file so an in-place renewal is detected as a change. TKT-071.
    private func currentHTTPSConfig() -> HTTPSConfig {
        HTTPSConfig(
            port: appState.serverPort,
            certPath: appState.certPath,
            keyPath: appState.keyPath,
            certFingerprint: Self.certFingerprint(path: appState.certPath)
        )
    }

    /// Returns a SHA-256 hex digest of the cert file's contents, or "" if the file
    /// is missing/unreadable. Cheap on a ~3KB PEM; this is the "did the cert change"
    /// signal `reconcileHTTPS` keys off. TKT-071.
    private static func certFingerprint(path: String) -> String {
        guard !path.isEmpty, let data = FileManager.default.contents(atPath: path) else { return "" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - API Router

    /// Builds real adapters for every injectable seam and hands them to
    /// `APIRouterFactory`.
    private func configureAPIRouter(on server: any DeployServerProtocol, buildManager: BuildManager, services: ServiceContainer) {
        guard let nioServer = server as? NIODeployServer else { return }
        guard let coordinator = services.buildCoordinator else {
            Logger.server.error("configureAPIRouter called before BuildCoordinator was constructed")
            return
        }

        // TKT-055 (Phase 2): the API reads the stores directly -- no AppState
        // snapshot. BuildManager remains the build-status source.
        let buildStatusProvider = BuildManagerBuildStatusProvider(buildManager: buildManager)

        let deps = APIRouterFactory.Dependencies(
            deviceStore: services.pairedDeviceStore,
            projectStore: services.projectStore,
            installTracker: services.installTracker,
            schemeDetector: XcodebuildSchemeDetector(),
            statusProvider: ServerStatusProvider(
                settingsStore: services.settingsStore,
                runtimeStatus: services.runtimeStatus,
                deployServer: nioServer,
                buildStatusProvider: buildStatusProvider
            ),
            buildTrigger: DirectBuildTrigger(projectStore: services.projectStore, coordinator: coordinator),
            buildStatus: buildStatusProvider,
            buildCanceler: CoordinatorBuildCanceler(coordinator: coordinator),
            buildHistory: EmptyBuildHistoryProvider(store: services.buildHistoryStore),
            settingsProvider: services.settingsStore,
            settingsUpdater: DeferredSettingsUpdater(settingsStore: services.settingsStore),
            serverName: Host.current().localizedName ?? "Mac",
            // TKT-060 (Phase 6): server-owned cert provisioning + IPA upload so
            // the menu bar drives both over the API rather than in-process. TKT-071:
            // the same provisioner instance backs the renewal timer, so its
            // in-progress guard dedupes API- and timer-triggered provisions.
            certProvisioner: services.certProvisioner,
            ipaImporter: services.ipaImporter,
            serveDirectory: APIRouterFactory.defaultServeDirectory
        )

        let output = APIRouterFactory.make(deps: deps)
        nioServer.apiRouter = output.router
        services.pairingHandler = output.pairingHandler

        // TKT-011: share the REST routes' AuthMiddleware with the WebSocket upgrade
        // path so both enforce the same paired-device token validation.
        let auth = output.auth
        nioServer.webSocketAuthenticator = { headers in
            auth.authenticateWebSocket(headers: headers) != nil
        }

        // Make the "buildstatus" WS channel stateful: any client that subscribes
        // is immediately sent the current status. A client that reconnects after
        // a build ended would otherwise miss the terminal broadcast and stay
        // stuck on a stale "building" view (the spinning, un-cancellable "Cancel
        // Build" button). Reads the same in-process status source as the REST
        // poll, off the event loop -- BuildStatus is a Sendable value load.
        nioServer.webSocketManager.setBuildStatusReplay {
            let info = buildStatusProvider.currentBuildStatus()
            guard let data = try? JSONEncoder().encode(info) else { return nil }
            return String(data: data, encoding: .utf8)
        }
    }

    // MARK: - Loopback token (TKT-060 Phase 6)

    /// Mints the loopback bearer token the menu bar uses to talk to this server,
    /// persists its hash as a "Menu bar (local)" paired device (so this server's
    /// AuthMiddleware accepts it), and writes the RAW token to LoopbackTokenStore
    /// (0600) for the separate menu bar process to read.
    ///
    /// A fresh token is minted each launch, replacing any prior local record so
    /// exactly one menu bar token is valid at a time; the menu bar re-reads the
    /// file and reconnects when the token rotates (e.g. after a server relaunch).
    private func mintLoopbackToken() {
        let store = serviceContainer.pairedDeviceStore
        let rawToken = JSONPairedDeviceStore.generateToken()
        let tokenHash = JSONPairedDeviceStore.hashToken(rawToken)

        do {
            // Revoke any stale local records so only the current token is valid.
            let existing = (try? store.loadDevices()) ?? []
            for device in existing where device.name == LoopbackTokenStore.deviceName {
                try? store.delete(deviceID: device.id)
            }
            try store.save(device: PairedDevice(name: LoopbackTokenStore.deviceName, tokenHash: tokenHash))
            try LoopbackTokenStore.write(rawToken)
        } catch {
            Logger.server.error("Failed to persist loopback token: \(error.localizedDescription, privacy: .public)")
        }
    }
}
