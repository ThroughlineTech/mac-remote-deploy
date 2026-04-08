// Unified error type for the RemoteDeploy boundary surface (UI alerts, push
// notifications, API responses returned to humans).
//
// **Wrapping philosophy:** Module-specific error enums (BuildError,
// PairedDeviceStoreError, ConnectionError, etc.) stay where they are, throwing
// typed errors at the throw site. At the boundary — where an error is about to
// reach a human or cross a target boundary — wrap it into a RemoteDeployError
// via `RemoteDeployError(wrapping: error)`. The wrapping init preserves the
// underlying message via `error.localizedDescription`, so no information is lost.
//
// TKT-007 plugs RemoteDeployError into AppState.error and ConnectionManager.error
// fields so views can render a consistent message format.
import Foundation

/// Unified error type used at error boundaries (UI alerts, push notifications,
/// API responses) across both the macOS host and the iOS companion.
public enum RemoteDeployError: LocalizedError, Sendable {

    /// The HTTPS deploy server failed to start (port in use, cert unreadable, bind error, etc.).
    case serverStartFailed(reason: String)

    /// A build (xcodebuild archive/export, IPA import, etc.) failed to produce an artifact.
    case buildFailed(reason: String)

    /// QR-code or token-based pairing with a companion device failed.
    case pairingFailed(reason: String)

    /// A network operation (Tailscale lookup, push notification, API call) failed.
    case networkError(reason: String)

    /// A required file or directory could not be found at the given path.
    case fileNotFound(path: String)

    /// User input failed validation (invalid port, malformed bundle ID, missing required field, etc.).
    case validationFailed(field: String, reason: String)

    /// A wrapped or unrecognized error. Used by `init(wrapping:)` to absorb any thrown error
    /// without losing the original `localizedDescription`.
    case unknown(reason: String)

    /// Wraps any thrown error into a `RemoteDeployError` so boundary code can rely on a single
    /// type. If `error` is already a `RemoteDeployError` it is returned unchanged; otherwise the
    /// underlying `localizedDescription` is captured into `.unknown(reason:)`.
    ///
    /// - Parameter error: Any error to wrap.
    public init(wrapping error: any Error) {
        if let already = error as? RemoteDeployError {
            self = already
        } else {
            self = .unknown(reason: error.localizedDescription)
        }
    }

    // MARK: - LocalizedError

    /// User-facing one-line summary suitable for an alert title or notification headline.
    public var errorDescription: String? {
        switch self {
        case .serverStartFailed:
            return "Failed to start the deploy server"
        case .buildFailed:
            return "Build failed"
        case .pairingFailed:
            return "Pairing failed"
        case .networkError:
            return "Network error"
        case .fileNotFound:
            return "File not found"
        case .validationFailed(let field, _):
            return "Invalid \(field)"
        case .unknown:
            return "Something went wrong"
        }
    }

    /// Technical detail suitable for an alert body or log line. Always non-nil.
    public var failureReason: String? {
        switch self {
        case .serverStartFailed(let reason),
             .buildFailed(let reason),
             .pairingFailed(let reason),
             .networkError(let reason),
             .unknown(let reason):
            return reason
        case .fileNotFound(let path):
            return "No file or directory exists at \(path)."
        case .validationFailed(_, let reason):
            return reason
        }
    }

    /// Suggested next step for the user, or nil if there is no obvious recovery action.
    public var recoverySuggestion: String? {
        switch self {
        case .serverStartFailed:
            return "Check that the configured port is not already in use and that your TLS certificate paths are valid."
        case .buildFailed:
            return "Open the build log to see the full error output."
        case .pairingFailed:
            return "Generate a new pairing code on your Mac and try again."
        case .networkError:
            return "Check your Tailscale or LAN connection and try again."
        case .fileNotFound:
            return "Verify the path is correct and that you have permission to read it."
        case .validationFailed:
            return "Correct the highlighted field and try again."
        case .unknown:
            return nil
        }
    }
}
