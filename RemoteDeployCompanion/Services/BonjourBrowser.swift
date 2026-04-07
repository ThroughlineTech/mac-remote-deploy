// Discovers RemoteDeploy Mac servers on the local network via Bonjour/mDNS.
// Uses the Network framework's NWBrowser to find _remotedeploy._tcp services.
import Foundation
import Network

/// Discovers RemoteDeploy servers on the local network.
@MainActor
final class BonjourBrowser: ObservableObject {

    /// A discovered RemoteDeploy server.
    struct DiscoveredServer: Identifiable, Hashable {
        let id: String
        let name: String
        let hostname: String
        let localIP: String
        let httpsPort: Int
        let httpPort: Int
    }

    /// Currently discovered servers.
    @Published var servers: [DiscoveredServer] = []

    /// Whether the browser is currently scanning.
    @Published var isSearching = false

    private var browser: NWBrowser?

    /// Starts scanning for RemoteDeploy servers on the local network.
    func startBrowsing() {
        guard browser == nil else { return }
        isSearching = true
        servers = []

        let params = NWParameters()
        params.includePeerToPeer = true

        let newBrowser = NWBrowser(for: .bonjour(type: "_remotedeploy._tcp", domain: nil), using: params)

        newBrowser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor [weak self] in
                self?.handleResults(results)
            }
        }

        newBrowser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                switch state {
                case .ready:
                    self?.isSearching = true
                case .failed, .cancelled:
                    self?.isSearching = false
                default:
                    break
                }
            }
        }

        newBrowser.start(queue: .main)
        browser = newBrowser
    }

    /// Stops scanning.
    func stopBrowsing() {
        browser?.cancel()
        browser = nil
        isSearching = false
    }

    /// Processes browse results into DiscoveredServer objects.
    private func handleResults(_ results: Set<NWBrowser.Result>) {
        var discovered: [DiscoveredServer] = []

        for result in results {
            guard case .service(let name, _, _, _) = result.endpoint else { continue }

            var hostname = ""
            var localIP = ""
            var httpsPort = 8443
            var httpPort = 8080

            if case .bonjour(let record) = result.metadata {
                hostname = txtString(from: record, key: "hostname") ?? ""
                localIP = txtString(from: record, key: "localIP") ?? ""
                if let p = txtString(from: record, key: "httpsPort"), let port = Int(p) {
                    httpsPort = port
                }
                if let p = txtString(from: record, key: "httpPort"), let port = Int(p) {
                    httpPort = port
                }
            }

            discovered.append(DiscoveredServer(
                id: name,
                name: name,
                hostname: hostname,
                localIP: localIP,
                httpsPort: httpsPort,
                httpPort: httpPort
            ))
        }

        servers = discovered
    }

    /// Extracts a string value from a Bonjour TXT record.
    private func txtString(from record: NWTXTRecord, key: String) -> String? {
        guard let entry = record.getEntry(for: key) else { return nil }
        switch entry {
        case .string(let value):
            return value
        case .none:
            return nil
        @unknown default:
            return nil
        }
    }
}
