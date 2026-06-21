// Remote settings view for the Mac server.
// Shows server status, connection info, and disconnect option.
import SwiftUI
import RemoteDeployShared

/// Settings and connection management for the paired Mac server.
struct RemoteSettingsView: View {
    @EnvironmentObject var connectionManager: ConnectionManager

    @State private var settings: SettingsData?
    @State private var isLoading = true
    @State private var showDisconnectConfirm = false

    var body: some View {
        NavigationStack {
            List {
                // Connection status
                Section("Connection") {
                    LabeledContent("Server", value: connectionManager.serverName)

                    if let status = connectionManager.serverStatus {
                        LabeledContent("Server Running") {
                            Image(systemName: status.serverRunning ? "checkmark.circle.fill" : "xmark.circle")
                                .foregroundColor(status.serverRunning ? .green : .red)
                        }
                        LabeledContent("Tailscale") {
                            Image(systemName: status.tailscaleConnected ? "checkmark.circle.fill" : "xmark.circle")
                                .foregroundColor(status.tailscaleConnected ? .green : .red)
                        }
                        if !status.hostname.isEmpty {
                            LabeledContent("Hostname", value: status.hostname)
                        }
                        LabeledContent("Port", value: "\(status.serverPort)")
                    }
                }

                // Server settings
                if let settings {
                    Section("Push Notifications") {
                        LabeledContent("Prowl") {
                            Image(systemName: settings.pushNotificationConfig.prowlEnabled ? "checkmark.circle.fill" : "minus.circle")
                                .foregroundColor(settings.pushNotificationConfig.prowlEnabled ? .green : .secondary)
                        }
                        LabeledContent("Pushover") {
                            Image(systemName: settings.pushNotificationConfig.pushoverEnabled ? "checkmark.circle.fill" : "minus.circle")
                                .foregroundColor(settings.pushNotificationConfig.pushoverEnabled ? .green : .secondary)
                        }
                        LabeledContent("ntfy") {
                            Image(systemName: settings.pushNotificationConfig.ntfyEnabled ? "checkmark.circle.fill" : "minus.circle")
                                .foregroundColor(settings.pushNotificationConfig.ntfyEnabled ? .green : .secondary)
                        }
                    }
                }

                // Pair another device (delegated pairing). Only available while
                // connected -- it mints a fresh one-time token using this phone's
                // bearer token. TKT-065.
                if connectionManager.isConnected {
                    Section {
                        NavigationLink {
                            PairAnotherDeviceView()
                        } label: {
                            HStack {
                                Image(systemName: "qrcode")
                                Text("Pair Another Device")
                            }
                        }
                    } footer: {
                        Text("Show a QR code from this phone so another device can pair with this Mac -- no need to be at the Mac. Each device gets its own login, revocable from the Mac's Devices list.")
                    }
                }

                // About
                Section {
                    NavigationLink {
                        AboutView()
                    } label: {
                        HStack {
                            Image(systemName: "info.circle")
                            Text("About RemoteDeploy")
                        }
                    }
                }

                // Disconnect
                Section {
                    Button(role: .destructive) {
                        showDisconnectConfirm = true
                    } label: {
                        HStack {
                            Image(systemName: "minus.circle")
                            Text("Disconnect from Server")
                        }
                    }
                }
            }
            .navigationTitle("Settings")
            .refreshable {
                await loadSettings()
            }
            .confirmationDialog("Disconnect?", isPresented: $showDisconnectConfirm) {
                Button("Disconnect", role: .destructive) {
                    connectionManager.disconnect()
                }
            } message: {
                Text("This will remove the saved connection. You'll need to scan the QR code again to reconnect.")
            }
        }
        .task {
            await loadSettings()
        }
    }

    private func loadSettings() async {
        guard let client = connectionManager.apiClient else { return }
        isLoading = true
        do {
            settings = try await client.getSettings()
            await connectionManager.refreshStatus()
        } catch {
            // Silently handle
        }
        isLoading = false
    }
}
