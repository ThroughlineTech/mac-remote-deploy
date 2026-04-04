// Handles paired device management API endpoints.
// GET /api/v1/devices lists paired devices.
// DELETE /api/v1/devices/:id revokes a specific device.
import Foundation
import RemoteDeployShared

/// Handles paired device listing and revocation.
final class DevicesRouteHandler: @unchecked Sendable {

    private let deviceStore: PairedDeviceStoring

    /// Creates a new devices route handler.
    ///
    /// - Parameter deviceStore: The store for managing paired devices.
    init(deviceStore: PairedDeviceStoring) {
        self.deviceStore = deviceStore
    }

    /// GET /api/v1/devices — List all paired devices.
    func list(_ request: APIRequest) -> APIResponse {
        do {
            let devices = try deviceStore.loadDevices()
            return .json(devices)
        } catch {
            return .error(status: .internalServerError, message: "Failed to load devices")
        }
    }

    /// DELETE /api/v1/devices/:id — Revoke a paired device.
    func revoke(_ request: APIRequest, deviceID: UUID) -> APIResponse {
        do {
            try deviceStore.delete(deviceID: deviceID)
            return .json(["revoked": true])
        } catch {
            return .error(status: .notFound, message: "Device not found")
        }
    }
}
