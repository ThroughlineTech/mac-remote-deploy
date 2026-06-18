// Validates bearer tokens on API requests by hashing the provided token
// and looking it up in the paired device store. Updates last-seen timestamps.
import Foundation
import CryptoKit
import RemoteDeployShared

/// Validates API authentication by checking bearer tokens against paired devices.
final class AuthMiddleware: Sendable {

    /// The paired device store used to validate tokens.
    private let deviceStore: PairedDeviceStoring

    /// Creates a new auth middleware backed by the given device store.
    ///
    /// - Parameter deviceStore: The store containing paired device records with hashed tokens.
    init(deviceStore: PairedDeviceStoring) {
        self.deviceStore = deviceStore
    }

    /// Extracts and validates a bearer token from HTTP headers.
    ///
    /// Hashes the raw token with SHA-256 and looks it up in the paired device store.
    /// If valid, updates the device's last-seen timestamp.
    ///
    /// - Parameter headers: The HTTP request headers to extract the token from.
    /// - Returns: The matched `PairedDevice` if authentication succeeds, `nil` otherwise.
    func authenticate(headers: [(String, String)]) -> PairedDevice? {
        guard let authHeader = headers.first(where: { $0.0.lowercased() == "authorization" })?.1,
              authHeader.lowercased().hasPrefix("bearer ") else {
            return nil
        }

        let rawToken = String(authHeader.dropFirst("bearer ".count)).trimmingCharacters(in: .whitespaces)
        return validate(rawToken: rawToken)
    }

    /// Authenticates a WebSocket upgrade request.
    ///
    /// Browsers cannot set the `Authorization` header on a WebSocket handshake
    /// (the `WebSocket` constructor only takes a URL and subprotocols), so this
    /// first tries the `Authorization` header (native/iOS clients) and then
    /// falls back to a bearer token carried in the `Sec-WebSocket-Protocol`
    /// subprotocol list, e.g. `Sec-WebSocket-Protocol: bearer, <token>`. TKT-058.
    ///
    /// - Parameter headers: The HTTP upgrade request headers.
    /// - Returns: The matched `PairedDevice` if authentication succeeds, `nil` otherwise.
    func authenticateWebSocket(headers: [(String, String)]) -> PairedDevice? {
        if let device = authenticate(headers: headers) { return device }

        guard let proto = headers.first(where: { $0.0.lowercased() == "sec-websocket-protocol" })?.1 else {
            return nil
        }
        let values = proto.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let markerIndex = values.firstIndex(of: "bearer"), markerIndex + 1 < values.count else {
            return nil
        }
        return validate(rawToken: values[markerIndex + 1])
    }

    /// Hashes a raw bearer token, looks it up in the store, and bumps last-seen.
    ///
    /// - Parameter rawToken: The raw bearer token string.
    /// - Returns: The matched `PairedDevice`, or `nil` if empty or unknown.
    private func validate(rawToken: String) -> PairedDevice? {
        guard !rawToken.isEmpty else { return nil }

        let tokenHash = JSONPairedDeviceStore.hashToken(rawToken)
        guard let device = deviceStore.device(forTokenHash: tokenHash) else {
            return nil
        }

        // Update last-seen timestamp (best-effort, don't fail the request if this errors)
        try? deviceStore.updateLastSeen(forTokenHash: tokenHash)

        return device
    }
}
