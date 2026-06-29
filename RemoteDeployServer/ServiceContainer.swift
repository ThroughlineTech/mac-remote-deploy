// Dependency-injection container for the headless server. TKT-060 (Phase 6):
// moved verbatim out of the menu bar's RemoteDeployApp.swift -- it owns the
// NIODeployServer, build engine, stores, providers, Bonjour, Tailscale, cert
// provider, IPA importer, and push notifiers, none of which the menu bar process
// touches anymore. Protocols are used throughout so implementations can be swapped
// (e.g. for testing).
import Foundation
import Combine
import os
import RemoteDeployShared

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
    /// endpoint reports. Written by ServerLifecycle's poll. TKT-055.
    let runtimeStatus: RuntimeStatusStore

    /// TLS certificate loader and renewal checker.
    let certificateProvider: any CertificateProviding

    /// Server-owned Tailscale cert provisioner (`tailscale cert`). Shared by the
    /// API router (menu-bar-triggered provisioning) and the renewal timer so its
    /// in-progress guard dedupes the two paths. TKT-060 / TKT-071.
    let certProvisioner: any CertProvisioning

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
    /// Set by ServerLifecycle when the API router is configured.
    var pairingHandler: PairingRouteHandler?

    /// View-independent build owner. Constructed by ServerLifecycle at startup
    /// (once AppState + BuildManager exist) and shared by the API adapters. TKT-054.
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
        // Shares the same Tailscale provider + settings store as the rest of the
        // container so the renewal timer and the API drive one provisioner. TKT-071.
        self.certProvisioner = TailscaleCertProvisioner(
            tailscaleProvider: self.tailscaleProvider,
            settingsStore: self.settingsStore
        )
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
