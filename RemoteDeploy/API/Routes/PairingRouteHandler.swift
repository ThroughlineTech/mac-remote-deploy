// Handles device pairing and unpairing API endpoints.
// POST /api/v1/pair completes QR code pairing by validating the token
// and registering the device. DELETE /api/v1/pair revokes the calling device.
import Foundation
import os
import RemoteDeployShared

/// Handles pairing and unpairing of companion devices.
final class PairingRouteHandler: @unchecked Sendable {

    private let deviceStore: PairedDeviceStoring
    private let serverName: String

    /// Pending tokens that have been generated but not yet claimed by a device.
    /// Maps token hash -> raw token (only stored in memory until claimed).
    private let pendingTokens: OSAllocatedUnfairLock<[String: Date]>

    /// Creates a new pairing route handler.
    ///
    /// - Parameter deviceStore: The store for persisting paired devices.
    /// - Parameter serverName: The display name of this Mac shown to companion devices.
    init(deviceStore: PairedDeviceStoring, serverName: String) {
        self.deviceStore = deviceStore
        self.serverName = serverName
        self.pendingTokens = OSAllocatedUnfairLock(initialState: [:])
    }

    /// Registers a token as available for pairing. Called when the Mac displays a QR code.
    ///
    /// - Parameter tokenHash: The SHA-256 hash of the token being offered for pairing.
    func registerPendingToken(_ tokenHash: String) {
        pendingTokens.withLock { $0[tokenHash] = Date() }
    }

    /// Removes expired pending tokens (older than 10 minutes).
    func cleanupExpiredTokens() {
        let cutoff = Date().addingTimeInterval(-600)
        pendingTokens.withLock { tokens in
            tokens = tokens.filter { $0.value > cutoff }
        }
    }

    /// POST /api/v1/pair — Complete pairing with a token from the QR code.
    func pair(_ request: APIRequest) -> APIResponse {
        guard let pairRequest = try? request.decodeBody(PairRequest.self) else {
            return .error(status: .badRequest, message: "Invalid request body")
        }

        let tokenHash = JSONPairedDeviceStore.hashToken(pairRequest.token)

        // Verify the token is a pending pairing token
        let isPending = pendingTokens.withLock { tokens -> Bool in
            guard tokens[tokenHash] != nil else { return false }
            tokens.removeValue(forKey: tokenHash)
            return true
        }

        guard isPending else {
            return .error(status: .forbidden, message: "Invalid or expired pairing token")
        }

        // Create and save the paired device
        let device = PairedDevice(
            name: pairRequest.deviceName,
            tokenHash: tokenHash,
            pushEndpoint: pairRequest.pushEndpoint
        )

        do {
            try deviceStore.save(device: device)
        } catch {
            Logger.pairing.error("Failed to save paired device: \(error.localizedDescription, privacy: .public)")
            return .error(status: .internalServerError, message: "Failed to save paired device")
        }

        let response = PairResponse(serverName: serverName, paired: true)
        return .json(response, status: .created)
    }

    /// DELETE /api/v1/pair — Unpair the calling device.
    func unpair(_ request: APIRequest) -> APIResponse {
        guard let device = request.device else {
            return .error(status: .unauthorized, message: "Not authenticated")
        }

        do {
            try deviceStore.delete(deviceID: device.id)
        } catch {
            return .error(status: .internalServerError, message: "Failed to unpair")
        }

        return .json(["unpaired": true])
    }
}
