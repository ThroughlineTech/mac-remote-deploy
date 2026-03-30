import Foundation

/// Codable struct for persisting app settings to disk.
/// Saved to ~/Library/Application Support/RemoteDeploy/settings.json.
struct SettingsData: Codable {
    /// The TCP port the HTTPS server listens on.
    var serverPort: Int = 8443
    /// The Tailscale MagicDNS hostname for this machine.
    var hostname: String = ""
    /// Absolute path to the TLS certificate PEM file.
    var certPath: String = ""
    /// Absolute path to the TLS private key PEM file.
    var keyPath: String = ""
    /// Push notification provider configuration.
    var pushNotificationConfig = PushNotificationConfig()
}
