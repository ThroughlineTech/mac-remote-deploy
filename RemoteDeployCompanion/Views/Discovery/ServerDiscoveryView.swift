// Server discovery and connection screen.
// Shows Bonjour-discovered servers and manual entry options.
import SwiftUI

/// Initial screen for finding and connecting to a RemoteDeploy Mac server.
struct ServerDiscoveryView: View {
    @EnvironmentObject var connectionManager: ConnectionManager
    @StateObject private var bonjourBrowser = BonjourBrowser()

    @State private var showQRScanner = false
    @State private var showManualEntry = false
    @State private var isConnecting = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                // Header
                VStack(spacing: 8) {
                    Image(systemName: "shippingbox")
                        .font(.system(size: 60))
                        .foregroundColor(.accentColor)
                    Text("RemoteDeploy")
                        .font(.largeTitle)
                        .fontWeight(.bold)
                    Text("Connect to your Mac to start deploying builds.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 40)

                // Scan QR Code button (primary action)
                Button {
                    showQRScanner = true
                } label: {
                    Label("Scan QR Code", systemImage: "qrcode.viewfinder")
                        .frame(maxWidth: .infinity)
                        .padding()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                // Discovered servers
                if !bonjourBrowser.servers.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Nearby Servers")
                            .font(.headline)
                            .padding(.horizontal)

                        ForEach(bonjourBrowser.servers) { server in
                            Button {
                                // Bonjour servers still need pairing via QR
                                showQRScanner = true
                            } label: {
                                HStack {
                                    Image(systemName: "desktopcomputer")
                                    VStack(alignment: .leading) {
                                        Text(server.name)
                                            .font(.body)
                                        if !server.hostname.isEmpty {
                                            Text(server.hostname)
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                        }
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .foregroundColor(.secondary)
                                }
                                .padding()
                                .background(Color(.secondarySystemGroupedBackground))
                                .cornerRadius(10)
                            }
                            .buttonStyle(.plain)
                            .padding(.horizontal)
                        }
                    }
                } else if bonjourBrowser.isSearching {
                    HStack {
                        ProgressView()
                        Text("Searching for servers...")
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()

                // Manual entry
                Button("Enter Server URL Manually") {
                    showManualEntry = true
                }
                .foregroundColor(.secondary)
                .padding(.bottom)

                if let error {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                        .padding(.horizontal)
                }
            }
            .navigationTitle("")
            .sheet(isPresented: $showQRScanner) {
                QRScannerView()
                    .environmentObject(connectionManager)
            }
            .sheet(isPresented: $showManualEntry) {
                ManualEntryView()
                    .environmentObject(connectionManager)
            }
        }
        .onAppear {
            bonjourBrowser.startBrowsing()
        }
        .onDisappear {
            bonjourBrowser.stopBrowsing()
        }
    }
}

/// Manual server URL and token entry sheet.
struct ManualEntryView: View {
    @EnvironmentObject var connectionManager: ConnectionManager
    @Environment(\.dismiss) var dismiss

    @State private var serverURL = ""
    @State private var token = ""
    @State private var isConnecting = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Server URL") {
                    TextField("https://macbook.tail1234.ts.net:8443", text: $serverURL)
                        .autocapitalization(.none)
                        .keyboardType(.URL)
                }

                Section("Token") {
                    TextField("Paste the token from your Mac", text: $token)
                        .autocapitalization(.none)
                        .font(.system(.body, design: .monospaced))
                }

                if let error {
                    Section {
                        Text(error)
                            .foregroundColor(.red)
                    }
                }
            }
            .navigationTitle("Manual Connection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Connect") {
                        connect()
                    }
                    .disabled(serverURL.isEmpty || token.isEmpty || isConnecting)
                }
            }
        }
    }

    private func connect() {
        isConnecting = true
        error = nil
        Task {
            do {
                try await connectionManager.connect(url: serverURL, token: token)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            isConnecting = false
        }
    }
}
