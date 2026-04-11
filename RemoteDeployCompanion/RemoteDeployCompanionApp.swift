import SwiftUI
import os

/// RemoteDeploy Companion -- iOS app for remotely controlling builds on a Mac.
@main
struct RemoteDeployCompanionApp: App {
    @StateObject private var connectionManager = ConnectionManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(connectionManager)
                .onOpenURL { url in
                    handleDeepLink(url)
                }
        }
    }

    /// Handles deep links for automated pairing.
    /// URL format: remotedeploy://pair?url=http://192.168.1.42:8080&token=abc123&name=MacName
    private func handleDeepLink(_ url: URL) {
        guard url.scheme == "remotedeploy", url.host == "pair" else { return }

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        guard let serverURL = components?.queryItems?.first(where: { $0.name == "url" })?.value,
              let token = components?.queryItems?.first(where: { $0.name == "token" })?.value else {
            return
        }
        let name = components?.queryItems?.first(where: { $0.name == "name" })?.value ?? "Mac"

        Task {
            do {
                try await connectionManager.pair(url: serverURL, token: token, serverName: name)
            } catch {
                Logger.pairing.error("Deep link pairing failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

/// Root view that shows the splash screen on first launch,
/// then either the server discovery flow or the main interface.
struct ContentView: View {
    @EnvironmentObject var connectionManager: ConnectionManager
    @State private var showSplash = true

    var body: some View {
        if showSplash {
            SplashView {
                withAnimation(.easeInOut(duration: 0.4)) {
                    showSplash = false
                }
            }
        } else if connectionManager.isConnected {
            MainTabView()
                .environmentObject(connectionManager)
        } else {
            ServerDiscoveryView()
                .environmentObject(connectionManager)
        }
    }
}

/// Main tab interface shown after pairing with a Mac.
struct MainTabView: View {
    @EnvironmentObject var connectionManager: ConnectionManager

    var body: some View {
        TabView(selection: $connectionManager.selectedTab) {
            ProjectListView()
                .environmentObject(connectionManager)
                .tabItem {
                    Label("Projects", systemImage: "folder")
                }
                .tag(0)

            BuildControlView()
                .environmentObject(connectionManager)
                .environmentObject(connectionManager.buildManager)
                .environmentObject(connectionManager.webSocketClient)
                .tabItem {
                    Label("Build", systemImage: "hammer")
                }
                .tag(1)

            InstallHistoryView()
                .environmentObject(connectionManager)
                .tabItem {
                    Label("Installs", systemImage: "arrow.down.circle")
                }
                .tag(2)

            RemoteSettingsView()
                .environmentObject(connectionManager)
                .tabItem {
                    Label("Settings", systemImage: "gear")
                }
                .tag(3)
        }
    }
}
