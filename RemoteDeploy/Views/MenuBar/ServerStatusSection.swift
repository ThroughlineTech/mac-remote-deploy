// Server + Tailscale status rows, including the server URL + Copy URL control.
// Extracted from MenuBarHeaderSection in TKT-012 so MenuBarView composes five
// focused subviews and stays under 100 lines. TKT-024.
//
// TKT-056 (Phase 3): reads from the MenuBarClient (the menu bar's own API client)
// instead of AppState. Reachability of the loopback server drives the "running"
// indicator; the rest comes from the /api/v1/status response.
import SwiftUI
import RemoteDeployShared

struct ServerStatusSection: View {
    @EnvironmentObject var menuBarClient: MenuBarClient

    private var status: ServerStatus? { menuBarClient.status }

    /// The :8080 API listener is always-on, so connection state tracks API
    /// reachability; the HTTPS install server (what "running" means to the user)
    /// comes from the status payload.
    private var isReachable: Bool { menuBarClient.connectionState == .connected }
    private var isHTTPSRunning: Bool { status?.serverRunning ?? false }

    private var serverLabel: String {
        guard isReachable else { return "Connecting..." }
        return isHTTPSRunning ? "Server Running" : "Server Stopped"
    }

    private var serverColor: Color {
        guard isReachable else { return .yellow }
        return isHTTPSRunning ? .green : .red
    }

    /// The install URL the user copies. Only meaningful when reachable over
    /// Tailscale (the loopback URL is not useful for installing on a device).
    private var serverURL: String {
        guard let status, status.tailscaleConnected, !status.hostname.isEmpty else { return "" }
        return "https://\(status.hostname):\(status.serverPort)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle()
                    .fill(serverColor)
                    .frame(width: 8, height: 8)
                Text(serverLabel)
                    .font(.subheadline)
                Spacer()
                if let status, isHTTPSRunning {
                    Text("Port \(status.serverPort)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            HStack(spacing: 6) {
                let tailscaleConnected = status?.tailscaleConnected ?? false
                Circle()
                    .fill(tailscaleConnected ? Color.green : Color.red)
                    .frame(width: 8, height: 8)
                Text(tailscaleConnected ? "Tailscale Connected" : "Tailscale Disconnected")
                    .font(.subheadline)
            }

            if !serverURL.isEmpty {
                HStack {
                    Text(serverURL)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer()

                    Button("Copy URL") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(serverURL, forType: .string)
                    }
                    .font(.caption)
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
