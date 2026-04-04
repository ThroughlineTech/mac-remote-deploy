import Foundation

/// Codable struct for persisting app settings to disk.
/// Saved to ~/Library/Application Support/RemoteDeploy/settings.json.
public struct SettingsData: Codable, Sendable {
    /// The TCP port the HTTPS server listens on.
    public var serverPort: Int
    /// The Tailscale MagicDNS hostname for this machine.
    public var hostname: String
    /// Absolute path to the TLS certificate PEM file.
    public var certPath: String
    /// Absolute path to the TLS private key PEM file.
    public var keyPath: String
    /// Push notification provider configuration.
    public var pushNotificationConfig: PushNotificationConfig

    public init(serverPort: Int = 8443, hostname: String = "", certPath: String = "", keyPath: String = "", pushNotificationConfig: PushNotificationConfig = PushNotificationConfig()) {
        self.serverPort = serverPort
        self.hostname = hostname
        self.certPath = certPath
        self.keyPath = keyPath
        self.pushNotificationConfig = pushNotificationConfig
    }
}
