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

    /// Registers a project so the server knows to serve its install page, manifest, and IPA.
    /// Call this for each project before or after starting the server.
    /// - Parameter project: The project configuration containing the URL slug and metadata.
    func registerProject(_ project: ProjectConfig)

    /// Removes a previously registered project from the server's routing table.
    /// - Parameter slug: The URL slug of the project to unregister.
    func unregisterProject(slug: String)

    /// Replaces the entire set of registered projects so the routing table
    /// exactly matches the given list (adds new slugs, drops removed ones,
    /// updates changed ones). Call this whenever the project store changes via
    /// any path so create/edit/delete take effect immediately without a server
    /// restart. TKT-055 (Phase 2).
    /// - Parameter projects: The full, authoritative set of projects to serve.
    func syncProjects(_ projects: [ProjectConfig])

    /// Sets the base HTTPS URL used to construct absolute URLs in manifests and install pages.
    /// - Parameter url: The full base URL (e.g., "https://hostname:8443").
    func setBaseURL(_ url: String)

    /// Callback invoked when an IPA is downloaded. Arguments: (projectSlug, sourceIP, userAgent).
    var onIPADownload: ((String, String, String) -> Void)? { get set }
}

extension DeployServerProtocol {

    /// Default `syncProjects` for conformers (e.g. test mocks) that don't track a
    /// removable registry: register each project. `NIODeployServer` overrides this
    /// with a true replace-all that also drops removed slugs. TKT-055 (Phase 2).
    func syncProjects(_ projects: [ProjectConfig]) {
        for project in projects {
            registerProject(project)
        }
    }
}
