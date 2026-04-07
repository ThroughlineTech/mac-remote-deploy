// Concrete implementation of PairedDeviceStoring that persists paired
// device records as a JSON file in Application Support.
// Follows the same file-based pattern as UserDefaultsProjectStore.
import Foundation
import CryptoKit
import RemoteDeployShared

final class JSONPairedDeviceStore: PairedDeviceStoring, @unchecked Sendable {

    /// Lock protecting file reads and writes for thread safety.
    private let lock = NSLock()

    /// Directory where the paired devices JSON file is stored.
    private let storageDirectory: URL

    /// Full path to the paired devices JSON file.
    private var storageURL: URL {
        storageDirectory.appendingPathComponent("paired_devices.json")
    }

    /// Creates a new paired device store. Automatically creates the Application Support
    /// subdirectory if it does not already exist.
    ///
    /// - Parameter directory: Optional override for the storage directory. Defaults to
    ///   `~/Library/Application Support/RemoteDeploy`.
    init(directory: URL? = nil) {
        if let directory = directory {
            self.storageDirectory = directory
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            self.storageDirectory = appSupport.appendingPathComponent("RemoteDeploy")
        }
        ensureDirectoryExists()
    }

    // MARK: - PairedDeviceStoring

    /// Loads all paired devices from the JSON file on disk.
    /// Returns an empty array if the file does not exist yet.
    func loadDevices() throws -> [PairedDevice] {
        lock.lock()
        defer { lock.unlock() }
        return try readDevicesFromDisk()
    }

    /// Saves a paired device. If a device with the same ID already exists
    /// it is updated in place; otherwise the device is appended.
    func save(device: PairedDevice) throws {
        lock.lock()
        defer { lock.unlock() }

        var devices = (try? readDevicesFromDisk()) ?? []

        if let index = devices.firstIndex(where: { $0.id == device.id }) {
            devices[index] = device
        } else {
            devices.append(device)
        }

        try writeDevicesToDisk(devices)
    }

    /// Deletes a paired device by its unique identifier, revoking its access.
    func delete(deviceID: UUID) throws {
        lock.lock()
        defer { lock.unlock() }

        var devices = try readDevicesFromDisk()
        guard let index = devices.firstIndex(where: { $0.id == deviceID }) else {
            throw PairedDeviceStoreError.deviceNotFound(deviceID)
        }
        devices.remove(at: index)
        try writeDevicesToDisk(devices)
    }

    /// Looks up a paired device by the SHA-256 hash of its bearer token.
    func device(forTokenHash tokenHash: String) -> PairedDevice? {
        lock.lock()
        defer { lock.unlock() }
        return try? readDevicesFromDisk().first(where: { $0.tokenHash == tokenHash })
    }

    /// Updates the last-seen timestamp for a device identified by its token hash.
    func updateLastSeen(forTokenHash tokenHash: String) throws {
        lock.lock()
        defer { lock.unlock() }

        var devices = (try? readDevicesFromDisk()) ?? []
        if let index = devices.firstIndex(where: { $0.tokenHash == tokenHash }) {
            devices[index].lastSeen = Date()
            try writeDevicesToDisk(devices)
        }
    }

    // MARK: - Token Hashing

    /// Computes the SHA-256 hash of a raw bearer token, hex-encoded.
    /// Call this to convert a raw token from a QR code into the stored hash.
    ///
    /// - Parameter rawToken: The raw bearer token string.
    /// - Returns: Hex-encoded SHA-256 hash of the token.
    static func hashToken(_ rawToken: String) -> String {
        let data = Data(rawToken.utf8)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Generates a cryptographically random token as a short hex string.
    ///
    /// - Returns: An 8-character hex string suitable for use as a bearer token.
    ///   This is a local dev tool on a private network — 32 bits of entropy is sufficient.
    static func generateToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 4)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Private Helpers

    /// Reads and decodes the paired devices JSON file from disk.
    /// Returns an empty array if the file does not exist.
    private func readDevicesFromDisk() throws -> [PairedDevice] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: storageURL.path) else {
            return []
        }

        let data = try Data(contentsOf: storageURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([PairedDevice].self, from: data)
    }

    /// Encodes and writes the devices array to the JSON file on disk.
    private func writeDevicesToDisk(_ devices: [PairedDevice]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(devices)
        try data.write(to: storageURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: storageURL.path
        )
    }

    /// Creates the storage directory if it does not already exist.
    private func ensureDirectoryExists() {
        try? FileManager.default.createDirectory(
            at: storageDirectory,
            withIntermediateDirectories: true
        )
    }
}

// MARK: - Errors

enum PairedDeviceStoreError: LocalizedError {
    case deviceNotFound(UUID)

    var errorDescription: String? {
        switch self {
        case .deviceNotFound(let id):
            return "No paired device found with ID \(id)"
        }
    }
}
