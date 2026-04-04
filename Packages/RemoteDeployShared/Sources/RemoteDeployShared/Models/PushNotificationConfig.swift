import Foundation

/// Configuration for external push notification providers.
/// Controls which services receive build status alerts and which events trigger them.
public struct PushNotificationConfig: Codable, Sendable {
    // MARK: - Prowl

    /// Whether Prowl push notifications are enabled.
    public var prowlEnabled: Bool

    /// API key for authenticating with the Prowl service.
    public var prowlAPIKey: String

    // MARK: - Pushover

    /// Whether Pushover push notifications are enabled.
    public var pushoverEnabled: Bool

    /// Application token for authenticating with Pushover.
    public var pushoverAppToken: String

    /// User key identifying the Pushover recipient.
    public var pushoverUserKey: String

    // MARK: - ntfy

    /// Whether ntfy push notifications are enabled.
    public var ntfyEnabled: Bool

    /// Base URL of the ntfy server (e.g., "https://ntfy.sh").
    public var ntfyServerURL: String

    /// Topic name to publish notifications to on the ntfy server.
    public var ntfyTopic: String

    // MARK: - Event Toggles

    /// Send a notification when a build starts.
    public var notifyOnBuildStarted: Bool

    /// Send a notification when a build succeeds.
    public var notifyOnBuildSuccess: Bool

    /// Send a notification when a build fails.
    public var notifyOnBuildFailure: Bool

    /// Creates a default configuration with all providers disabled
    /// and all event toggles enabled.
    public init() {
        self.prowlEnabled = false
        self.prowlAPIKey = ""
        self.pushoverEnabled = false
        self.pushoverAppToken = ""
        self.pushoverUserKey = ""
        self.ntfyEnabled = false
        self.ntfyServerURL = ""
        self.ntfyTopic = ""
        self.notifyOnBuildStarted = true
        self.notifyOnBuildSuccess = true
        self.notifyOnBuildFailure = true
    }
}
