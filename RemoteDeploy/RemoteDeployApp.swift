import SwiftUI
import AppKit
import os
import RemoteDeployShared

/// RemoteDeploy — A macOS menu bar app for one-click iOS app deployment over Tailscale.
///
/// This is the app entry point. It creates a menu bar item (no dock icon, no main window)
/// and manages the app's lifecycle including the HTTPS server, build engine, and settings.
///
/// Startup work (settings load, project load, Tailscale check, server start, status polling)
/// runs from `AppDelegate.applicationDidFinishLaunching(_:)` via `@NSApplicationDelegateAdaptor`
/// so the server is listening the moment the app finishes launching, NOT when the user
/// first clicks the menu bar icon. TKT-019.
@main
struct RemoteDeployApp: App {
    @StateObject private var appState = AppState()
    @StateObject private var serviceContainer = ServiceContainer()
    @StateObject private var buildManager = BuildManager()

    /// TKT-056 (Phase 3): the menu bar's API client over loopback. Created here
    /// and `configure`d by AppDelegate at startup once the loopback token exists.
    @StateObject private var menuBarClient = MenuBarClient()

    /// AppDelegate wired up via SwiftUI's @NSApplicationDelegateAdaptor so we can run
    /// startup logic in `applicationDidFinishLaunching(_:)` — independent of whether
    /// the user has clicked the menu bar icon yet.
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // Wire state objects into the delegate on every body evaluation. The delegate
        // itself only triggers startup once per launch, so repeated calls are cheap.
        //
        // TKT-021: register() must stay here (not in .onAppear) because
        // .onAppear on MenuBarExtra content only fires when the popover first
        // renders (= first user click), which would regress TKT-019 — the
        // server has to start at launch, not on first click. register() itself
        // is side-effect-free in this context; the startup Task it spawns is
        // deferred via DispatchQueue.main.async inside AppDelegate so it runs
        // strictly after SwiftUI's first layout pass, avoiding the
        // _NSDetectedLayoutRecursion warning.
        let _ = appDelegate.register(
            appState: appState,
            serviceContainer: serviceContainer,
            buildManager: buildManager,
            menuBarClient: menuBarClient
        )

        // Menu bar item — the primary (and only) UI entry point
        MenuBarExtra {
            MenuBarView()
                .environmentObject(appState)
                .environmentObject(serviceContainer)
                .environmentObject(buildManager)
                .environmentObject(menuBarClient)
        } label: {
            Label("RemoteDeploy", systemImage: menuBarClient.menuBarIconName)
        }
        .menuBarExtraStyle(.window)

        // Settings window — opened from menu bar
        Settings {
            SettingsView()
                .environmentObject(appState)
                .environmentObject(serviceContainer)
                .environmentObject(menuBarClient)
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
            // TKT-060 (Phase 6): the wizard is a pure API client now.
            .environmentObject(menuBarClient)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 600, height: 520)

        // Build log — opens as a standalone window
        Window("Build Log", id: "build-log") {
            BuildLogView()
                .environmentObject(serviceContainer)
                .environmentObject(buildManager)
                .environmentObject(menuBarClient)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 600, height: 400)
    }
}

// MARK: - Service Container

/// Dependency injection container that holds all service instances.
/// Protocols are used everywhere so implementations can be swapped (e.g., for testing).
@MainActor
final class ServiceContainer: ObservableObject {
    /// Build engine router that dispatches to the appropriate engine
    /// (Xcode or Expo) based on project type. TKT-048.
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

    /// Thread-safe single source of truth for app settings (settings.json).
    /// Read directly by the API; the menu bar saves route through it. TKT-055.
    let settingsStore: SettingsStore

    /// Live, non-persisted runtime status (Tailscale connectivity) the API status
    /// endpoint reports. Written by AppDelegate's poll. TKT-055.
    let runtimeStatus: RuntimeStatusStore

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

    /// Persistent store for the last N completed build results. TKT-008.
    let buildHistoryStore: any BuildHistoryStoring

    /// QR code generator for device pairing.
    let qrCodeGenerator: QRCodeGenerator

    /// Bonjour advertiser for local network discovery.
    let bonjourAdvertiser: BonjourAdvertiser

    /// Pairing route handler reference for registering pending tokens.
    /// Set by AppDelegate when the API router is configured.
    var pairingHandler: PairingRouteHandler?

    /// View-independent build owner. Constructed by AppDelegate at startup (once
    /// AppState + BuildManager exist) and shared by the API adapters and the menu
    /// bar build button so neither drives builds through a view. TKT-054.
    var buildCoordinator: BuildCoordinator?

    init() {
        let manifestGen = ManifestGenerator()
        let installPageGen = InstallPageGenerator()

        self.buildEngine = BuildEngineRouter()
        self.deployServer = NIODeployServer(
            manifestGenerator: manifestGen,
            installPageGenerator: installPageGen
        )
        self.tailscaleProvider = CLITailscaleProvider()
        self.manifestGenerator = manifestGen
        self.installPageGenerator = installPageGen
        self.projectStore = UserDefaultsProjectStore()
        self.settingsStore = SettingsStore()
        self.runtimeStatus = RuntimeStatusStore()
        self.certificateProvider = TailscaleCertificateProvider()
        self.installTracker = ServerInstallTracker()
        self.notificationManager = NotificationManager.shared
        self.pushNotifiers = []
        self.ipaImporter = IPAImporter()
        self.pairedDeviceStore = JSONPairedDeviceStore()
        self.buildHistoryStore = JSONBuildHistoryStore()
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
                Logger.notifications.error("Push notification failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

// MARK: - Notification Names

extension Notification.Name {
    /// Posted when the setup wizard or other UI requests that the server be started
    /// and settings be saved. Handled by AppDelegate.
    static let startServerRequested = Notification.Name("RemoteDeploy.startServerRequested")
    /// Posted when settings have been changed and need to be persisted.
    static let saveSettingsRequested = Notification.Name("RemoteDeploy.saveSettingsRequested")
    /// Posted at launch to open the setup assistant window when no projects exist.
    static let openSetupAssistant = Notification.Name("RemoteDeploy.openSetupAssistant")
    /// Posted when the menu bar popover opens to trigger a fresh Tailscale status check.
    static let refreshTailscaleStatus = Notification.Name("RemoteDeploy.refreshTailscaleStatus")
    /// Posted from the Server settings tab to stop and restart the HTTPS server.
    static let restartServerRequested = Notification.Name("RemoteDeploy.restartServerRequested")
    /// Posted by the project store after any successful create/update/delete, by
    /// any writer (API on a NIO thread, menu bar on main). AppDelegate observes
    /// this to refresh the menu bar's projection and re-sync the server's slug
    /// registry. TKT-055 (Phase 2): the store is the single source of truth.
    static let projectsDidChange = Notification.Name("RemoteDeploy.projectsDidChange")
    /// Posted by the SettingsStore after any successful settings write, by any
    /// writer (API on a NIO thread, menu bar on main). AppDelegate observes this
    /// to refresh AppState's settings projection. TKT-055 (Phase 2).
    static let settingsDidChange = Notification.Name("RemoteDeploy.settingsDidChange")
}
