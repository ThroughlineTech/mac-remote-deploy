import Foundation

/// Represents a single IPA download event from the built-in web server.
/// Logged each time a device fetches an IPA for installation.
struct InstallRecord: Codable, Identifiable, Sendable {
    /// Unique identifier for this download event.
    var id: UUID

    /// Human-readable name of the project that was downloaded.
    var projectName: String

    /// IP address of the client that initiated the download.
    var sourceIP: String

    /// User-Agent header from the download request, useful for identifying device type.
    var userAgent: String

    /// Timestamp when the download occurred.
    var timestamp: Date
}
