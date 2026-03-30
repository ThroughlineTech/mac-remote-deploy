import SwiftUI

/// RemoteDeploy — A macOS menu bar app for one-click iOS app deployment over Tailscale.
///
/// This is the app entry point. It creates a menu bar item (no dock icon, no main window)
/// and manages the app's lifecycle including the HTTPS server, build engine, and settings.
@main
struct RemoteDeployApp: App {
    @StateObject private var appState = AppState()
    @StateObject private var serviceContainer = ServiceContainer()

    var body: some Scene {
        // Menu bar item — the primary (and only) UI entry point
        MenuBarExtra {
            MenuBarView()
                .environmentObject(appState)
                .environmentObject(serviceContainer)
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
    }

    /// Configures push notifiers based on the user's saved notification settings.
    /// - Parameter config: The push notification configuration from settings.
    func configurePushNotifiers(from config: PushNotificationConfig) {
        var notifiers: [any PushNotifying] = []

        if config.prowlEnabled, !config.prowlAPIKey.isEmpty {
            let prowl = ProwlNotifier()
            prowl.apiKey = config.prowlAPIKey
            notifiers.append(prowl)
        }

        if config.pushoverEnabled, !config.pushoverAppToken.isEmpty {
            let pushover = PushoverNotifier()
            pushover.appToken = config.pushoverAppToken
            pushover.userKey = config.pushoverUserKey
            notifiers.append(pushover)
        }

        if config.ntfyEnabled, !config.ntfyServerURL.isEmpty {
            let ntfy = NtfyNotifier()
            ntfy.serverURL = config.ntfyServerURL
            ntfy.topic = config.ntfyTopic
            notifiers.append(ntfy)
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
