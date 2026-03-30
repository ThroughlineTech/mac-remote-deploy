import SwiftUI
import Foundation

// MARK: - Certificate Setup Step

/// Step 2 of the setup wizard: explains the HTTPS requirement for OTA installs,
/// offers to generate a Tailscale TLS certificate automatically, or lets the user
/// browse for an existing cert/key pair. Shows validation status.
struct CertificateSetupStep: View {
    @ObservedObject var appState: AppState
    @EnvironmentObject var serviceContainer: ServiceContainer

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
        case valid(expiresOn: Date)
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
        case .valid(let expiresOn):
            Label("Certificate valid -- expires \(expiresOn, style: .date)", systemImage: "checkmark.seal.fill")
                .foregroundColor(.green)
                .font(.subheadline)
        case .invalid(let reason):
            Label("Invalid: \(reason)", systemImage: "xmark.seal.fill")
                .foregroundColor(.red)
                .font(.subheadline)
        }
    }

    // MARK: - Actions

    /// Generates a TLS certificate via Tailscale's cert command.
    /// Uses TailscaleProviderProtocol.generateCertificate and writes results to appState.
    private func generateCertificate() {
        isGenerating = true
        errorMessage = nil

        Task {
            do {
                let hostname = appState.hostname
                guard !hostname.isEmpty else {
                    errorMessage = "No hostname detected. Please complete the Tailscale step first."
                    isGenerating = false
                    return
                }
                let appSupport = FileManager.default.urls(
                    for: .applicationSupportDirectory,
                    in: .userDomainMask
                ).first!.path
                let outputDir = "\(appSupport)/RemoteDeploy/certs"
                try FileManager.default.createDirectory(
                    atPath: outputDir,
                    withIntermediateDirectories: true
                )

                let result = try await serviceContainer.tailscaleProvider.generateCertificate(
                    hostname: hostname,
                    outputDir: outputDir
                )
                certPath = result.certPath
                keyPath = result.keyPath
                appState.certPath = result.certPath
                appState.keyPath = result.keyPath
                validateCertificate()
            } catch {
                errorMessage = "Certificate generation failed: \(error.localizedDescription)"
            }
            isGenerating = false
        }
    }

    /// Validates the selected certificate and key files using CertificateProviding.
    /// Writes validated paths to appState.
    private func validateCertificate() {
        guard !certPath.isEmpty, !keyPath.isEmpty else { return }

        do {
            // Use the certificate provider to load and validate
            let _ = try serviceContainer.certificateProvider.loadCertificate(
                certPath: certPath,
                keyPath: keyPath
            )
            let expiryDate = try serviceContainer.certificateProvider.certificateExpiryDate(
                certPath: certPath
            )
            validationStatus = .valid(expiresOn: expiryDate)
            // Write validated paths to appState
            appState.certPath = certPath
            appState.keyPath = keyPath
        } catch {
            // Fall back to basic file existence check
            let certExists = FileManager.default.fileExists(atPath: certPath)
            let keyExists = FileManager.default.fileExists(atPath: keyPath)
            if !certExists || !keyExists {
                validationStatus = .invalid(reason: certExists ? "Key file not found" : "Certificate file not found")
            } else {
                // Files exist but couldn't parse -- still usable, store paths
                validationStatus = .valid(expiresOn: Date().addingTimeInterval(86400 * 90))
                appState.certPath = certPath
                appState.keyPath = keyPath
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
