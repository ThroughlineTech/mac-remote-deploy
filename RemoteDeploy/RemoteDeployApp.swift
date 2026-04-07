import SwiftUI
import RemoteDeployShared

/// RemoteDeploy — A macOS menu bar app for one-click iOS app deployment over Tailscale.
///
/// This is the app entry point. It creates a menu bar item (no dock icon, no main window)
/// and manages the app's lifecycle including the HTTPS server, build engine, and settings.
@main
struct RemoteDeployApp: App {
    @StateObject private var appState = AppState()
    @StateObject private var serviceContainer = ServiceContainer()

    /// Tracks whether performStartup() has already been called.
    @State private var hasLaunched = false

    /// The directory where settings.json is stored.
    private static var settingsDirectory: String {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!.path
        return "\(appSupport)/RemoteDeploy"
    }

    /// Full path to the settings JSON file.
    private static var settingsFilePath: String {
        "\(settingsDirectory)/settings.json"
    }

    var body: some Scene {
        // Menu bar item — the primary (and only) UI entry point
        MenuBarExtra {
            MenuBarView()
                .environmentObject(appState)
                .environmentObject(serviceContainer)
                .task {
                    // Guard ensures startup runs only once across popover open/close cycles
                    guard !hasLaunched else { return }
                    hasLaunched = true
                    await performStartup()
                }
                .onReceive(NotificationCenter.default.publisher(for: .startServerRequested)) { _ in
                    saveSettings()
                    startServer()
                }
                .onReceive(NotificationCenter.default.publisher(for: .saveSettingsRequested)) { _ in
                    saveSettings()
                }
        } label: {
            Label("RemoteDeploy", systemImage: appState.menuBarIconName)
        }
        .menuBarExtraStyle(.window)

        // Settings window — opened from menu bar
        Settings {
            SettingsView()
                .environmentObject(appState)
                .environmentObject(serviceContainer)
        }

        // Setup assistant — opens as a standalone window (not a sheet)
        Window("Setup Assistant", id: "setup-assistant") {
            SetupAssistantView(
                appState: appState,
                onDismiss: {
                    // Close the window by toggling the flag
                    appState.showSetupAssistant = false
                },
                onStartServer: {
                    NotificationCenter.default.post(name: .startServerRequested, object: nil)
                }
            )
            .environmentObject(serviceContainer)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 600, height: 520)

        // Build log — opens as a standalone window
        Window("Build Log", id: "build-log") {
            BuildLogView(appState: appState)
                .environmentObject(serviceContainer)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 600, height: 400)
    }

    // MARK: - Startup

    /// Runs once at launch: loads settings, checks Tailscale, loads projects,
    /// starts the server if configured, and begins periodic status polling.
    private func performStartup() async {
        // Request notification permissions
        serviceContainer.notificationManager.requestPermission()

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
        // Post a notification so the MenuBarView can call openWindow(id:).
        if appState.projects.isEmpty {
            NotificationCenter.default.post(name: .openSetupAssistant, object: nil)
        }

        // Start periodic Tailscale status polling (every 30 seconds)
        startStatusPolling()
    }

    /// Loads projects from the persistent store into app state.
    private func loadSavedProjects() {
        do {
            let projects = try serviceContainer.projectStore.loadProjects()
            appState.projects = projects
            if let first = projects.first {
                appState.selectedProjectID = first.id
            }
        } catch {
            print("Failed to load projects: \(error.localizedDescription)")
        }
    }

    /// Queries Tailscale CLI to update connection status and hostname.
    private func checkTailscaleStatus() async {
        do {
            let connected = await serviceContainer.tailscaleProvider.isConnected()
            appState.tailscaleConnected = connected

            if connected {
                let hostname = try await serviceContainer.tailscaleProvider.detectHostname()
                appState.hostname = hostname
                let port = appState.serverPort
                appState.serverURL = "https://\(hostname):\(port)"
            } else {
                // No Tailscale — use local IP so QR codes and the API still work
                if let localIP = QRCodeGenerator.localIPAddress() {
                    appState.serverURL = "http://\(localIP):8080"
                }
            }
        } catch {
            appState.tailscaleConnected = false
            // Fall back to local IP
            if let localIP = QRCodeGenerator.localIPAddress() {
                appState.serverURL = "http://\(localIP):8080"
            }
            print("Tailscale check failed: \(error.localizedDescription)")
        }
    }

    /// Polls Tailscale status every 30 seconds using an async Task loop.
    private func startStatusPolling() {
        Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                await checkTailscaleStatus()
            }
        }
    }

    // MARK: - Settings Persistence

    /// Loads settings from the JSON file on disk and applies them to AppState.
    private func loadSettings() {
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
            print("Failed to load settings: \(error.localizedDescription)")
        }
    }

    /// Persists current AppState settings to the JSON file on disk.
    func saveSettings() {
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
            print("Failed to save settings: \(error.localizedDescription)")
        }
    }

    // MARK: - Server Lifecycle

    /// Starts the HTTPS deploy server if certificates are configured and the server is not already running.
    /// Registers all known projects, wires up the API router, and sets up the IPA download callback.
    func startServer() {
        guard !appState.certPath.isEmpty, !appState.keyPath.isEmpty else { return }
        guard !appState.serverRunning else { return }

        let server = serviceContainer.deployServer

        // Register all known projects so their routes are available
        for project in appState.projects {
            server.registerProject(project)
        }
        server.setBaseURL(appState.serverURL)

        // Configure the API router for companion device access
        configureAPIRouter(on: server, appState: appState, services: serviceContainer)

        // Wire up IPA download callback for install tracking
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

        Task {
            do {
                try await server.start(
                    port: appState.serverPort,
                    certPath: appState.certPath,
                    keyPath: appState.keyPath
                )
                await MainActor.run {
                    appState.serverRunning = true
                }

                // Start Bonjour advertisement for local network discovery
                serviceContainer.bonjourAdvertiser.start(
                    name: Host.current().localizedName ?? "RemoteDeploy",
                    httpsPort: appState.serverPort,
                    httpPort: 8080,
                    hostname: appState.hostname
                )
            } catch {
                print("Server failed to start: \(error)")
            }
        }
    }
}

    /// Configures the API router on the deploy server with all route handlers.
    @MainActor private func configureAPIRouter(on server: any DeployServerProtocol, appState: AppState, services: ServiceContainer) {
        guard let nioServer = server as? NIODeployServer else { return }

        let deviceStore = services.pairedDeviceStore
        let auth = AuthMiddleware(deviceStore: deviceStore)
        let macName = Host.current().localizedName ?? "Mac"

        // Create a thread-safe bridge to read live AppState values from NIO's event loop.
        let stateBridge = AppStateBridge(appState: appState)
        let deployServer = nioServer

        // Build status provider closure — reads live values
        let statusProvider: @Sendable () -> ServerStatus = {
            let snapshot = stateBridge.snapshot()
            return ServerStatus(
                serverRunning: deployServer.isRunning,
                tailscaleConnected: snapshot.tailscaleConnected,
                hostname: snapshot.hostname,
                serverPort: deployServer.port,
                buildStatus: stateBridge.buildStatusInfo()
            )
        }

        // Build trigger closure — posts a notification that MenuBarView handles
        // so the API-triggered build goes through the same flow as the UI button.
        let projectStore = services.projectStore
        let buildTrigger: @Sendable (UUID, String?) -> String? = { projectID, config in
            guard let project = projectStore.project(withID: projectID) else {
                return "Project not found"
            }
            // Post notification on main thread to trigger the same build flow as the UI
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: .apiBuildRequested,
                    object: nil,
                    userInfo: ["projectID": projectID, "configuration": config as Any]
                )
            }
            return nil
        }

        // Settings closures — read live values via bridge
        let settingsProvider: @Sendable () -> SettingsData = {
            stateBridge.settings()
        }

        let settingsUpdater: @Sendable (SettingsData) -> String? = { _ in
            // Settings update from API is deferred for now
            return nil
        }

        // Scheme detection closure
        let schemeDetector: @Sendable (String) -> [String] = { path in
            // Use xcodebuild -list to detect schemes
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/xcodebuild")
            process.arguments = ["-list", "-project", path]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()
            try? process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            // Parse schemes from xcodebuild -list output
            var schemes: [String] = []
            var inSchemes = false
            for line in output.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed == "Schemes:" {
                    inSchemes = true
                } else if inSchemes {
                    if trimmed.isEmpty || trimmed.hasSuffix(":") { break }
                    schemes.append(trimmed)
                }
            }
            return schemes
        }

        let pairingHandler = PairingRouteHandler(deviceStore: deviceStore, serverName: macName)
        let statusHandler = StatusRouteHandler(statusProvider: statusProvider)
        let projectsHandler = ProjectsRouteHandler(projectStore: projectStore)
        let buildHandler = BuildRouteHandler(
            buildTrigger: buildTrigger,
            buildStatusProvider: { stateBridge.buildStatusInfo() },
            buildCanceler: { false },
            buildHistoryProvider: { [] }
        )
        let installsHandler = InstallsRouteHandler(installTracker: services.installTracker)
        let settingsHandler = SettingsRouteHandler(settingsProvider: settingsProvider, settingsUpdater: settingsUpdater)
        let filesystemHandler = FilesystemRouteHandler(schemeDetector: schemeDetector)
        let devicesHandler = DevicesRouteHandler(deviceStore: deviceStore)

        let router = APIRouter(
            auth: auth,
            pairingHandler: pairingHandler,
            statusHandler: statusHandler,
            projectsHandler: projectsHandler,
            buildHandler: buildHandler,
            installsHandler: installsHandler,
            settingsHandler: settingsHandler,
            filesystemHandler: filesystemHandler,
            devicesHandler: devicesHandler
        )

        nioServer.apiRouter = router

        // Store pairingHandler reference for QR code generation
        services.pairingHandler = pairingHandler
    }

// MARK: - Service Container

/// Dependency injection container that holds all service instances.
/// Protocols are used everywhere so implementations can be swapped (e.g., for testing).
@MainActor
final class ServiceContainer: ObservableObject {
    /// Build engine for archiving and exporting IPAs via xcodebuild.
    let buildEngine: any BuildEngineProtocol

    /// HTTPS server that serves install pages, manifests, and IPA files.
    let deployServer: any DeployServerProtocol

    /// Tailscale CLI wrapper for hostname detection and cert management.
    let tailscaleProvider: any TailscaleProviderProtocol

    /// Generates iOS OTA manifest.plist XML.
    let manifestGenerator: any ManifestGenerating

    /// Generates HTML install pages.
    let installPageGenerator: any InstallPageGenerating

    /// Persistent storage for project configurations.
    let projectStore: any ProjectStoring

    /// TLS certificate loader and renewal checker.
    let certificateProvider: any CertificateProviding

    /// Tracks IPA download events.
    let installTracker: any InstallTracking

    /// macOS desktop notification manager.
    let notificationManager: NotificationManager

    /// Active push notification providers (Prowl, Pushover, ntfy).
    var pushNotifiers: [any PushNotifying]

    /// Imports pre-built .ipa files for serving without building.
    let ipaImporter: IPAImporter

    /// Storage for paired companion devices.
    let pairedDeviceStore: any PairedDeviceStoring

    /// QR code generator for device pairing.
    let qrCodeGenerator: QRCodeGenerator

    /// Bonjour advertiser for local network discovery.
    let bonjourAdvertiser: BonjourAdvertiser

    /// Pairing route handler reference for registering pending tokens.
    /// Set by RemoteDeployApp when the API router is configured.
    var pairingHandler: PairingRouteHandler?

    init() {
        let manifestGen = ManifestGenerator()
        let installPageGen = InstallPageGenerator()

        self.buildEngine = XcodeBuildEngine()
        self.deployServer = NIODeployServer(
            manifestGenerator: manifestGen,
            installPageGenerator: installPageGen
        )
        self.tailscaleProvider = CLITailscaleProvider()
        self.manifestGenerator = manifestGen
        self.installPageGenerator = installPageGen
        self.projectStore = UserDefaultsProjectStore()
        self.certificateProvider = TailscaleCertificateProvider()
        self.installTracker = ServerInstallTracker()
        self.notificationManager = NotificationManager.shared
        self.pushNotifiers = []
        self.ipaImporter = IPAImporter()
        self.pairedDeviceStore = JSONPairedDeviceStore()
        self.qrCodeGenerator = QRCodeGenerator()
        self.bonjourAdvertiser = BonjourAdvertiser()
    }

    /// Configures push notifiers based on the user's saved notification settings.
    /// - Parameter config: The push notification configuration from settings.
    func configurePushNotifiers(from config: PushNotificationConfig) {
        var notifiers: [any PushNotifying] = []

        if config.prowlEnabled, !config.prowlAPIKey.isEmpty {
            notifiers.append(ProwlNotifier(apiKey: config.prowlAPIKey))
        }

        if config.pushoverEnabled, !config.pushoverAppToken.isEmpty {
            notifiers.append(PushoverNotifier(appToken: config.pushoverAppToken, userKey: config.pushoverUserKey))
        }

        if config.ntfyEnabled, !config.ntfyServerURL.isEmpty {
            notifiers.append(NtfyNotifier(serverURL: config.ntfyServerURL, topic: config.ntfyTopic))
        }

        self.pushNotifiers = notifiers
    }

    /// Sends a push notification to all active providers.
    /// - Parameters:
    ///   - title: Notification title
    ///   - message: Notification body text
    ///   - priority: Urgency level
    ///   - url: Optional clickable URL (e.g., install link)
    func sendPushNotification(title: String, message: String, priority: PushPriority, url: String? = nil) async {
        for notifier in pushNotifiers {
            do {
                try await notifier.send(title: title, message: message, priority: priority, url: url)
            } catch {
                print("Push notification failed: \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - AppState Extension

extension AppState {
    /// Returns the appropriate SF Symbol name for the menu bar icon based on server state.
    var menuBarIconName: String {
        if !tailscaleConnected {
            return "antenna.radiowaves.left.and.right.slash"
        }
        if serverRunning {
            return "shippingbox.fill"
        }
        return "shippingbox"
    }
}

// MARK: - AppState Bridge

/// Thread-safe bridge for reading AppState values from NIO's event loop.
/// Captures the AppState reference on the MainActor and provides
/// Sendable closures that read values synchronously.
final class AppStateBridge: @unchecked Sendable {
    private let _snapshot: () -> (hostname: String, tailscaleConnected: Bool, serverPort: Int, certPath: String, keyPath: String, pushConfig: PushNotificationConfig, buildStatus: BuildStatus)

    @MainActor
    init(appState: AppState) {
        // Capture the appState reference. The closure will be called from NIO threads
        // but AppState properties are simple value types so reading is safe.
        nonisolated(unsafe) let state = appState
        self._snapshot = {
            (state.hostname, state.tailscaleConnected, state.serverPort, state.certPath, state.keyPath, state.pushNotificationConfig, state.buildStatus)
        }
    }

    func snapshot() -> (hostname: String, tailscaleConnected: Bool, serverPort: Int) {
        let s = _snapshot()
        return (s.hostname, s.tailscaleConnected, s.serverPort)
    }

    func buildStatusInfo() -> BuildStatusInfo {
        let s = _snapshot()
        switch s.buildStatus {
        case .idle:
            return BuildStatusInfo(state: "idle")
        case .building(let progress):
            return BuildStatusInfo(state: "building", message: progress)
        case .success(let ipaPath):
            return BuildStatusInfo(state: "success", message: ipaPath)
        case .failure(let error):
            return BuildStatusInfo(state: "failure", message: error)
        }
    }

    func settings() -> SettingsData {
        let s = _snapshot()
        return SettingsData(serverPort: s.serverPort, hostname: s.hostname, certPath: s.certPath, keyPath: s.keyPath, pushNotificationConfig: s.pushConfig)
    }
}

// MARK: - Notification Names

extension Notification.Name {
    /// Posted when the setup wizard or other UI requests that the server be started
    /// and settings be saved. Handled by RemoteDeployApp.
    static let startServerRequested = Notification.Name("RemoteDeploy.startServerRequested")
    /// Posted when settings have been changed and need to be persisted.
    static let saveSettingsRequested = Notification.Name("RemoteDeploy.saveSettingsRequested")
    /// Posted at launch to open the setup assistant window when no projects exist.
    static let openSetupAssistant = Notification.Name("RemoteDeploy.openSetupAssistant")
    /// Posted by the API when a build is triggered remotely from a companion device.
    static let apiBuildRequested = Notification.Name("RemoteDeploy.apiBuildRequested")
}
