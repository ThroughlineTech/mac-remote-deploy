// Protocol for managing paired companion devices.
// Implementations persist PairedDevice records so device pairings
// survive app restarts. Tokens are stored hashed for security.
import Foundation
import RemoteDeployShared

protocol PairedDeviceStoring: Sendable {

    /// Loads all paired devices from persistent storage.
    ///
    /// - Returns: An array of every `PairedDevice` that has been paired.
    /// - Throws: If the backing store is corrupt or unreadable.
    func loadDevices() throws -> [PairedDevice]

    /// Saves a paired device to persistent storage. If a device with the same
    /// ID already exists, it is overwritten; otherwise a new entry is created.
    ///
    /// - Parameter device: The `PairedDevice` to save.
    /// - Throws: If writing to the backing store fails.
    func save(device: PairedDevice) throws

    /// Deletes a paired device by its unique identifier, revoking access.
    ///
    /// - Parameter deviceID: The UUID of the device to remove.
    /// - Throws: If the device does not exist or the backing store cannot be written.
    func delete(deviceID: UUID) throws

    /// Looks up a paired device by the SHA-256 hash of its bearer token.
    ///
    /// - Parameter tokenHash: The hex-encoded SHA-256 hash of the raw bearer token.
    /// - Returns: The matching `PairedDevice`, or `nil` if no device matches.
    func device(forTokenHash tokenHash: String) -> PairedDevice?

    /// Updates the last-seen timestamp for a device identified by its token hash.
    ///
    /// - Parameter tokenHash: The hex-encoded SHA-256 hash of the raw bearer token.
    func updateLastSeen(forTokenHash tokenHash: String) throws
}
