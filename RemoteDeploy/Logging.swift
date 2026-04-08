// Centralized os.Logger categories for the macOS host app.
//
// Every production code site uses one of these categories instead of print().
// Filter logs in Console.app or via the `log` CLI:
//
//     log stream --subsystem com.remotedeploy.host
//     log stream --subsystem com.remotedeploy.host --predicate 'category == "api"' --level debug
//
// Privacy convention: paths, hostnames, IPs, project names, and device names are
// `.private` and get redacted in release builds. Status codes, HTTP methods,
// durations, slugs, and counts are `.public`.
import os

extension Logger {

    /// The macOS host app's reverse-DNS subsystem identifier.
    private static let hostSubsystem = "com.remotedeploy.host"

    /// HTTPS deploy server lifecycle (start/stop, channel binding, TLS setup).
    static let server = Logger(subsystem: hostSubsystem, category: "server")

    /// REST API request handling, routing, and response generation.
    static let api = Logger(subsystem: hostSubsystem, category: "api")

    /// Companion device pairing flows and authentication failures.
    static let pairing = Logger(subsystem: hostSubsystem, category: "pairing")

    /// xcodebuild archive/export pipeline, IPA import, build flow.
    static let build = Logger(subsystem: hostSubsystem, category: "build")

    /// Tailscale CLI lookups, hostname detection, status polling.
    static let tailscale = Logger(subsystem: hostSubsystem, category: "tailscale")

    /// Persistent storage: settings, projects, paired devices, install records.
    static let storage = Logger(subsystem: hostSubsystem, category: "storage")

    /// Push notifications (Prowl/Pushover/ntfy) and macOS user notifications.
    static let notifications = Logger(subsystem: hostSubsystem, category: "notifications")

    /// Bonjour service advertisement and discovery.
    static let bonjour = Logger(subsystem: hostSubsystem, category: "bonjour")

    /// SwiftUI view-layer error logging (form validation, scheme detection, launch-at-login, etc.).
    static let ui = Logger(subsystem: hostSubsystem, category: "ui")
}
