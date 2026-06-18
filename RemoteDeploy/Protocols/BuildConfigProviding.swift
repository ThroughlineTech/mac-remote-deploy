// Source of the server / TLS configuration a build needs. Lets BuildCoordinator
// read serverURL/port/cert/key/running directly instead of receiving them from a
// view at the call site (TKT-054, Phase 1 of the backend-decoupling plan).
import Foundation

/// The server and TLS configuration a build sources at trigger time.
///
/// `AppState` conforms to this today; once Phase 2 makes the stores the single
/// source of truth, the coordinator can be repointed at a store-backed
/// implementation without touching its call sites.
@MainActor
protocol BuildConfigProviding: AnyObject {
    /// Base server URL (e.g. `https://host:8443`) used to build the install URL.
    var serverURL: String { get }
    /// HTTPS port the server should bind to if it needs to be started post-build.
    var serverPort: Int { get }
    /// Absolute path to the TLS certificate PEM file.
    var certPath: String { get }
    /// Absolute path to the TLS private key PEM file.
    var keyPath: String { get }
    /// Whether the server is already running (so a post-build start is skipped).
    /// Mutable so the coordinator can flip it true after starting the server.
    var serverRunning: Bool { get set }
}
