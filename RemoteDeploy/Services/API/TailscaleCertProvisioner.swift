// Real CertProvisioning implementation. TKT-060 (Phase 6): runs `tailscale cert`
// for the server's configured hostname, writes the PEM files into the app
// support certs directory, and persists the resulting cert/key paths through
// the SettingsStore. The settings write posts `.settingsDidChange`, which the
// server's lifecycle owner observes to bring HTTPS up -- so a successful
// provision results in a live HTTPS listener with no extra wiring.
import Foundation
import os
import RemoteDeployShared

final class TailscaleCertProvisioner: CertProvisioning, @unchecked Sendable {

    private let tailscaleProvider: any TailscaleProviderProtocol
    private let settingsStore: SettingsStore
    private let outputDir: String

    /// Mutable provisioning state guarded for cross-thread access (the POST
    /// handler runs on the NIO event loop; the work runs on a detached task).
    private struct State {
        var inProgress = false
        var lastError: String?
    }
    private let locked = OSAllocatedUnfairLock(initialState: State())

    /// - Parameter outputDir: Where the cert/key PEM files are written. Defaults
    ///   to `~/Library/Application Support/RemoteDeploy/certs`. Tests inject a temp dir.
    init(tailscaleProvider: any TailscaleProviderProtocol, settingsStore: SettingsStore, outputDir: String? = nil) {
        self.tailscaleProvider = tailscaleProvider
        self.settingsStore = settingsStore
        if let outputDir {
            self.outputDir = outputDir
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.path
            self.outputDir = "\(appSupport)/RemoteDeploy/certs"
        }
    }

    func state() -> CertProvisioningState {
        let snapshot = locked.withLock { $0 }
        let settings = settingsStore.current()
        let configured = !settings.certPath.isEmpty && !settings.keyPath.isEmpty
            && FileManager.default.fileExists(atPath: settings.certPath)
            && FileManager.default.fileExists(atPath: settings.keyPath)
        return CertProvisioningState(inProgress: snapshot.inProgress, certConfigured: configured, lastError: snapshot.lastError)
    }

    func provision() -> CertProvisioningState {
        let shouldStart = locked.withLock { state -> Bool in
            guard !state.inProgress else { return false }
            state.inProgress = true
            state.lastError = nil
            return true
        }
        guard shouldStart else { return state() }

        let hostname = settingsStore.current().hostname
        Task.detached { [self] in
            await runProvision(hostname: hostname)
        }
        return state()
    }

    private func runProvision(hostname: String) async {
        do {
            guard !hostname.isEmpty else {
                throw CertProvisioningError.noHostname
            }
            try FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)
            let result = try await tailscaleProvider.generateCertificate(hostname: hostname, outputDir: outputDir)

            var settings = settingsStore.current()
            settings.certPath = result.certPath
            settings.keyPath = result.keyPath
            settingsStore.update(settings)

            locked.withLock { state in
                state.inProgress = false
                state.lastError = nil
            }
            Logger.server.info("Provisioned Tailscale cert for \(hostname, privacy: .public)")
        } catch {
            locked.withLock { state in
                state.inProgress = false
                state.lastError = error.localizedDescription
            }
            Logger.server.error("Cert provisioning failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

/// Errors specific to cert provisioning.
enum CertProvisioningError: LocalizedError {
    case noHostname

    var errorDescription: String? {
        switch self {
        case .noHostname:
            return "Tailscale hostname not detected yet. Connect Tailscale, then try again."
        }
    }
}
