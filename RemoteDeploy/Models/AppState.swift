// Central observable state for the entire macOS app. Extracted from
// MenuBarView.swift as part of TKT-012's decomposition work.
import SwiftUI
import Foundation
import RemoteDeployShared

/// Central observable state for the entire app.
/// Published properties drive all SwiftUI view updates across the menu bar,
/// settings window, and setup assistant.
@MainActor
final class AppState: ObservableObject {
    @Published var serverRunning = false
    @Published var tailscaleConnected = false
    @Published var serverURL = ""
    @Published var serverPort: Int = 8443
    @Published var projects: [ProjectConfig] = []
    @Published var selectedProjectID: UUID?
    @Published var lastInstall: InstallRecord?
    @Published var showSetupAssistant = false
    @Published var showSettings = false
    @Published var showBuildLog = false
    @Published var buildConfiguration: String = "Release"

    /// Current boundary-level error, if any. Set by RemoteDeployApp when a boundary
    /// operation (server start, settings save, Tailscale check, etc.) fails. MenuBarView
    /// renders this via .alert() so the user sees what went wrong. TKT-007.
    /// Named `currentError` (not `error`) to avoid shadowing the implicit `error`
    /// binding in `catch` clauses at call sites.
    @Published var currentError: RemoteDeployError?

    /// Absolute path to the TLS certificate PEM file.
    @Published var certPath: String = ""
    /// Absolute path to the TLS private key PEM file.
    @Published var keyPath: String = ""
    /// The Tailscale MagicDNS hostname for this machine.
    @Published var hostname: String = ""
    /// Push notification provider configuration.
    @Published var pushNotificationConfig = PushNotificationConfig()

    /// Returns the currently selected project, if any.
    var selectedProject: ProjectConfig? {
        projects.first { $0.id == selectedProjectID }
    }

    /// Setter helper so non-view callers don't trip SwiftUI's dynamic-member-lookup
    /// path on `@StateObject` when assigning to the published property directly.
    func setError(_ err: RemoteDeployError?) {
        self.currentError = err
    }
}
