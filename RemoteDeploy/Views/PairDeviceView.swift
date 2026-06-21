// Sheet that displays a QR code for pairing a companion device.
// The QR code contains a JSON payload with the server URL and a
// one-time bearer token. The companion app scans this to complete pairing.
// Automatically dismisses when the device successfully pairs.
import SwiftUI

/// Displays a QR code for pairing a new companion device.
struct PairDeviceView: View {
    @EnvironmentObject var appState: AppState
    // TKT-060 (Phase 6): pairing is driven over the API -- the server mints the
    // one-time token and the menu bar polls the devices list for completion.
    @EnvironmentObject var menuBarClient: MenuBarClient

    /// The generated QR code image.
    @State private var qrImage: NSImage?
    /// The raw token for this pairing session (shown for manual entry fallback).
    @State private var rawToken: String = ""
    /// Paired-device ids captured before minting. A new pairing is detected when a
    /// device id appears that was not in this baseline -- robust to the server
    /// deduping a same-name re-pair (which revokes the old record, so a plain
    /// count would stay flat and never trip). TKT-066.
    @State private var baselineDeviceIDs: Set<UUID> = []
    /// Error surfaced if minting the pairing token fails.
    @State private var errorMessage: String?
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

                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundColor(.red)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 300)
                }

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
            startPairing()
        }
        .onDisappear {
            pollTask?.cancel()
        }
    }

    /// Asks the server to mint a one-time pairing token, builds the QR, and
    /// starts polling for completion. TKT-060 (Phase 6).
    private func startPairing() {
        Task {
            // Baseline the existing device ids so a new pairing is detected as a
            // new id (not a count increase, which dedupe can mask).
            await menuBarClient.refreshDevices()
            baselineDeviceIDs = Set(menuBarClient.devices.map(\.id))

            guard let pending = await menuBarClient.mintPairingToken() else {
                errorMessage = "Could not start pairing: \(menuBarClient.lastError ?? "server unreachable")"
                return
            }
            rawToken = pending.token
            qrImage = buildQRCode(token: pending.token)
            startPolling()
        }
    }

    /// Builds the pairing QR code locally from the server-minted token. The QR
    /// payload's URL points at the server's HTTPS endpoint so the companion can
    /// claim the token over Tailscale.
    private func buildQRCode(token: String) -> NSImage? {
        let localIP = QRCodeGenerator.localIPAddress()
        let localURL = localIP.map { "http://\($0):8080" }

        var primaryURL = ""
        if let status = menuBarClient.status, !status.hostname.isEmpty {
            primaryURL = "https://\(status.hostname):\(status.serverPort)"
        } else if !appState.serverURL.isEmpty {
            primaryURL = appState.serverURL
        } else if let local = localURL {
            primaryURL = local
        }

        let payload = QRCodeGenerator.PairingPayload(
            url: primaryURL,
            token: token,
            serverName: Host.current().localizedName ?? "Mac",
            localURL: localURL
        )
        return QRCodeGenerator().generateQRCode(for: payload)
    }

    /// Polls the devices list every 2 seconds; completes when a new device
    /// (the one claiming this token) appears.
    private func startPolling() {
        pollTask = Task {
            while !Task.isCancelled && !pairingComplete {
                try? await Task.sleep(for: .seconds(2))
                if Task.isCancelled { break }
                await menuBarClient.refreshDevices()
                let newIDs = Set(menuBarClient.devices.map(\.id)).subtracting(baselineDeviceIDs)
                if !newIDs.isEmpty {
                    withAnimation {
                        pairingComplete = true
                    }
                }
            }
        }
    }
}
