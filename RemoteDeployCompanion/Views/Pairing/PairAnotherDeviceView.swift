// "Pair Another Device" screen (TKT-065).
//
// Lets an already-paired phone (Phone A) mint a fresh one-time pairing token and
// show it as a QR code on its own screen, so a second device (Phone B) can pair
// without anyone being at the Mac. Phone B scans it with the stock, unmodified
// scanner (QRScannerView) and gets its OWN device record + token -- independently
// revocable from the Mac's Devices list.
//
// This is a deliberate relaxation of the "QR only shows on the Mac" trust model:
// any paired device can enroll further devices without Mac-side approval. Risk
// accepted as low for now (decided with the user). A PIN / Mac-side confirmation
// gate is intentionally OUT OF SCOPE here and can be layered on later if warranted.
import SwiftUI
import os
import RemoteDeployShared

/// Mints and displays a delegated pairing QR code from an already-paired phone.
struct PairAnotherDeviceView: View {
    @EnvironmentObject var connectionManager: ConnectionManager

    /// The rendered QR image, nil until a token has been minted and encoded.
    @State private var qrImage: UIImage?
    /// Seconds until the minted token expires, from the server's response.
    @State private var expiresInSeconds = Int(0)
    /// A user-facing error when minting or rendering fails.
    @State private var errorMessage: String?
    /// Whether a mint/render round-trip is in flight.
    @State private var isLoading = false
    /// Whether the encoded URL is HTTPS. The receiving device's claim is rejected
    /// over plain HTTP, so a non-HTTPS URL gets a heads-up caption.
    @State private var usesHTTPS = true

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                Text("Show this code to another phone or browser running the RemoteDeploy companion. It pairs with \(serverNameForDisplay) and gets its own login, separate from this device.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                qrPanel

                if qrImage != nil {
                    Label("Expires in about \(displayMinutes) min - works once.", systemImage: "clock")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    if !usesHTTPS {
                        Text("Heads up: the other device must be on your Tailscale network. The current address is not HTTPS, so pairing may not work until Tailscale is connected.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }

                Button {
                    Task { await generate() }
                } label: {
                    Label(qrImage == nil ? "Generate Code" : "Regenerate",
                          systemImage: "arrow.clockwise")
                        .frame(maxWidth: 280)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isLoading)

                Spacer(minLength: 12)
            }
            .padding(.vertical)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Pair Another Device")
        .navigationBarTitleDisplayMode(.inline)
        .task { await generate() }
    }

    /// The square panel that holds the QR image, a spinner, or a placeholder.
    private var qrPanel: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(.secondarySystemBackground))
                .frame(width: 280, height: 280)

            if let qrImage {
                Image(uiImage: qrImage)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 240, height: 240)
            } else if isLoading {
                ProgressView()
            } else {
                Image(systemName: "qrcode")
                    .font(.system(size: 80))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var serverNameForDisplay: String {
        connectionManager.serverName.isEmpty ? "your Mac" : connectionManager.serverName
    }

    /// TTL rounded to whole minutes, with a floor of 1 so the copy never reads "0".
    private var displayMinutes: Int {
        max(1, expiresInSeconds / 60)
    }

    // MARK: - Mint + render

    /// Mints a fresh one-time pairing token via the existing
    /// `APIClient.mintPairingToken()` and renders it as a QR code that encodes the
    /// exact `PairingPayload` the stock scanner decodes, using this phone's own
    /// server URL + name and the freshly minted token (NOT this phone's token).
    @MainActor
    private func generate() async {
        guard connectionManager.isConnected, let client = connectionManager.apiClient else {
            qrImage = nil
            errorMessage = "Not connected to a Mac. Reconnect, then try again."
            return
        }

        isLoading = true
        errorMessage = nil

        // Refresh status first so we have a current Tailscale hostname/port for
        // building the HTTPS URL the receiving device needs.
        await connectionManager.refreshStatus()

        do {
            let pending = try await client.mintPairingToken()
            let resolved = resolvePairingURL()

            guard let url = resolved else {
                qrImage = nil
                errorMessage = "Could not determine the Mac's address. Make sure Tailscale is connected and try again."
                isLoading = false
                return
            }

            let payload = QRCodeGenerator.PairingPayload(
                url: url.absoluteString,
                token: pending.token,
                serverName: connectionManager.serverName,
                // Delegated pairing is HTTPS-only: the receiving device's claim is
                // rejected over plain HTTP, so we omit the LAN URL entirely.
                localURL: nil
            )

            guard let image = QRCodeGenerator().generateQRCode(for: payload) else {
                qrImage = nil
                errorMessage = "Could not render the QR code. Try regenerating."
                isLoading = false
                return
            }

            expiresInSeconds = pending.expiresInSeconds
            usesHTTPS = (url.scheme?.lowercased() == "https")
            qrImage = image
            Logger.pairing.info("Minted delegated pairing token; QR encodes url=\(url.absoluteString, privacy: .public)")
        } catch {
            qrImage = nil
            errorMessage = mintErrorMessage(for: error)
            Logger.pairing.error("Delegated pairing mint failed: \(error.localizedDescription, privacy: .public)")
        }

        isLoading = false
    }

    /// Resolves the URL to encode for the receiving device. Prefers the canonical
    /// Tailscale HTTPS URL built from the server status; falls back to this phone's
    /// own connection URL.
    private func resolvePairingURL() -> URL? {
        if let status = connectionManager.serverStatus, !status.hostname.isEmpty {
            if let url = URL(string: "https://\(status.hostname):\(status.serverPort)") {
                return url
            }
        }
        return connectionManager.apiClient?.baseURL
    }

    /// Maps a mint failure to a clear, actionable message instead of a blank QR.
    private func mintErrorMessage(for error: Error) -> String {
        if let apiError = error as? APIClientError {
            switch apiError {
            case .httpError(401, _):
                return "This phone is no longer authorized by the Mac. Reconnect, then try again."
            case .httpError(429, _):
                return "Too many pairing attempts right now. Wait a bit, then tap Regenerate."
            case .httpError(let code, let message):
                return "The Mac returned an error (\(code)): \(message)"
            case .invalidResponse:
                return "Got an unexpected response from the Mac. Try regenerating."
            }
        }
        return "Could not reach the Mac. Check your connection, then try again."
    }
}
