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

    /// AppDelegate wired up via SwiftUI's @NSApplicationDelegateAdaptor so we can run
    /// startup logic in `applicationDidFinishLaunching(_:)` — independent of whether
    /// the user has clicked the menu bar icon yet.
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // Wire state objects into the delegate on every body evaluation. The delegate
        // itself only triggers startup once per launch, so repeated calls are cheap.
        let _ = appDelegate.register(
            appState: appState,
            serviceContainer: serviceContainer,
            buildManager: buildManager
        )

        // Menu bar item — the primary (and only) UI entry point
        MenuBarExtra {
            MenuBarView()
                .environmentObject(appState)
                .environmentObject(serviceContainer)
                .environmentObject(buildManager)
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
            BuildLogView()
                .environmentObject(serviceContainer)
                .environmentObject(buildManager)
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

    /// Persistent store for the last N completed build results. TKT-008.
    let buildHistoryStore: any BuildHistoryStoring

    /// QR code generator for device pairing.
    let qrCodeGenerator: QRCodeGenerator

    /// Bonjour advertiser for local network discovery.
    let bonjourAdvertiser: BonjourAdvertiser

    /// Pairing route handler reference for registering pending tokens.
    /// Set by AppDelegate when the API router is configured.
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
    init(appState: AppState, buildManager: BuildManager) {
        // Capture both references. Closures will be called from NIO threads but
        // the fields we read are simple value types so reading is safe.
        nonisolated(unsafe) let state = appState
        nonisolated(unsafe) let manager = buildManager
        self._snapshot = {
            (state.hostname, state.tailscaleConnected, state.serverPort, state.certPath, state.keyPath, state.pushNotificationConfig, manager.buildStatus)
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
    /// and settings be saved. Handled by AppDelegate.
    static let startServerRequested = Notification.Name("RemoteDeploy.startServerRequested")
    /// Posted when settings have been changed and need to be persisted.
    static let saveSettingsRequested = Notification.Name("RemoteDeploy.saveSettingsRequested")
    /// Posted at launch to open the setup assistant window when no projects exist.
    static let openSetupAssistant = Notification.Name("RemoteDeploy.openSetupAssistant")
    /// Posted by the API when a build is triggered remotely from a companion device.
    static let apiBuildRequested = Notification.Name("RemoteDeploy.apiBuildRequested")
}
