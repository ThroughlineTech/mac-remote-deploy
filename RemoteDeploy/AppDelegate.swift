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

    // MARK: - Lifecycle guards

    /// Set to true once performStartup() has run; prevents double-runs if the
    /// system calls applicationDidFinishLaunching multiple times (shouldn't
    /// happen but defensive).
    private var didPerformStartup = false

    /// Set to true once register() has been called with non-nil state objects.
    /// applicationDidFinishLaunching waits up to 2 seconds for this to flip
    /// in case the OS callback fires before SwiftUI has evaluated body.
    private var didRegister = false

    // MARK: - Startup helpers

    /// Directory for settings.json.
    private static var settingsDirectory: String {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!.path
        return "\(appSupport)/RemoteDeploy"
    }

    /// Full path to settings.json.
    private static var settingsFilePath: String {
        "\(settingsDirectory)/settings.json"
    }

    // MARK: - Registration

    /// Called by RemoteDeployApp.body to hand in the SwiftUI-owned state objects.
    /// Idempotent — safe to call on every body evaluation. Stores the references
    /// the first time; subsequent calls are no-ops. The first call also triggers
    /// startup if applicationDidFinishLaunching has already fired and was waiting.
    func register(
        appState: AppState,
        serviceContainer: ServiceContainer,
        buildManager: BuildManager
    ) {
        guard !didRegister else { return }
        self.appState = appState
        self.serviceContainer = serviceContainer
        self.buildManager = buildManager
        self.didRegister = true

        // If the OS lifecycle callback fired before SwiftUI evaluated body,
        // kick off startup now that we finally have the state objects.
        if !didPerformStartup, NSApp != nil {
            Task { @MainActor in
                await self.performStartup()
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

        // If register() has already been called (normal case — SwiftUI body
        // evaluates before applicationDidFinishLaunching), run startup now.
        // Otherwise register() will kick it off when it's eventually called.
        if didRegister, !didPerformStartup {
            Task { @MainActor in
                await self.performStartup()
            }
        }
    }

    // MARK: - Startup

    /// Runs once at launch: loads settings, checks Tailscale, loads projects,
    /// starts the server if configured, and begins periodic status polling.
    private func performStartup() async {
        guard !didPerformStartup else { return }
        didPerformStartup = true

        guard let appState, let serviceContainer, let buildManager else {
            Logger.server.error("AppDelegate.performStartup called before register() completed")
            return
        }

        // Request notification permissions
        serviceContainer.notificationManager.requestPermission()

        // Wire BuildManager's dependencies.
        buildManager.configure(
            buildEngine: serviceContainer.buildEngine,
            deployServer: serviceContainer.deployServer,
            notificationManager: serviceContainer.notificationManager,
            ipaImporter: serviceContainer.ipaImporter,
            buildHistoryStore: serviceContainer.buildHistoryStore
        )
        buildManager.sendPushNotification = { [serviceContainer] title, message, priority, url in
            await serviceContainer.sendPushNotification(title: title, message: message, priority: priority, url: url)
        }

        // Load persisted settings (cert paths, hostname, push config, etc.)
        loadSettings()

        // Load saved projects from disk
        loadSavedProjects()

        // Configure push notifiers from saved config
        serviceContainer.configurePushNotifiers(from: appState.pushNotificationConfig)

        // Check Tailscale status and detect hostname
        await checkTailscaleStatus()

        // Start the HTTPS server if certificates are already configured
        startServer()

        // Show setup assistant if no projects are configured.
        if appState.projects.isEmpty {
            NotificationCenter.default.post(name: .openSetupAssistant, object: nil)
        }

        // Start periodic Tailscale status polling (every 30 seconds)
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

    // MARK: - Loaders

    /// Loads projects from the persistent store into app state.
    private func loadSavedProjects() {
        guard let appState, let serviceContainer else { return }
        do {
            let projects = try serviceContainer.projectStore.loadProjects()
            appState.projects = projects
            if let first = projects.first {
                appState.selectedProjectID = first.id
            }
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

            if connected {
                let hostname = try await serviceContainer.tailscaleProvider.detectHostname()
                appState.hostname = hostname
                let port = appState.serverPort
                appState.serverURL = "https://\(hostname):\(port)"
            } else {
                if let localIP = QRCodeGenerator.localIPAddress() {
                    appState.serverURL = "http://\(localIP):8080"
                }
            }
        } catch {
            appState.tailscaleConnected = false
            if let localIP = QRCodeGenerator.localIPAddress() {
                appState.serverURL = "http://\(localIP):8080"
            }
            let boundaryError = RemoteDeployError.networkError(reason: error.localizedDescription)
            // Not setting appState.error: "Tailscale not connected" is a normal state.
            Logger.tailscale.error("Tailscale check failed: \(boundaryError.failureReason ?? "", privacy: .public)")
        }
    }

    /// Polls Tailscale status every 30 seconds using an async Task loop.
    private func startStatusPolling() {
        Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                await self?.checkTailscaleStatus()
            }
        }
    }

    // MARK: - Settings Persistence

    /// Loads settings from the JSON file on disk and applies them to AppState.
    private func loadSettings() {
        guard let appState else { return }
        let path = Self.settingsFilePath
        guard FileManager.default.fileExists(atPath: path),
              let data = FileManager.default.contents(atPath: path) else {
            return
        }
        do {
            let settings = try JSONDecoder().decode(SettingsData.self, from: data)
            appState.serverPort = settings.serverPort
            appState.hostname = settings.hostname
            appState.certPath = settings.certPath
            appState.keyPath = settings.keyPath
            appState.pushNotificationConfig = settings.pushNotificationConfig
            if !settings.hostname.isEmpty {
                appState.serverURL = "https://\(settings.hostname):\(settings.serverPort)"
            }
        } catch {
            let boundaryError = RemoteDeployError(wrapping: error)
            appState.setError(boundaryError)
            Logger.storage.error("Failed to load settings: \(boundaryError.localizedDescription, privacy: .public)")
        }
    }

    /// Persists current AppState settings to the JSON file on disk.
    private func saveSettings() {
        guard let appState else { return }
        let settings = SettingsData(
            serverPort: appState.serverPort,
            hostname: appState.hostname,
            certPath: appState.certPath,
            keyPath: appState.keyPath,
            pushNotificationConfig: appState.pushNotificationConfig
        )
        do {
            let dir = Self.settingsDirectory
            try FileManager.default.createDirectory(
                atPath: dir,
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(settings)
            try data.write(to: URL(fileURLWithPath: Self.settingsFilePath))
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: Self.settingsFilePath
            )
        } catch {
            let boundaryError = RemoteDeployError(wrapping: error)
            appState.setError(boundaryError)
            Logger.storage.error("Failed to save settings: \(boundaryError.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Server Lifecycle

    /// Starts the HTTPS deploy server if certificates are configured and not already running.
    private func startServer() {
        guard let appState, let serviceContainer, let buildManager else { return }
        guard !appState.certPath.isEmpty, !appState.keyPath.isEmpty else { return }
        guard !appState.serverRunning else { return }

        let server = serviceContainer.deployServer

        for project in appState.projects {
            server.registerProject(project)
        }
        server.setBaseURL(appState.serverURL)

        configureAPIRouter(on: server, appState: appState, buildManager: buildManager, services: serviceContainer)

        server.onIPADownload = { [weak appState, serviceContainer] slug, ip, ua in
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
            }
        }

        Task { @MainActor [weak self] in
            do {
                try await server.start(
                    port: appState.serverPort,
                    certPath: appState.certPath,
                    keyPath: appState.keyPath
                )
                appState.serverRunning = true

                serviceContainer.bonjourAdvertiser.start(
                    name: Host.current().localizedName ?? "RemoteDeploy",
                    httpsPort: appState.serverPort,
                    httpPort: 8080,
                    hostname: appState.hostname
                )
            } catch {
                let boundaryError = RemoteDeployError.serverStartFailed(reason: error.localizedDescription)
                self?.appState?.setError(boundaryError)
                Logger.server.error("Server failed to start: \(boundaryError.failureReason ?? "", privacy: .public)")
            }
        }
    }

    // MARK: - API Router

    /// Configures the API router on the deploy server by building real adapters
    /// for every injectable seam and handing them to `APIRouterFactory`.
    private func configureAPIRouter(on server: any DeployServerProtocol, appState: AppState, buildManager: BuildManager, services: ServiceContainer) {
        guard let nioServer = server as? NIODeployServer else { return }

        let bridge = AppStateBridge(appState: appState, buildManager: buildManager)

        let deps = APIRouterFactory.Dependencies(
            deviceStore: services.pairedDeviceStore,
            projectStore: services.projectStore,
            installTracker: services.installTracker,
            schemeDetector: XcodebuildSchemeDetector(),
            statusProvider: AppStateStatusProvider(bridge: bridge, deployServer: nioServer),
            buildTrigger: NotificationBuildTrigger(projectStore: services.projectStore),
            buildStatus: AppStateBridgeBuildStatusProvider(bridge: bridge),
            buildCanceler: NoopBuildCanceler(),
            buildHistory: EmptyBuildHistoryProvider(store: services.buildHistoryStore),
            settingsProvider: AppStateBridgeSettingsProvider(bridge: bridge),
            settingsUpdater: DeferredSettingsUpdater(
                bridge: bridge,
                applyOnMain: { [weak appState] settings in
                    DispatchQueue.main.async {
                        guard let appState else { return }
                        appState.serverPort = settings.serverPort
                        appState.hostname = settings.hostname
                        appState.certPath = settings.certPath
                        appState.keyPath = settings.keyPath
                        appState.pushNotificationConfig = settings.pushNotificationConfig
                        NotificationCenter.default.post(name: .saveSettingsRequested, object: nil)
                    }
                }
            ),
            serverName: Host.current().localizedName ?? "Mac"
        )

        let output = APIRouterFactory.make(deps: deps)
        nioServer.apiRouter = output.router
        services.pairingHandler = output.pairingHandler
    }
}
