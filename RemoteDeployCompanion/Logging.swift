// Centralized os.Logger categories for the iOS companion app.
//
// Every production code site uses one of these categories instead of print().
// Filter logs in Console.app or via the `log` CLI when the device is connected:
//
//     log stream --subsystem com.remotedeploy.companion
//     log stream --subsystem com.remotedeploy.companion --predicate 'category == "pairing"'
//
// Privacy convention matches the macOS host: paths, hostnames, IPs, server names,
// and tokens are `.private` and get redacted in release builds. Status codes,
// HTTP methods, durations, and counts are `.public`.
import os

extension Logger {

    /// The iOS companion app's reverse-DNS subsystem identifier.
    private static let companionSubsystem = "com.remotedeploy.companion"

    /// Pairing flows: QR scan, deep link, manual entry, ConnectionManager.
    static let pairing = Logger(subsystem: companionSubsystem, category: "pairing")

    /// REST API client request/response logging.
    static let api = Logger(subsystem: companionSubsystem, category: "api")

    /// SwiftUI view-layer error logging.
    static let ui = Logger(subsystem: companionSubsystem, category: "ui")
}
