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
    @EnvironmentObject var serviceContainer: ServiceContainer

    /// The raw pairing code shown to the user (doubles as the browser's bearer token).
    @State private var rawToken: String = ""
    /// The token hash to poll for.
    @State private var tokenHash: String = ""
    /// Whether pairing was completed.
    @State private var pairingComplete = false
    /// Timer task for polling.
    @State private var pollTask: Task<Void, Never>?

    /// Dismiss action for the sheet.
    var onDismiss: () -> Void

    /// The web-app URL the user opens in their browser to enter the code.
    /// Empty when no HTTPS server URL is configured.
    private var webURL: String {
        appState.serverURL.isEmpty ? "" : "\(appState.serverURL)/app/"
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
            generateCode()
            startPolling()
        }
        .onDisappear {
            pollTask?.cancel()
        }
    }

    /// Generates a fresh code and registers its hash as a pending pairing token.
    private func generateCode() {
        let token = JSONPairedDeviceStore.generateToken()
        rawToken = token
        tokenHash = JSONPairedDeviceStore.hashToken(token)
        serviceContainer.pairingHandler?.registerPendingToken(tokenHash)
    }

    /// Polls the device store every 2 seconds to detect when the browser claims the code.
    private func startPolling() {
        pollTask = Task {
            while !Task.isCancelled && !pairingComplete {
                try? await Task.sleep(for: .seconds(2))
                if Task.isCancelled { break }

                if serviceContainer.pairedDeviceStore.device(forTokenHash: tokenHash) != nil {
                    withAnimation {
                        pairingComplete = true
                    }
                }
            }
        }
    }
}
