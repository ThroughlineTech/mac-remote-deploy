// Protocol for sending push notifications to iOS devices.
// Used to alert team members when a new build is ready for installation
// or when a build fails.
import Foundation

/// Controls the urgency of a push notification.
/// Maps to the notification's interruption level or visual prominence.
enum PushPriority: String, Codable, Sendable {
    /// Delivered silently; no sound or banner.
    case low
    /// Standard delivery with sound and banner.
    case normal
    /// Time-sensitive delivery that may break through Focus modes.
    case high
}

protocol PushNotifying: Sendable {

    /// Sends a push notification to all registered devices.
    ///
    /// - Parameter title: The notification title (e.g. "Build Succeeded").
    /// - Parameter message: The notification body text (e.g. "MyApp 1.2.0 (42) is ready").
    /// - Parameter priority: The delivery urgency -- controls sound, banner, and
    ///   whether the notification can interrupt Focus modes.
    /// - Parameter url: An optional HTTPS URL that the notification links to when tapped.
    ///   Typically the install page URL so the user can install with one tap. Pass `nil`
    ///   if no link is needed.
    /// - Throws: If the push service is unreachable, credentials are invalid, or
    ///   the notification payload cannot be delivered.
    func send(title: String, message: String, priority: PushPriority, url: String?) async throws

    /// Sends a test notification to verify that push delivery is working.
    /// Uses a default title/body so the user can confirm their device receives it.
    ///
    /// - Throws: If the push service is unreachable or credentials are invalid.
    func sendTest() async throws
}
