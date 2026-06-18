import SwiftUI
import AppKit
import os
import RemoteDeployShared

/// RemoteDeploy -- the macOS menu bar CLIENT for one-click iOS app deployment.
///
/// TKT-060 (Phase 6): after the process split this app starts NO server. The
/// backend (NIO server, build coordinator, stores, Tailscale, Bonjour) runs as a
/// separate headless `RemoteDeployServer` LaunchAgent. This process is a pure API
/// client: it owns only `AppState` (UI state) and `MenuBarClient` (the loopback
/// API/WebSocket client), and talks to the server over http://127.0.0.1:8080 using
/// a loopback token the server hands off via `LoopbackTokenStore`.
///
/// Startup work (read the token, configure the client, mirror server state into
/// AppState) runs from `MenuBarAppDelegate.applicationDidFinishLaunching(_:)` via
/// `@NSApplicationDelegateAdaptor`.
@main
struct RemoteDeployApp: App {
    @StateObject private var appState = AppState()

    /// The menu bar's API client over loopback. Created here and configured by
    /// MenuBarAppDelegate at startup once the loopback token file exists.
    @StateObject private var menuBarClient = MenuBarClient()

    @NSApplicationDelegateAdaptor(MenuBarAppDelegate.self) private var appDelegate

    var body: some Scene {
        // Hand the state objects to the delegate so it can configure the client
        // and mirror server state into AppState. Idempotent; cheap to call on
        // every body evaluation.
        let _ = appDelegate.register(appState: appState, menuBarClient: menuBarClient)

        // Menu bar item -- the primary (and only) UI entry point.
        MenuBarExtra {
            MenuBarView()
                .environmentObject(appState)
                .environmentObject(menuBarClient)
        } label: {
            Label("RemoteDeploy", systemImage: menuBarClient.menuBarIconName)
        }
        .menuBarExtraStyle(.window)

        // Settings window -- opened from the menu bar.
        Settings {
            SettingsView()
                .environmentObject(appState)
                .environmentObject(menuBarClient)
        }

        // Setup assistant -- opens as a standalone window (not a sheet).
        Window("Setup Assistant", id: "setup-assistant") {
            SetupAssistantView(
                appState: appState,
                onDismiss: {
                    appState.showSetupAssistant = false
                },
                onStartServer: {
                    // TKT-060 (Phase 6): the server auto-starts HTTPS when certs are
                    // configured (via its settings-change reconcile), so the wizard
                    // no longer triggers a server start. Just refresh the client's
                    // view of server state.
                    menuBarClient.refreshNow()
                }
            )
            .environmentObject(menuBarClient)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 600, height: 520)

        // Build log -- opens as a standalone window.
        Window("Build Log", id: "build-log") {
            BuildLogView()
                .environmentObject(menuBarClient)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 600, height: 400)
    }
}

// MARK: - Notification Names

extension Notification.Name {
    /// Posted by MenuBarAppDelegate the first time the client connects with no
    /// projects, to open the setup assistant. Observed by MenuBarView. TKT-060:
    /// this is the only cross-component NotificationCenter name left in the menu
    /// bar process -- all server-directed names moved to the server target.
    static let openSetupAssistant = Notification.Name("RemoteDeploy.openSetupAssistant")
}
