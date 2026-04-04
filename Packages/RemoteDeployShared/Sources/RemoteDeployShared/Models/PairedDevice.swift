import Foundation

/// Represents a mobile device that has been paired with this Mac via QR code.
/// The token is stored hashed (SHA-256) on disk; the raw token lives only on the paired device.
public struct PairedDevice: Codable, Identifiable, Sendable {
    /// Unique identifier for this pairing.
    public var id: UUID

    /// Human-readable device name (e.g., "iPhone 15 Pro").
    public var name: String

    /// SHA-256 hash of the bearer token (hex-encoded). Raw token never stored on Mac.
    public var tokenHash: String

    /// Timestamp when the device was first paired.
    public var pairedAt: Date

    /// Timestamp of the most recent API call from this device.
    public var lastSeen: Date

    /// Optional push notification endpoint for sending build status to this device.
    public var pushEndpoint: String?

    public init(id: UUID = UUID(), name: String, tokenHash: String, pairedAt: Date = Date(), lastSeen: Date = Date(), pushEndpoint: String? = nil) {
        self.id = id
        self.name = name
        self.tokenHash = tokenHash
        self.pairedAt = pairedAt
        self.lastSeen = lastSeen
        self.pushEndpoint = pushEndpoint
    }
}
