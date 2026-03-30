import SwiftUI
import Foundation

// MARK: - Setup Complete Step

/// Step 5 (final) of the setup wizard: summary of what was configured,
/// the install URL displayed prominently with a copy button, and
/// a brief explanation of next steps.
struct SetupCompleteStep: View {
    @ObservedObject var appState: AppState

    /// Tracks the "Copied!" confirmation flash.
    @State private var showCopiedConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Completion header with checkmark
            HStack {
                Image(systemName: "checkmark.circle.fill")
                    .font(.largeTitle)
                    .foregroundColor(.green)
                Text("Setup Complete!")
                    .font(.title2.bold())
            }

            Text("Your Mac is ready to build and deploy iOS apps over the air.")
                .font(.body)
                .foregroundColor(.secondary)

            Divider()

            // --- Configuration Summary ---
            summarySection

            Divider()

            // --- Install URL (prominent) ---
            installURLSection

            Divider()

            // --- Next Steps ---
            nextStepsSection

            Spacer()
        }
    }

    // MARK: - Configuration Summary

    /// Lists what was configured during the wizard.
    private var summarySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Configuration Summary")
                .font(.headline)

            // Tailscale status
            summaryRow(
                icon: appState.tailscaleConnected ? "checkmark.circle" : "xmark.circle",
                color: appState.tailscaleConnected ? .green : .red,
                label: "Tailscale",
                detail: appState.tailscaleConnected ? "Connected" : "Not connected"
            )

            // Server status
            summaryRow(
                icon: appState.serverRunning ? "checkmark.circle" : "minus.circle",
                color: appState.serverRunning ? .green : .orange,
                label: "Server",
                detail: appState.serverRunning ? "Running on port \(appState.serverPort)" : "Not started"
            )

            // Projects count
            summaryRow(
                icon: appState.projects.isEmpty ? "minus.circle" : "checkmark.circle",
                color: appState.projects.isEmpty ? .orange : .green,
                label: "Projects",
                detail: appState.projects.isEmpty ? "None added" : "\(appState.projects.count) project(s)"
            )
        }
    }

    /// A single summary row with icon, label, and detail text.
    private func summaryRow(icon: String, color: Color, label: String, detail: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundColor(color)
                .frame(width: 20)
            Text(label)
                .fontWeight(.medium)
            Spacer()
            Text(detail)
                .foregroundColor(.secondary)
                .font(.subheadline)
        }
    }

    // MARK: - Install URL Section

    /// Displays the server URL prominently with a copy-to-clipboard button.
    private var installURLSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Install URL")
                .font(.headline)

            if appState.serverURL.isEmpty {
                Text("URL will be available once the server starts.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            } else {
                // URL in a prominent styled box
                HStack {
                    Text(appState.serverURL)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)

                    Spacer()

                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(appState.serverURL, forType: .string)
                        showCopiedConfirmation = true
                        // Reset the confirmation after a short delay
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            showCopiedConfirmation = false
                        }
                    } label: {
                        Label(
                            showCopiedConfirmation ? "Copied!" : "Copy URL",
                            systemImage: showCopiedConfirmation ? "checkmark" : "doc.on.doc"
                        )
                    }
                    .buttonStyle(.bordered)
                }
                .padding(10)
                .background(Color.gray.opacity(0.08))
                .cornerRadius(8)
            }
        }
    }

    // MARK: - Next Steps

    /// Brief instructions for what to do after setup.
    private var nextStepsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Next Steps")
                .font(.headline)

            Label("Open the URL above in Safari on your iOS device", systemImage: "1.circle")
                .font(.subheadline)
            Label("Tap \"Install\" to download the app", systemImage: "2.circle")
                .font(.subheadline)
            Label("Trust the developer certificate in Settings > General > Device Management", systemImage: "3.circle")
                .font(.subheadline)
        }
    }
}
