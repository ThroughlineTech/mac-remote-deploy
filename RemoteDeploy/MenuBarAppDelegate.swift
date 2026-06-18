// App delegate for the menu bar CLIENT process. TKT-060 (Phase 6).
//
// After the process split the menu bar starts no server. This delegate does three
// client-only things:
//   1. Requests macOS notification permission (UtilitiesSection posts desktop
//      notifications on IPA import).
//   2. Reads the loopback bearer token the headless server wrote to
//      LoopbackTokenStore and configures MenuBarClient against http://127.0.0.1:8080.
//      The token file may be absent at first (server still starting) and rotates on
//      every server relaunch, so it is polled: when it appears or changes, the
//      client is (re)configured and reconnects.
//   3. Mirrors MenuBarClient's polled status + projects into AppState, which the
//      setup wizard and pairing views still read as a cross-step scratchpad. This
//      replaces the projection the old fused AppDelegate maintained from the
//      in-process stores.
import Foundation
import AppKit
import Combine
import os
import RemoteDeployShared

@MainActor
final class MenuBarAppDelegate: NSObject, NSApplicationDelegate {

    private var appState: AppState?
    private var menuBarClient: MenuBarClient?

    /// Loopback base URL the menu bar uses to talk to the server. The server's
    /// plain-HTTP API listener binds :8080; pairing over HTTP is blocked but the
    /// menu bar uses the pre-seeded loopback token, so it never calls /pair.
    private static let loopbackBaseURL = URL(string: "http://127.0.0.1:8080")!

    /// The token currently applied to the client, so we only reconfigure when it
    /// actually changes (initial appearance or a server-side rotation).
    private var appliedToken: String?

    /// One-shot guards for first-run setup + the initial settings fetch.
    private var offeredSetupAssistant = false
    private var didFetchSettings = false

    private var syncTask: Task<Void, Never>?
    private var didRegister = false

    /// Called by RemoteDeployApp.body to hand in the SwiftUI-owned state objects.
    /// Idempotent. The sync loop polls for these, so registration order relative to
    /// applicationDidFinishLaunching does not matter.
    func register(appState: AppState, menuBarClient: MenuBarClient) {
        guard !didRegister else { return }
        self.appState = appState
        self.menuBarClient = menuBarClient
        self.didRegister = true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NotificationManager.shared.requestPermission()
        startSyncLoop()
    }

    func applicationWillTerminate(_ notification: Notification) {
        syncTask?.cancel()
        menuBarClient?.stop()
    }

    /// Drives token pickup, reconnection, and the client -> AppState mirror on a
    /// short cadence. Cheap (field copies + a file read); guarded so it only
    /// touches @Published state when something actually changed.
    private func startSyncLoop() {
        syncTask?.cancel()
        syncTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.applyTokenIfChanged()
                self?.mirrorClientToAppState()
                await self?.fetchSettingsOnce()
                self?.offerSetupAssistantIfNeeded()
                try? await Task.sleep(for: .seconds(1.5))
            }
        }
    }

    /// (Re)configures the client whenever the loopback token appears or rotates.
    private func applyTokenIfChanged() {
        guard let client = menuBarClient, let token = LoopbackTokenStore.read() else { return }
        guard token != appliedToken else { return }
        client.configure(baseURL: Self.loopbackBaseURL, token: token)
        appliedToken = token
        // A rotation means the server relaunched; re-fetch settings for the wizard.
        didFetchSettings = false
    }

    /// Copies the client's polled status + project list into AppState so the setup
    /// wizard / pairing views (which read AppState) reflect live server state.
    /// Diff-guarded to avoid per-tick @Published churn.
    private func mirrorClientToAppState() {
        guard let appState, let client = menuBarClient else { return }

        if let status = client.status {
            if appState.serverRunning != status.serverRunning { appState.serverRunning = status.serverRunning }
            if appState.tailscaleConnected != status.tailscaleConnected { appState.tailscaleConnected = status.tailscaleConnected }
            if appState.hostname != status.hostname { appState.hostname = status.hostname }
            if appState.serverPort != status.serverPort { appState.serverPort = status.serverPort }

            let derivedURL = (status.tailscaleConnected && !status.hostname.isEmpty)
                ? "https://\(status.hostname):\(status.serverPort)"
                : appState.serverURL
            if appState.serverURL != derivedURL { appState.serverURL = derivedURL }
        }

        if appState.projects != client.projects { appState.projects = client.projects }
    }

    /// Fetches settings once after connecting so the wizard's push step can
    /// pre-fill the saved config (settings are not part of the status poll).
    private func fetchSettingsOnce() async {
        guard !didFetchSettings, let client = menuBarClient, client.connectionState == .connected else { return }
        didFetchSettings = true
        await client.refreshSettings()
        // Assigned once per (re)connect; PushNotificationConfig is not Equatable so
        // there is no cheap diff, but this path is one-shot so it does not churn.
        if let config = client.settings?.pushNotificationConfig {
            appState?.pushNotificationConfig = config
        }
    }

    /// Opens the setup assistant the first time we connect and find no projects,
    /// matching the old first-run behavior. Best-effort (the listener is the menu
    /// bar popover; the user can also open it from Utilities).
    private func offerSetupAssistantIfNeeded() {
        guard !offeredSetupAssistant, let client = menuBarClient,
              client.connectionState == .connected else { return }
        offeredSetupAssistant = true
        if client.projects.isEmpty {
            NotificationCenter.default.post(name: .openSetupAssistant, object: nil)
        }
    }
}
