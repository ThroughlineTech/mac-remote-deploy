// Advertises the RemoteDeploy API service over Bonjour/mDNS so that
// companion devices on the same local network can discover the Mac
// without needing to know its IP address or Tailscale hostname.
import Foundation
import os

/// Advertises the RemoteDeploy service via Bonjour for local network discovery.
/// Uses NetService which is designed for pure advertisement without accepting connections.
final class BonjourAdvertiser: NSObject, @unchecked Sendable, NetServiceDelegate {

    /// The Bonjour service type used for discovery.
    static let serviceType = "_remotedeploy._tcp."

    /// The NetService that handles Bonjour advertisement.
    private var service: NetService?

    /// Lock protecting service state.
    private let lock = NSLock()

    /// Whether the advertiser is currently broadcasting.
    var isAdvertising: Bool {
        lock.lock()
        defer { lock.unlock() }
        return service != nil
    }

    /// Starts advertising the RemoteDeploy service on the local network.
    ///
    /// Creates a Bonjour TXT record with connection details that companion
    /// apps read to connect to the API server.
    ///
    /// - Parameter name: The display name for this Mac.
    /// - Parameter httpsPort: The HTTPS server port (for Tailscale connections).
    /// - Parameter httpPort: The plain HTTP server port (for local WiFi).
    /// - Parameter hostname: The Tailscale hostname, if available.
    func start(name: String, httpsPort: Int, httpPort: Int, hostname: String) {
        lock.lock()
        guard service == nil else {
            lock.unlock()
            return
        }
        lock.unlock()

        // Build TXT record data
        var txtDict: [String: Data] = [
            "version": Data("1".utf8),
            "httpsPort": Data("\(httpsPort)".utf8),
            "httpPort": Data("\(httpPort)".utf8),
        ]
        if !hostname.isEmpty {
            txtDict["hostname"] = Data(hostname.utf8)
        }
        if let localIP = QRCodeGenerator.localIPAddress() {
            txtDict["localIP"] = Data(localIP.utf8)
        }

        // TKT-021: defensively drop any empty TXT values. The legacy
        // NetService / dnssd client reports "send failed: Invalid argument"
        // when handed an empty-value TXT entry, and the existing guards above
        // already skip empty hostname / missing localIP — but this filter is
        // cheap insurance against future additions forgetting to check.
        txtDict = txtDict.filter { !$0.value.isEmpty }

        let txtData = NetService.data(fromTXTRecord: txtDict)

        // Advertise on the HTTP port so Bonjour resolves to something reachable
        let newService = NetService(
            domain: "local.",
            type: Self.serviceType,
            name: name,
            port: Int32(httpPort)
        )
        newService.delegate = self
        newService.setTXTRecord(txtData)
        newService.publish()

        lock.lock()
        self.service = newService
        lock.unlock()
    }

    /// Stops the Bonjour advertisement.
    func stop() {
        lock.lock()
        let current = service
        service = nil
        lock.unlock()

        current?.stop()
    }

    /// Updates the TXT record with new connection details.
    ///
    /// - Parameter hostname: Updated Tailscale hostname.
    /// - Parameter httpsPort: Updated HTTPS port.
    /// - Parameter httpPort: Updated HTTP port.
    func updateTXTRecord(hostname: String, httpsPort: Int, httpPort: Int) {
        lock.lock()
        guard let current = service else {
            lock.unlock()
            return
        }
        lock.unlock()

        var txtDict: [String: Data] = [
            "version": Data("1".utf8),
            "httpsPort": Data("\(httpsPort)".utf8),
            "httpPort": Data("\(httpPort)".utf8),
        ]
        if !hostname.isEmpty {
            txtDict["hostname"] = Data(hostname.utf8)
        }

        current.setTXTRecord(NetService.data(fromTXTRecord: txtDict))
    }

    // MARK: - NetServiceDelegate

    func netServiceDidPublish(_ sender: NetService) {
        Logger.bonjour.info("Advertising as '\(sender.name, privacy: .private)' on \(Self.serviceType, privacy: .public)")
    }

    func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        Logger.bonjour.error("Advertisement failed: \(errorDict, privacy: .public)")
    }
}
