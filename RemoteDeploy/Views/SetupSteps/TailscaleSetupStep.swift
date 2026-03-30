import SwiftUI
import Foundation

// MARK: - Tailscale Setup Step

/// Step 1 of the setup wizard: detects whether Tailscale is installed and connected,
/// displays the machine's MagicDNS hostname, and provides install instructions if needed.
struct TailscaleSetupStep: View {
    @ObservedObject var appState: AppState

    /// Whether Tailscale was detected on this machine.
    @State private var tailscaleDetected: Bool? = nil
    /// The Tailscale MagicDNS hostname (e.g., "macbook.tail1234.ts.net").
    @State private var hostname: String = ""
    /// True while an async detection check is in progress.
    @State private var isChecking = false
    /// Error message from the last detection attempt, if any.
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Tailscale Setup")
                .font(.title2.bold())

            Text("RemoteDeploy uses Tailscale to create a secure connection between your Mac and iOS device. Tailscale provides a private network and trusted HTTPS certificates.")
                .font(.body)
                .foregroundColor(.secondary)

            Divider()

            // Detection result display
            if isChecking {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Checking for Tailscale...")
                }
            } else if let detected = tailscaleDetected {
                if detected {
                    // Tailscale found and connected
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Tailscale detected", systemImage: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .font(.headline)

                        if !hostname.isEmpty {
                            HStack {
                                Text("Hostname:")
                                    .foregroundColor(.secondary)
                                Text(hostname)
                                    .fontWeight(.medium)
                                    .textSelection(.enabled)
                            }
                        }

                        // Connection status indicator
                        HStack(spacing: 6) {
                            Circle()
                                .fill(appState.tailscaleConnected ? Color.green : Color.orange)
                                .frame(width: 8, height: 8)
                            Text(appState.tailscaleConnected ? "Connected to tailnet" : "Not connected -- please log in to Tailscale")
                                .font(.subheadline)
                        }
                    }
                } else {
                    // Tailscale not found -- show install instructions
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Tailscale not found", systemImage: "xmark.circle.fill")
                            .foregroundColor(.red)
                            .font(.headline)

                        Text("Install Tailscale to continue:")
                            .font(.subheadline)
                            .foregroundColor(.secondary)

                        // Installation options
                        GroupBox {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Option 1: Download from the Mac App Store")
                                    .font(.subheadline)
                                Link("Open Mac App Store", destination: URL(string: "https://apps.apple.com/app/tailscale/id1475387142")!)
                                    .font(.subheadline)

                                Divider()

                                Text("Option 2: Install via Homebrew")
                                    .font(.subheadline)
                                Text("brew install --cask tailscale")
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                                    .padding(4)
                                    .background(Color.gray.opacity(0.1))
                                    .cornerRadius(4)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }

                // Display error if detection failed for a reason other than "not found"
                if let error = errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                }
            }

            Spacer()

            // Check Again button to re-run detection
            HStack {
                Spacer()
                Button("Check Again") {
                    checkTailscale()
                }
                .disabled(isChecking)
            }
        }
        .onAppear {
            checkTailscale()
        }
    }

    /// Runs Tailscale detection asynchronously using the TailscaleProviderProtocol.
    /// Updates the local state with the result.
    private func checkTailscale() {
        isChecking = true
        errorMessage = nil

        // In a real implementation, the coordinator injects a TailscaleProviderProtocol.
        // Here we simulate the check with a shell probe.
        Task {
            do {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
                process.arguments = ["tailscale"]
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                try process.run()
                process.waitUntilExit()

                await MainActor.run {
                    tailscaleDetected = process.terminationStatus == 0
                    isChecking = false
                }
            } catch {
                await MainActor.run {
                    tailscaleDetected = false
                    errorMessage = error.localizedDescription
                    isChecking = false
                }
            }
        }
    }
}
