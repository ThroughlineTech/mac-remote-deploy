// Protocol for the HTTPS server that serves install pages, OTA manifests, and IPA files.
// The server runs on the Mac's Tailscale IP so that iOS devices on the same tailnet
// can reach it directly over HTTPS (required for OTA installation).
import Foundation

/// Called when an IPA file is downloaded by a client device.
/// Implementations use this to update install history in the UI.
protocol DeployServerDelegate: AnyObject, Sendable {

    /// Notifies the delegate that a device downloaded an IPA.
    ///
    /// - Parameter projectName: The display name of the project whose IPA was fetched.
    /// - Parameter sourceIP: The IP address of the downloading device.
    /// - Parameter userAgent: The raw User-Agent header from the request (useful for
    ///   identifying device type, e.g. "iOS 17.4").
    func serverDidServeIPA(projectName: String, sourceIP: String, userAgent: String) async
}

protocol DeployServerProtocol: AnyObject, Sendable {

    /// Starts the HTTPS server, binding to the given port with the provided TLS certificate.
    ///
    /// - Parameter port: The TCP port to listen on (e.g. 8443).
    /// - Parameter certPath: Absolute path to the PEM-encoded TLS certificate file.
    /// - Parameter keyPath: Absolute path to the PEM-encoded TLS private key file.
    /// - Throws: If the port is already in use, the cert/key files are invalid, or
    ///   the server otherwise fails to start.
    func start(port: Int, certPath: String, keyPath: String) async throws

    /// Stops the server and releases the listening socket. No-op if already stopped.
    func stop() async

    /// Whether the server is currently listening for connections.
    var isRunning: Bool { get }

    /// The TCP port the server is currently configured to use.
    var port: Int { get }

    /// Delegate that receives callbacks when IPA files are downloaded.
    /// Set this before calling `start` to receive install-tracking events.
    var delegate: DeployServerDelegate? { get set }
}
