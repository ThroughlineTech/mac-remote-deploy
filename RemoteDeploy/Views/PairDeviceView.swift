// Sheet that displays a QR code for pairing a companion device.
// The QR code contains a JSON payload with the server URL and a
// one-time bearer token. The companion app scans this to complete pairing.
// Automatically dismisses when the device successfully pairs.
import SwiftUI

/// Displays a QR code for pairing a new companion device.
struct PairDeviceView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var serviceContainer: ServiceContainer

    /// The generated QR code image.
    @State private var qrImage: NSImage?
    /// The raw token for this pairing session (shown for manual entry fallback).
    @State private var rawToken: String = ""
    /// The token hash to poll for.
    @State private var tokenHash: String = ""
    /// Whether pairing was completed.
    @State private var pairingComplete = false
    /// Timer task for polling.
    @State private var pollTask: Task<Void, Never>?

    /// Dismiss action for the sheet.
    var onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            if pairingComplete {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 60))
                    .foregroundColor(.green)
                Text("Device Paired!")
                    .font(.title2)
                    .fontWeight(.semibold)
                Text("Your companion device is now connected.")
                    .font(.callout)
                    .foregroundColor(.secondary)
                Button("Done") {
                    onDismiss()
                }
                .keyboardShortcut(.defaultAction)
            } else {
                Text("Pair Companion Device")
                    .font(.title2)
                    .fontWeight(.semibold)

                if let qrImage {
                    Image(nsImage: qrImage)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 200, height: 200)
                        .border(Color.secondary.opacity(0.3), width: 1)
                } else {
                    ProgressView()
                        .frame(width: 200, height: 200)
                }

                Text("Scan this QR code with the RemoteDeploy companion app on your phone.")
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 300)

                if !rawToken.isEmpty {
                    GroupBox("Manual Entry") {
                        HStack {
                            Text(rawToken)
                                .font(.system(.caption, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Button("Copy") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(rawToken, forType: .string)
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    .frame(maxWidth: 300)
                }

                HStack {
                    Button("Cancel") {
                        pollTask?.cancel()
                        onDismiss()
                    }
                    .keyboardShortcut(.cancelAction)
                }
            }
        }
        .padding(30)
        .frame(minWidth: 380)
        .onAppear {
            generateQRCode()
            startPolling()
        }
        .onDisappear {
            pollTask?.cancel()
        }
    }

    /// Generates a QR code containing the server URL and a fresh token.
    private func generateQRCode() {
        let token = JSONPairedDeviceStore.generateToken()
        let hash = JSONPairedDeviceStore.hashToken(token)
        rawToken = token
        tokenHash = hash

        // Register the token as pending pairing
        serviceContainer.pairingHandler?.registerPendingToken(hash)

        // Build URLs — always include a local IP fallback
        let localIP = QRCodeGenerator.localIPAddress()
        let localURL = localIP.map { "http://\($0):8080" }

        // Primary URL: use serverURL if set, otherwise local
        var primaryURL = appState.serverURL
        if primaryURL.isEmpty, let local = localURL {
            primaryURL = local
        }

        let payload = QRCodeGenerator.PairingPayload(
            url: primaryURL,
            token: token,
            serverName: Host.current().localizedName ?? "Mac",
            localURL: localURL
        )

        qrImage = serviceContainer.qrCodeGenerator.generateQRCode(for: payload)
    }

    /// Polls the device store every 2 seconds to detect when pairing completes.
    private func startPolling() {
        pollTask = Task {
            while !Task.isCancelled && !pairingComplete {
                try? await Task.sleep(for: .seconds(2))
                if Task.isCancelled { break }

                // Check if a device with this token hash has been registered
                if serviceContainer.pairedDeviceStore.device(forTokenHash: tokenHash) != nil {
                    withAnimation {
                        pairingComplete = true
                    }
                }
            }
        }
    }
}
