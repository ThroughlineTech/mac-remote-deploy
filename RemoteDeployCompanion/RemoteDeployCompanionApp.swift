import SwiftUI

/// RemoteDeploy Companion -- iOS app for remotely controlling builds on a Mac.
@main
struct RemoteDeployCompanionApp: App {
    @StateObject private var connectionManager = ConnectionManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(connectionManager)
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
        TabView {
            ProjectListView()
                .environmentObject(connectionManager)
                .tabItem {
                    Label("Projects", systemImage: "folder")
                }

            BuildControlView()
                .environmentObject(connectionManager)
                .tabItem {
                    Label("Build", systemImage: "hammer")
                }

            InstallHistoryView()
                .environmentObject(connectionManager)
                .tabItem {
                    Label("Installs", systemImage: "arrow.down.circle")
                }

            RemoteSettingsView()
                .environmentObject(connectionManager)
                .tabItem {
                    Label("Settings", systemImage: "gear")
                }
        }
    }
}
