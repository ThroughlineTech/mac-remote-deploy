import Foundation

/// Represents a single IPA download event from the built-in web server.
/// Logged each time a device fetches an IPA for installation.
public struct InstallRecord: Codable, Identifiable, Sendable, Equatable {
    /// Unique identifier for this download event.
    public var id: UUID

    /// Human-readable name of the project that was downloaded.
    public var projectName: String

    /// IP address of the client that initiated the download.
    public var sourceIP: String

    /// User-Agent header from the download request, useful for identifying device type.
    public var userAgent: String

    /// Timestamp when the download occurred.
    public var timestamp: Date

    public init(id: UUID = UUID(), projectName: String, sourceIP: String, userAgent: String, timestamp: Date = Date()) {
        self.id = id
        self.projectName = projectName
        self.sourceIP = sourceIP
        self.userAgent = userAgent
        self.timestamp = timestamp
    }
}
