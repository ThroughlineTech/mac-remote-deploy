// Sheet that surfaces a short-lived pairing code and the web-app URL for
// pairing a browser (the PWA) with this Mac. The user opens the web app over
// HTTPS, enters the code on the Connect screen, and the PWA POSTs
// /api/v1/pair to claim it. Polls the device store for completion and
// dismisses on success. (TKT-057, Phase 4 of the backend-decoupling plan.)
import SwiftUI
import RemoteDeployShared

/// Displays a one-time pairing code (and the web URL to enter it) for pairing a browser.
struct PairBrowserView: View {
    @EnvironmentObject var appState: AppState
    // TKT-060 (Phase 6): the server mints the pairing code; the menu bar polls
    // the devices list for completion.
    @EnvironmentObject var menuBarClient: MenuBarClient

    /// The raw pairing code shown to the user (doubles as the browser's bearer token).
    @State private var rawToken: String = ""
    /// Paired-device count captured before minting, so a new pairing is detected
    /// as an increase.
    @State private var baselineDeviceCount = 0
    /// Error surfaced if minting the pairing code fails.
    @State private var errorMessage: String?
    /// Whether pairing was completed.
    @State private var pairingComplete = false
    /// Timer task for polling.
    @State private var pollTask: Task<Void, Never>?

    /// Dismiss action for the sheet.
    var onDismiss: () -> Void

    /// The web-app URL the user opens in their browser to enter the code. Derived
    /// from the server status hostname, falling back to AppState's serverURL.
    private var webURL: String {
        if let status = menuBarClient.status, !status.hostname.isEmpty {
            return "https://\(status.hostname):\(status.serverPort)/app/"
        }
        return appState.serverURL.isEmpty ? "" : "\(appState.serverURL)/app/"
    }

    var body: some View {
        VStack(spacing: 20) {
            if pairingComplete {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 60))
                    .foregroundColor(.green)
                Text("Browser Paired!")
                    .font(.title2)
                    .fontWeight(.semibold)
                Text("Your browser is now connected.")
                    .font(.callout)
                    .foregroundColor(.secondary)
                Button("Done") {
                    onDismiss()
                }
                .keyboardShortcut(.defaultAction)
            } else {
                Text("Pair Browser")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text("Open the web app and enter this code to connect a browser.")
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)

                GroupBox("Pairing code") {
                    HStack {
                        Text(rawToken.isEmpty ? "--------" : rawToken)
                            .font(.system(size: 28, weight: .semibold, design: .monospaced))
                            .textSelection(.enabled)
                        Spacer()
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(rawToken, forType: .string)
                        }
                        .buttonStyle(.borderless)
                    }
                    .padding(.vertical, 4)
                }
                .frame(maxWidth: 320)

                if !webURL.isEmpty {
                    GroupBox("Open in your browser") {
                        HStack {
                            Text(webURL)
                                .font(.system(.caption, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Button("Copy") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(webURL, forType: .string)
                            }
                            .buttonStyle(.borderless)
                            Button("Open") {
                                if let url = URL(string: webURL) {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    .frame(maxWidth: 320)
                }

                Text("The code expires in 10 minutes.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundColor(.red)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 320)
                }

                Button("Cancel") {
                    pollTask?.cancel()
                    onDismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(30)
        .frame(minWidth: 380)
        .onAppear {
            startPairing()
        }
        .onDisappear {
            pollTask?.cancel()
        }
    }

    /// Asks the server to mint a one-time pairing code, then polls for the
    /// browser to claim it. TKT-060 (Phase 6).
    private func startPairing() {
        Task {
            await menuBarClient.refreshDevices()
            baselineDeviceCount = menuBarClient.devices.count

            guard let pending = await menuBarClient.mintPairingToken() else {
                errorMessage = "Could not start pairing: \(menuBarClient.lastError ?? "server unreachable")"
                return
            }
            rawToken = pending.token
            startPolling()
        }
    }

    /// Polls the devices list every 2 seconds; completes when the browser claims
    /// the code (a new device appears).
    private func startPolling() {
        pollTask = Task {
            while !Task.isCancelled && !pairingComplete {
                try? await Task.sleep(for: .seconds(2))
                if Task.isCancelled { break }
                await menuBarClient.refreshDevices()
                if menuBarClient.devices.count > baselineDeviceCount {
                    withAnimation {
                        pairingComplete = true
                    }
                }
            }
        }
    }
}
