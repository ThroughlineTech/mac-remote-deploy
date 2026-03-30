import Foundation
import UserNotifications

/// Manages macOS desktop notifications for build events.
/// Posts native notifications that appear in Notification Center.
final class NotificationManager: NSObject, Sendable {
    static let shared = NotificationManager()

    private override init() {
        super.init()
    }

    /// Requests notification permission from the user.
    /// Call this at app launch so the system can prompt for authorization.
    func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound, .badge]
        ) { granted, error in
            if let error {
                print("NotificationManager: permission request failed – \(error.localizedDescription)")
            } else if !granted {
                print("NotificationManager: notification permission denied by user")
            }
        }
    }

    /// Posts a notification for a build event.
    /// - Parameters:
    ///   - title: Notification title (e.g., "Build Success").
    ///   - body: Notification body text.
    ///   - identifier: Unique ID for the notification (used for deduplication).
    func postNotification(title: String, body: String, identifier: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil // Deliver immediately
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                print("NotificationManager: failed to post notification – \(error.localizedDescription)")
            }
        }
    }

    /// Posts a build success notification with the install URL.
    /// - Parameters:
    ///   - projectName: The name of the project that was built.
    ///   - installURL: The URL where the build can be installed from.
    func notifyBuildSuccess(projectName: String, installURL: String) {
        postNotification(
            title: "Build Succeeded",
            body: "\(projectName) is ready to install.\n\(installURL)",
            identifier: "build-success-\(projectName)-\(Date().timeIntervalSince1970)"
        )
    }

    /// Posts a build failure notification with the error summary.
    /// - Parameters:
    ///   - projectName: The name of the project whose build failed.
    ///   - error: A short description of the failure reason.
    func notifyBuildFailure(projectName: String, error: String) {
        postNotification(
            title: "Build Failed",
            body: "\(projectName): \(error)",
            identifier: "build-failure-\(projectName)-\(Date().timeIntervalSince1970)"
        )
    }

    /// Posts a build started notification.
    /// - Parameter projectName: The name of the project being built.
    func notifyBuildStarted(projectName: String) {
        postNotification(
            title: "Build Started",
            body: "Building \(projectName)...",
            identifier: "build-started-\(projectName)-\(Date().timeIntervalSince1970)"
        )
    }
}
