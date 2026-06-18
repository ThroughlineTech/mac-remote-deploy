import SwiftUI
import Foundation

// MARK: - Certificate Setup Step

/// Step 2 of the setup wizard: explains the HTTPS requirement for OTA installs,
/// offers to generate a Tailscale TLS certificate automatically, or lets the user
/// browse for an existing cert/key pair. Shows validation status.
struct CertificateSetupStep: View {
    @ObservedObject var appState: AppState
    // TKT-060 (Phase 6): cert provisioning + manual cert paths go through the
    // server over the API; the menu bar no longer runs `tailscale cert` or
    // validates cert files in-process.
    @EnvironmentObject var menuBarClient: MenuBarClient

    /// Path to the TLS certificate PEM file.
    @State private var certPath: String = ""
    /// Path to the TLS private key PEM file.
    @State private var keyPath: String = ""
    /// Whether certificate generation is in progress.
    @State private var isGenerating = false
    /// Validation state of the currently selected cert/key pair.
    @State private var validationStatus: CertValidation = .unknown
    /// Error message from generation or validation.
    @State private var errorMessage: String?

    /// Possible validation outcomes for the certificate pair.
    enum CertValidation {
        case unknown
        /// The server reports cert + key configured (expiry isn't exposed over the API).
        case configured
        case invalid(reason: String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("HTTPS Certificate")
                .font(.title2.bold())

            Text("iOS requires HTTPS for over-the-air app installation. Tailscale can generate a free, trusted Let's Encrypt certificate for your machine automatically.")
                .font(.body)
                .foregroundColor(.secondary)

            Divider()

            // --- Auto-generate option ---
            GroupBox("Generate via Tailscale") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Recommended: let Tailscale create a certificate for your hostname.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    Button {
                        generateCertificate()
                    } label: {
                        HStack {
                            if isGenerating {
                                ProgressView().controlSize(.small)
                            }
                            Text(isGenerating ? "Generating..." : "Generate Certificate")
                        }
                    }
                    .disabled(isGenerating)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }

            // --- Manual file picker option ---
            GroupBox("Use Existing Certificate") {
                VStack(alignment: .leading, spacing: 8) {
                    // Certificate file picker
                    HStack {
                        Text("Cert:")
                            .frame(width: 40, alignment: .trailing)
                        TextField("path/to/cert.pem", text: $certPath)
                            .textFieldStyle(.roundedBorder)
                        Button("Browse...") {
                            if let url = openFilePanel(title: "Select Certificate File") {
                                certPath = url.path
                                validateCertificate()
                            }
                        }
                    }

                    // Private key file picker
                    HStack {
                        Text("Key:")
                            .frame(width: 40, alignment: .trailing)
                        TextField("path/to/key.pem", text: $keyPath)
                            .textFieldStyle(.roundedBorder)
                        Button("Browse...") {
                            if let url = openFilePanel(title: "Select Private Key File") {
                                keyPath = url.path
                                validateCertificate()
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }

            // --- Validation Status ---
            validationStatusView

            // Error display
            if let error = errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
            }

            Spacer()
        }
    }

    // MARK: - Validation Status View

    /// Shows whether the certificate is valid, invalid, or not yet checked.
    @ViewBuilder
    private var validationStatusView: some View {
        switch validationStatus {
        case .unknown:
            EmptyView()
        case .configured:
            Label("Certificate configured -- HTTPS is ready", systemImage: "checkmark.seal.fill")
                .foregroundColor(.green)
                .font(.subheadline)
        case .invalid(let reason):
            Label("Invalid: \(reason)", systemImage: "xmark.seal.fill")
                .foregroundColor(.red)
                .font(.subheadline)
        }
    }

    // MARK: - Actions

    /// Asks the server to provision a Tailscale certificate for its hostname,
    /// then polls until provisioning completes. The server persists the cert/key
    /// paths and brings HTTPS up; the menu bar only reports progress. TKT-060.
    private func generateCertificate() {
        isGenerating = true
        errorMessage = nil

        Task {
            guard let started = await menuBarClient.provisionCertificate() else {
                errorMessage = "Could not reach the server to provision a certificate."
                isGenerating = false
                return
            }
            if let error = started.lastError {
                errorMessage = "Certificate generation failed: \(error)"
                isGenerating = false
                return
            }

            // Poll until provisioning finishes (timeout ~60s; `tailscale cert`
            // can take a little while).
            let deadline = Date().addingTimeInterval(60)
            while Date() < deadline {
                try? await Task.sleep(for: .seconds(2))
                guard let state = await menuBarClient.certificateStatus() else { continue }
                if state.inProgress { continue }
                if let error = state.lastError {
                    errorMessage = "Certificate generation failed: \(error)"
                } else if state.certConfigured {
                    validationStatus = .configured
                    await menuBarClient.refreshStatus()
                } else {
                    errorMessage = "Certificate provisioning ended without a configured certificate."
                }
                isGenerating = false
                return
            }
            errorMessage = "Certificate provisioning timed out. Check Tailscale and try again."
            isGenerating = false
        }
    }

    /// Submits manually chosen cert/key paths to the server via the settings API.
    /// The server validates the files exist + are readable and (re)starts HTTPS;
    /// a nil result means the server rejected them. TKT-060.
    private func validateCertificate() {
        guard !certPath.isEmpty, !keyPath.isEmpty else { return }
        let cert = certPath
        let key = keyPath

        Task {
            let updated = await menuBarClient.applySettings { settings in
                settings.certPath = cert
                settings.keyPath = key
            }
            if updated != nil {
                validationStatus = .configured
                await menuBarClient.refreshStatus()
            } else {
                validationStatus = .invalid(reason: menuBarClient.lastError ?? "Server rejected the certificate paths")
            }
        }
    }

    /// Presents an NSOpenPanel for selecting a single file.
    private func openFilePanel(title: String) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }
}
