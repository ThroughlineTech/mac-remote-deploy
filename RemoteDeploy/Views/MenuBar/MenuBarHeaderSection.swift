// Header section of the menu bar popover: server + Tailscale status
// and the copy-URL control. Extracted from MenuBarView in TKT-012.
import SwiftUI

struct MenuBarHeaderSection: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Remote Deploy Server")
                .font(.headline)
                .padding(.bottom, 2)

            HStack(spacing: 6) {
                Circle()
                    .fill(appState.serverRunning ? Color.green : Color.red)
                    .frame(width: 8, height: 8)
                Text(appState.serverRunning ? "Server Running" : "Server Stopped")
                    .font(.subheadline)
                Spacer()
                if appState.serverRunning {
                    Text("Port \(appState.serverPort)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            HStack(spacing: 6) {
                Circle()
                    .fill(appState.tailscaleConnected ? Color.green : Color.red)
                    .frame(width: 8, height: 8)
                Text(appState.tailscaleConnected ? "Tailscale Connected" : "Tailscale Disconnected")
                    .font(.subheadline)
            }

            if !appState.serverURL.isEmpty {
                HStack {
                    Text(appState.serverURL)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer()

                    Button("Copy URL") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(appState.serverURL, forType: .string)
                    }
                    .font(.caption)
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
