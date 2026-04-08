@testable import RemoteDeploy
import Foundation
import RemoteDeployShared

final class MockPairedDeviceStore: PairedDeviceStoring, @unchecked Sendable {

    // MARK: - Internal storage

    var devices: [PairedDevice] = []

    // MARK: - loadDevices()

    var loadDevicesCallCount = 0
    var loadDevicesShouldThrow: Error?

    func loadDevices() throws -> [PairedDevice] {
        loadDevicesCallCount += 1
        if let error = loadDevicesShouldThrow { throw error }
        return devices
    }

    // MARK: - save(device:)

    var saveCallCount = 0
    var lastSavedDevice: PairedDevice?
    var saveShouldThrow: Error?

    func save(device: PairedDevice) throws {
        saveCallCount += 1
        lastSavedDevice = device
        if let error = saveShouldThrow { throw error }
        if let index = devices.firstIndex(where: { $0.id == device.id }) {
            devices[index] = device
        } else {
            devices.append(device)
        }
    }

    // MARK: - delete(deviceID:)

    var deleteCallCount = 0
    var lastDeletedDeviceID: UUID?
    var deleteShouldThrow: Error?

    func delete(deviceID: UUID) throws {
        deleteCallCount += 1
        lastDeletedDeviceID = deviceID
        if let error = deleteShouldThrow { throw error }
        devices.removeAll { $0.id == deviceID }
    }

    // MARK: - device(forTokenHash:)

    var deviceForTokenHashCallCount = 0
    var lastTokenHashLookup: String?

    func device(forTokenHash tokenHash: String) -> PairedDevice? {
        deviceForTokenHashCallCount += 1
        lastTokenHashLookup = tokenHash
        return devices.first { $0.tokenHash == tokenHash }
    }

    // MARK: - updateLastSeen(forTokenHash:)

    var updateLastSeenCallCount = 0
    var lastUpdatedTokenHash: String?
    var updateLastSeenShouldThrow: Error?

    func updateLastSeen(forTokenHash tokenHash: String) throws {
        updateLastSeenCallCount += 1
        lastUpdatedTokenHash = tokenHash
        if let error = updateLastSeenShouldThrow { throw error }
    }
}
