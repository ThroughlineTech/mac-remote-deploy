// App delegate that runs startup work in applicationDidFinishLaunching
// rather than deferring it to the MenuBarExtra popover's .task modifier
// (which only fires on first click). Fixes TKT-019: the server now
// starts at actual launch, not on first icon click.
//
// The delegate is instantiated by SwiftUI via @NSApplicationDelegateAdaptor
// on RemoteDeployApp. The App struct's body calls `register(...)` to hand
// the @StateObject state objects to the delegate before
// applicationDidFinishLaunching fires.
import Foundation
import AppKit
import SwiftUI
import os
import RemoteDeployShared

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    // MARK: - Injected state (set by RemoteDeployApp.body via register)

    private var appState: AppState?
    private var serviceContainer: ServiceContainer?
    private var buildManager: BuildManager?
    private var menuBarClient: MenuBarClient?

    /// Loopback base URL the menu bar uses to talk to its own server. The local
    /// HTTP listener binds on :8080 (plain HTTP); pairing over HTTP is blocked
    /// but the menu bar uses a pre-seeded token, so it never calls /pair.
    private static let loopbackBaseURL = URL(string: "http://127.0.0.1:8080")!

    /// The cert/port HTTPS is currently bound with, so a settings change can
    /// tell whether HTTPS needs to (re)start. Nil when HTTPS is not running.
    /// TKT-056 (Phase 3).
    private var runningHTTPSConfig: HTTPSConfig?

    private struct HTTPSConfig: Equatable {
        let port: Int
        let certPath: String
        let keyPath: String
    }

    // MARK: - Lifecycle guards

    /// Set to true once performStartup() has run; prevents double-runs if the
    /// system calls applicationDidFinishLaunching multiple times (shouldn't
    /// happen but defensive).
    /// Exposed `internal` for AppDelegateStartupTests (TKT-019).
    internal private(set) var didPerformStartup = false

    /// Set to true once register() has been called with non-nil state objects.
    /// applicationDidFinishLaunching waits up to 2 seconds for this to flip
    /// in case the OS callback fires before SwiftUI has evaluated body.
    private var didRegister = false

    /// Test-only override: when non-nil, `performStartup()` invokes this
    /// closure instead of the real startup body. Lets AppDelegateStartupTests
    /// verify the register/launch ordering guards without triggering real
    /// side effects (Tailscale CLI, file I/O, server bind). TKT-019.
    internal var performStartupOverrideForTests: (@MainActor () async -> Void)?

    // MARK: - Registration

    /// Called by RemoteDeployApp.body to hand in the SwiftUI-owned state objects.
    /// Idempotent — safe to call on every body evaluation. Stores the references
    /// the first time; subsequent calls are no-ops. The first call also triggers
    /// startup if applicationDidFinishLaunching has already fired and was waiting.
    func register(
        appState: AppState,
        serviceContainer: ServiceContainer,
        buildManager: BuildManager,
        menuBarClient: MenuBarClient
    ) {
        guard !didRegister else { return }
        self.appState = appState
        self.serviceContainer = serviceContainer
        self.buildManager = buildManager
        self.menuBarClient = menuBarClient
        self.didRegister = true

        // If the OS lifecycle callback fired before SwiftUI evaluated body,
        // kick off startup now that we finally have the state objects.
        //
        // TKT-021 / TKT-024 Commit 5a: a plain `DispatchQueue.main.async` hop
        // wasn't enough to escape the MenuBarExtra's first layout pass — on
        // device the `_NSDetectedLayoutRecursion` warning still fired. Bumping
        // to an explicit 150ms `asyncAfter` gives AppKit room to complete its
        // initial layout before any @Published mutations from performStartup()
        // hit. 150ms is imperceptible to the user at launch.
        if !didPerformStartup, NSApp != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                Task { @MainActor [weak self] in
                    await self?.performStartup()
                }
            }
        }
    }

    // MARK: - NSApplicationDelegate

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Install NotificationCenter observers for server/settings requests
        // from other parts of the app. These previously lived on MenuBarView.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleStartServerRequested),
            name: .startServerRequested,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSaveSettingsRequested),
            name: .saveSettingsRequested,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleRefreshTailscaleStatus),
            name: .refreshTailscaleStatus,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleRestartServerRequested),
            name: .restartServerRequested,
            object: nil
        )
        // TKT-055 (Phase 2): the stores are the single source of truth. Refresh
        // the menu bar's projections (and the server's slug registry) whenever
        // any writer -- the API on a NIO thread or the menu bar on main --
        // mutates the project store or settings store.
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

        // If register() has already been called (normal case — SwiftUI body
        // evaluates before applicationDidFinishLaunching), run startup now.
        // Otherwise register() will kick it off when it's eventually called.
        //
        // TKT-021 / TKT-024 Commit 5a: 150ms asyncAfter (not plain async) so
        // startup's @Published mutations don't interleave with the
        // MenuBarExtra's first layout pass. See register() for the rationale.
        if didRegister, !didPerformStartup {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                Task { @MainActor [weak self] in
                    await self?.performStartup()
                }
            }
        }
    }

    // MARK: - Termination

    /// Synchronously stop the NIO server and Bonjour advertiser to release
    /// ports before exit. This lets graceful-relaunch.sh confirm port release
    /// instead of relying on the OS to reclaim them. TKT-050.
    func applicationWillTerminate(_ notification: Notification) {
        guard let serviceContainer else { return }

        serviceContainer.bonjourAdvertiser.stop()

        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            await serviceContainer.deployServer.stop()
            semaphore.signal()
        }
        semaphore.wait(timeout: .now() + 3)
    }

    // MARK: - Startup

    /// Runs once at launch: loads settings, checks Tailscale, loads projects,
    /// starts the server if configured, and begins periodic status polling.
    private func performStartup() async {
        guard !didPerformStartup else { return }
        didPerformStartup = true

        // Test seam: AppDelegateStartupTests uses this to assert the
        // register/launch ordering guards without touching real services. TKT-019.
        if let override = performStartupOverrideForTests {
            await override()
            return
        }

        guard let appState, let serviceContainer, let buildManager else {
            Logger.server.error("AppDelegate.performStartup called before register() completed")
            return
        }

        // Request notification permissions
        serviceContainer.notificationManager.requestPermission()

        // Wire BuildManager's dependencies.
        // TKT-027: the deploy server (NIODeployServer) also acts as the
        // BuildEventBroadcasting sink, so live build log lines and status
        // transitions fan out to subscribed WebSocket clients.
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

        // Construct the view-independent build owner now that AppState and
        // BuildManager exist. Shared by the API adapters and the menu bar build
        // button so neither drives a build through a view. TKT-054.
        serviceContainer.buildCoordinator = BuildCoordinator(
            buildManager: buildManager,
            projectStore: serviceContainer.projectStore,
            config: appState,
            buildEngine: serviceContainer.buildEngine
        )

        // Load persisted settings (cert paths, hostname, push config, etc.)
        loadSettings()

        // Load saved projects from the store into the menu bar projection.
        refreshProjectsFromStore()

        // Configure push notifiers from saved config
        serviceContainer.configurePushNotifiers(from: appState.pushNotificationConfig)

        // Check Tailscale status and detect hostname
        await checkTailscaleStatus()

        // TKT-056 (Phase 3): configure the API router and bring up the always-on
        // plain-HTTP API listener on :8080 so the menu bar (and local-WiFi
        // companions) can reach the API even before TLS certs are configured.
        await prepareServer()

        // Start the HTTPS install server if certificates are already configured.
        startServer()

        // TKT-056 (Phase 3): mint the loopback token and point the menu bar's
        // API client at its own server. Safe to do before HTTPS is up -- the
        // client reaches the API over the loopback HTTP listener.
        configureMenuBarClient()

        // Show setup assistant if no projects are configured.
        if appState.projects.isEmpty {
            NotificationCenter.default.post(name: .openSetupAssistant, object: nil)
        }

        // Start periodic Tailscale status polling (every 10 seconds)
        startStatusPolling()
    }

    // MARK: - NotificationCenter handlers

    @objc private func handleStartServerRequested() {
        saveSettings()
        startServer()
    }

    @objc private func handleSaveSettingsRequested() {
        saveSettings()
    }

    /// Triggers a fresh Tailscale status check when the popover opens. TKT-030.
    @objc private func handleRefreshTailscaleStatus() {
        Task { @MainActor [weak self] in
            await self?.checkTailscaleStatus()
        }
    }

    /// Stops the running server, then restarts it with current settings. TKT-037.
    @objc private func handleRestartServerRequested() {
        Task { @MainActor [weak self] in
            guard let self, let appState = self.appState, let serviceContainer = self.serviceContainer,
                  let nioServer = serviceContainer.deployServer as? NIODeployServer else { return }
            // TKT-056 (Phase 3): stop only HTTPS, leaving the :8080 API listener
            // up so the menu bar's client stays connected across the restart.
            // Settings are already persisted (the client PUT them), so just
            // rebind HTTPS with the current config.
            await nioServer.stopHTTPS()
            appState.serverRunning = false
            self.runningHTTPSConfig = nil
            self.startServer()
        }
    }

    /// Refreshes the menu bar's project projection and the server's slug registry
    /// after any writer mutates the project store. Posted from arbitrary threads
    /// (the API runs on a NIO event loop), so hop to the main actor. TKT-055.
    @objc private func handleProjectsDidChange() {
        Task { @MainActor [weak self] in
            self?.refreshProjectsFromStore()
        }
    }

    /// Refreshes AppState's settings projection after any writer mutates the
    /// settings store. Posted from arbitrary threads; hop to the main actor.
    /// TKT-055.
    @objc private func handleSettingsDidChange() {
        Task { @MainActor [weak self] in
            self?.applySettingsFromStore()
            // TKT-056 (Phase 3): a settings write may have set cert paths or
            // changed the port (e.g. via the menu bar's API client). Bring HTTPS
            // into line so the change takes effect without a relaunch.
            self?.reconcileHTTPS()
        }
    }

    // MARK: - Loaders

    /// Refreshes AppState's project projection and the deploy server's slug
    /// registry from the authoritative project store. Called at startup and
    /// whenever any writer posts `.projectsDidChange`. TKT-055 (Phase 2): the
    /// store is the single source of truth; `appState.projects` is a read-only
    /// projection of it.
    private func refreshProjectsFromStore() {
        guard let appState, let serviceContainer else { return }
        do {
            let projects = try serviceContainer.projectStore.loadProjects()
            appState.projects = projects

            // Normalize selection: keep the current project if it still exists,
            // otherwise fall back to the first (or nil when the list is empty).
            if let id = appState.selectedProjectID, !projects.contains(where: { $0.id == id }) {
                appState.selectedProjectID = projects.first?.id
            } else if appState.selectedProjectID == nil {
                appState.selectedProjectID = projects.first?.id
            }

            // Keep the install-page slug registry in sync so a project created or
            // deleted via any path takes effect immediately (no server restart).
            serviceContainer.deployServer.syncProjects(projects)
        } catch {
            let boundaryError = RemoteDeployError(wrapping: error)
            appState.setError(boundaryError)
            Logger.storage.error("Failed to load projects: \(boundaryError.localizedDescription, privacy: .public)")
        }
    }

    /// Queries Tailscale CLI to update connection status and hostname.
    private func checkTailscaleStatus() async {
        guard let appState, let serviceContainer else { return }
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
                // TKT-055: persist the detected hostname through the settings store
                // (the single source of truth the status endpoint reports) only
                // when it actually changed, so the 10s poll doesn't rewrite
                // settings.json every tick.
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
            // Not setting appState.error: "Tailscale not connected" is a normal state.
            Logger.tailscale.error("Tailscale check failed: \(boundaryError.failureReason ?? "", privacy: .public)")
        }
    }

    /// Polls Tailscale status every 10 seconds using an async Task loop.
    private func startStatusPolling() {
        Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                await self?.checkTailscaleStatus()
            }
        }
    }

    // MARK: - Settings Persistence

    /// Applies the settings store's current values into AppState's UI projection.
    /// TKT-055 (Phase 2): the SettingsStore is the single source of truth; this is
    /// the read side, called at startup and whenever `.settingsDidChange` fires
    /// (including writes made by the API).
    private func applySettingsFromStore() {
        guard let appState, let serviceContainer else { return }
        let settings = serviceContainer.settingsStore.current()
        appState.serverPort = settings.serverPort
        appState.hostname = settings.hostname
        appState.certPath = settings.certPath
        appState.keyPath = settings.keyPath
        appState.pushNotificationConfig = settings.pushNotificationConfig
        if !settings.hostname.isEmpty {
            appState.serverURL = "https://\(settings.hostname):\(settings.serverPort)"
        }
        // Keep the deploy server's base URL (used for install-page + manifest
        // absolute URLs) in sync with the current hostname/port. TKT-056.
        serviceContainer.deployServer.setBaseURL(appState.serverURL)
        // TKT-056 (Phase 3): a settings write may have changed push config via
        // the API client, so reconfigure the server process's push notifiers.
        serviceContainer.configurePushNotifiers(from: settings.pushNotificationConfig)
    }

    /// Startup alias for the settings read side. Kept as `loadSettings()` so the
    /// startup sequence reads naturally.
    private func loadSettings() {
        applySettingsFromStore()
    }

    /// Persists current AppState settings by writing them through the settings
    /// store (the single writer). The store persists to disk and posts
    /// `.settingsDidChange`. TKT-055 (Phase 2).
    private func saveSettings() {
        guard let appState, let serviceContainer else { return }
        let settings = SettingsData(
            serverPort: appState.serverPort,
            hostname: appState.hostname,
            certPath: appState.certPath,
            keyPath: appState.keyPath,
            pushNotificationConfig: appState.pushNotificationConfig
        )
        serviceContainer.settingsStore.update(settings)
    }

    // MARK: - Server Lifecycle

    /// Configures the API router and brings up the always-on plain-HTTP API
    /// listener on :8080. Runs once at startup, before HTTPS, so the menu bar's
    /// loopback client (and local-WiFi companions) can reach the API regardless
    /// of whether TLS certs are configured yet. TKT-056 (Phase 3).
    private func prepareServer() async {
        guard let appState, let serviceContainer, let buildManager else { return }
        guard let nioServer = serviceContainer.deployServer as? NIODeployServer else { return }

        nioServer.syncProjects(appState.projects)
        nioServer.setBaseURL(appState.serverURL)

        configureAPIRouter(on: nioServer, buildManager: buildManager, services: serviceContainer)

        // TKT-027: capture the broadcaster here so the onIPADownload closure can
        // fan out install events without reaching back through serviceContainer.
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
                // TKT-027: also fan the install out to WebSocket subscribers.
                broadcaster?.broadcastInstall(slug: slug, sourceIP: ip)
            }
        }

        await nioServer.startAPIListener(httpPort: 8080)
    }

    /// Starts the HTTPS install server if certificates are configured and HTTPS
    /// is not already running. The :8080 API listener is brought up separately
    /// by `prepareServer()`. TKT-056 (Phase 3): HTTPS-only.
    private func startServer() {
        guard let appState, let serviceContainer else { return }
        guard !appState.certPath.isEmpty, !appState.keyPath.isEmpty else { return }
        guard !appState.serverRunning else { return }
        guard let nioServer = serviceContainer.deployServer as? NIODeployServer else { return }

        let config = HTTPSConfig(port: appState.serverPort, certPath: appState.certPath, keyPath: appState.keyPath)

        Task { @MainActor [weak self] in
            do {
                try await nioServer.startHTTPS(
                    port: config.port,
                    certPath: config.certPath,
                    keyPath: config.keyPath
                )
                appState.serverRunning = true
                self?.runningHTTPSConfig = config

                // TKT-021: defer Bonjour advertisement by a short interval so
                // the HTTP listener on :8080 has time to fully finish binding
                // before mDNSResponder is told about the service. Without this,
                // publishing races the bind and Darwin logs two benign but
                // noisy "send failed: Invalid argument" lines at startup.
                let serverName = Host.current().localizedName ?? "RemoteDeploy"
                let httpsPort = config.port
                let hostname = appState.hostname
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    serviceContainer.bonjourAdvertiser.start(
                        name: serverName,
                        httpsPort: httpsPort,
                        httpPort: 8080,
                        hostname: hostname
                    )
                }
            } catch {
                let boundaryError = RemoteDeployError.serverStartFailed(reason: error.localizedDescription)
                self?.appState?.setError(boundaryError)
                Logger.server.error("Server failed to start: \(boundaryError.failureReason ?? "", privacy: .public)")
            }
        }
    }

    /// Brings HTTPS up once certs become available (the bootstrap case: the user
    /// set cert paths via the menu bar's API client). Start-only -- changes to
    /// the port/cert while HTTPS is already running take effect via the explicit
    /// "Restart Server" control, so a per-keystroke settings write does not churn
    /// the listener. TKT-056 (Phase 3).
    private func reconcileHTTPS() {
        guard let appState else { return }
        let certsPresent = !appState.certPath.isEmpty && !appState.keyPath.isEmpty
        guard certsPresent, !appState.serverRunning else { return }
        startServer()
    }

    // MARK: - API Router

    /// Configures the API router on the deploy server by building real adapters
    /// for every injectable seam and handing them to `APIRouterFactory`.
    private func configureAPIRouter(on server: any DeployServerProtocol, buildManager: BuildManager, services: ServiceContainer) {
        guard let nioServer = server as? NIODeployServer else { return }
        guard let coordinator = services.buildCoordinator else {
            Logger.server.error("configureAPIRouter called before BuildCoordinator was constructed")
            return
        }

        // TKT-055 (Phase 2): the API reads the stores directly -- no AppState
        // snapshot. BuildManager remains the build-status source. Settings writes
        // go through the SettingsStore, which posts `.settingsDidChange` so
        // AppState's projection (and the menu bar) refresh.
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
            // the menu bar drives both over the API rather than in-process.
            certProvisioner: TailscaleCertProvisioner(
                tailscaleProvider: services.tailscaleProvider,
                settingsStore: services.settingsStore
            ),
            ipaImporter: services.ipaImporter,
            serveDirectory: APIRouterFactory.defaultServeDirectory
        )

        let output = APIRouterFactory.make(deps: deps)
        nioServer.apiRouter = output.router
        services.pairingHandler = output.pairingHandler

        // TKT-011 / TKT-024 Commit 6: share the REST routes' AuthMiddleware
        // with the WebSocket upgrade path so both enforce the same
        // paired-device token validation.
        let auth = output.auth
        nioServer.webSocketAuthenticator = { headers in
            auth.authenticateWebSocket(headers: headers) != nil
        }
    }

    // MARK: - Menu bar loopback client (TKT-056 Phase 3)

    /// Mints the loopback bearer token the menu bar uses to talk to its own
    /// server, persists its hash as a "Menu bar (local)" paired device, and
    /// points the MenuBarClient at http://127.0.0.1:8080.
    ///
    /// A fresh token is minted each launch (the raw token is not recoverable
    /// from the stored hash), replacing any prior local record so exactly one
    /// menu bar token is valid at a time. The raw token lives only in memory.
    private func configureMenuBarClient() {
        guard let serviceContainer, let menuBarClient else { return }
        let store = serviceContainer.pairedDeviceStore
        let rawToken = JSONPairedDeviceStore.generateToken()
        let tokenHash = JSONPairedDeviceStore.hashToken(rawToken)

        do {
            // Revoke any stale local records so only the current token is valid.
            let existing = (try? store.loadDevices()) ?? []
            for device in existing where device.name == MenuBarClient.localDeviceName {
                try? store.delete(deviceID: device.id)
            }
            try store.save(device: PairedDevice(name: MenuBarClient.localDeviceName, tokenHash: tokenHash))
        } catch {
            Logger.server.error("Failed to persist loopback token: \(error.localizedDescription, privacy: .public)")
        }

        menuBarClient.configure(baseURL: Self.loopbackBaseURL, token: rawToken)
    }
}
