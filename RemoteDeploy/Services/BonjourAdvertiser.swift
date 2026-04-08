// Advertises the RemoteDeploy API service over Bonjour/mDNS so that
// companion devices on the same local network can discover the Mac
// without needing to know its IP address or Tailscale hostname.
//
// TKT-021 fallback (via TKT-024 Commit 5a): migrated from the legacy
// NetService API to Network.framework's NWListener. NetService's dnssd
// client was emitting two benign but noisy `send failed: Invalid argument`
// lines at startup on macOS 15 — investigation Step 7 of TKT-021 documented
// NWListener as the fallback path.
//
// The NWListener binds an ephemeral TCP port and never accepts connections;
// it exists purely to drive the Bonjour advertisement. The companion app
// reads the real server ports from the TXT record (`httpsPort` / `httpPort`),
// not from the resolved service port, so the ephemeral port is cosmetic.
// See RemoteDeployCompanion/Services/BonjourBrowser.swift for the reader.
import Foundation
import Network
import os

/// Advertises the RemoteDeploy service via Bonjour for local network discovery.
/// Uses NWListener for advertisement without producing the legacy NetService
/// dnssd chatter. TKT-021 / TKT-024.
final class BonjourAdvertiser: @unchecked Sendable {

    /// The Bonjour service type used for discovery.
    static let serviceType = "_remotedeploy._tcp"

    /// The NWListener that drives the Bonjour advertisement.
    private var listener: NWListener?

    /// Serial queue the listener runs on. Kept off the main queue so any
    /// internal Network.framework work does not interleave with AppKit layout.
    private let queue = DispatchQueue(label: "com.remotedeploy.bonjour")

    /// Lock protecting `listener`.
    private let lock = NSLock()

    /// Whether the advertiser is currently broadcasting.
    var isAdvertising: Bool {
        lock.lock()
        defer { lock.unlock() }
        return listener != nil
    }

    /// Starts advertising the RemoteDeploy service on the local network.
    ///
    /// - Parameter name: The display name for this Mac.
    /// - Parameter httpsPort: The HTTPS server port (for Tailscale connections).
    /// - Parameter httpPort: The plain HTTP server port (for local WiFi).
    /// - Parameter hostname: The Tailscale hostname, if available.
    func start(name: String, httpsPort: Int, httpPort: Int, hostname: String) {
        lock.lock()
        guard listener == nil else {
            lock.unlock()
            return
        }
        lock.unlock()

        let txtRecord = buildTXTRecord(httpsPort: httpsPort, httpPort: httpPort, hostname: hostname)

        // Use an ephemeral TCP port — we are not actually serving anything
        // here, just driving Bonjour. The companion reads the real port out
        // of the TXT record. `.any` means "let the kernel pick".
        let parameters = NWParameters.tcp
        // Avoid TLS / keepalive work since we never accept connections.
        parameters.allowLocalEndpointReuse = true

        do {
            let newListener = try NWListener(using: parameters)
            newListener.service = NWListener.Service(
                name: name,
                type: Self.serviceType,
                domain: "local.",
                txtRecord: txtRecord
            )

            // We must accept incoming connection handlers even though we
            // immediately cancel them — NWListener requires one to be set.
            newListener.newConnectionHandler = { connection in
                connection.cancel()
            }

            newListener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    Logger.bonjour.info("Advertising as '\(name, privacy: .private)' on \(Self.serviceType, privacy: .public)")
                case .failed(let error):
                    Logger.bonjour.error("Bonjour advertisement failed: \(error.localizedDescription, privacy: .public)")
                default:
                    break
                }
            }

            newListener.start(queue: queue)

            lock.lock()
            self.listener = newListener
            lock.unlock()
        } catch {
            Logger.bonjour.error("Failed to create NWListener for Bonjour: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Stops the Bonjour advertisement.
    func stop() {
        lock.lock()
        let current = listener
        listener = nil
        lock.unlock()

        current?.cancel()
    }

    /// Updates the TXT record with new connection details.
    func updateTXTRecord(hostname: String, httpsPort: Int, httpPort: Int) {
        lock.lock()
        guard let current = listener else {
            lock.unlock()
            return
        }
        lock.unlock()

        let txt = buildTXTRecord(httpsPort: httpsPort, httpPort: httpPort, hostname: hostname)

        // Re-setting the `service` property on a live listener updates the
        // advertisement in place. We preserve the existing service name by
        // reading it off the current service.
        if let existingName = current.service?.name {
            current.service = NWListener.Service(
                name: existingName,
                type: Self.serviceType,
                domain: "local.",
                txtRecord: txt
            )
        }
    }

    // MARK: - TXT record construction

    /// Builds the NWTXTRecord carrying the real port + hostname metadata.
    /// Empty values are dropped — the legacy NetService code was defensive
    /// about this and we maintain the behavior.
    private func buildTXTRecord(httpsPort: Int, httpPort: Int, hostname: String) -> NWTXTRecord {
        var dict: [String: String] = [
            "version": "1",
            "httpsPort": "\(httpsPort)",
            "httpPort": "\(httpPort)",
        ]
        if !hostname.isEmpty {
            dict["hostname"] = hostname
        }
        if let localIP = QRCodeGenerator.localIPAddress() {
            dict["localIP"] = localIP
        }
        dict = dict.filter { !$0.value.isEmpty }
        return NWTXTRecord(dict)
    }
}
