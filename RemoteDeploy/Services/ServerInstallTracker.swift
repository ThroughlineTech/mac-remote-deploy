// Concrete implementation of InstallTracking that persists install
// records as a JSON file in Application Support. Uses Swift's actor
// model for thread-safe file access.
import Foundation

actor ServerInstallTracker: InstallTracking {

    /// Maximum number of install records to retain on disk.
    /// When this limit is exceeded, the oldest records are trimmed.
    private static let maxRecords = 1000

    /// Directory where the installs JSON file is stored.
    private let storageDirectory: URL

    /// Full path to the installs JSON file.
    private var storageURL: URL {
        storageDirectory.appendingPathComponent("installs.json")
    }

    /// Creates a new install tracker. Automatically creates the Application Support
    /// subdirectory if it does not already exist.
    ///
    /// - Parameter directory: Optional override for the storage directory. Defaults to
    ///   `~/Library/Application Support/RemoteDeploy`.
    public init(directory: URL? = nil) {
        if let directory = directory {
            self.storageDirectory = directory
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            self.storageDirectory = appSupport.appendingPathComponent("RemoteDeploy")
        }
        ensureDirectoryExists()
    }

    // MARK: - InstallTracking

    /// Records that a device downloaded an IPA from the deploy server.
    /// Creates a new `InstallRecord` with the current timestamp, appends it to
    /// the on-disk store, and trims to the most recent 1000 records if needed.
    ///
    /// - Parameter projectName: The display name of the project that was installed.
    /// - Parameter sourceIP: The IP address of the requesting device.
    /// - Parameter userAgent: The User-Agent header from the HTTP request.
    public func recordInstall(projectName: String, sourceIP: String, userAgent: String) async {
        let record = InstallRecord(
            id: UUID(),
            projectName: projectName,
            sourceIP: sourceIP,
            userAgent: userAgent,
            timestamp: Date()
        )

        var records = readRecordsFromDisk()
        records.append(record)

        // Trim to the most recent maxRecords entries if we exceed the limit.
        if records.count > Self.maxRecords {
            records = Array(records.suffix(Self.maxRecords))
        }

        writeRecordsToDisk(records)
    }

    /// Returns the most recent install records, ordered newest-first.
    ///
    /// - Parameter limit: The maximum number of records to return.
    /// - Returns: An array of `InstallRecord` values sorted by timestamp descending,
    ///   capped at `limit` entries.
    public func recentInstalls(limit: Int) async -> [InstallRecord] {
        let records = readRecordsFromDisk()
        let sorted = records.sorted { $0.timestamp > $1.timestamp }
        return Array(sorted.prefix(limit))
    }

    // MARK: - Private helpers

    /// Reads and decodes the installs JSON file from disk.
    /// Returns an empty array if the file does not exist or cannot be decoded.
    private func readRecordsFromDisk() -> [InstallRecord] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: storageURL.path) else {
            return []
        }
        do {
            let data = try Data(contentsOf: storageURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .secondsSince1970
            return try decoder.decode([InstallRecord].self, from: data)
        } catch {
            return []
        }
    }

    /// Encodes and writes the install records array to the JSON file on disk.
    /// Silently ignores write failures to avoid disrupting the server.
    private func writeRecordsToDisk(_ records: [InstallRecord]) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .secondsSince1970
            let data = try encoder.encode(records)
            try data.write(to: storageURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: storageURL.path
            )
        } catch {
            // Log but do not propagate — install tracking is non-critical.
            print("ServerInstallTracker: failed to write installs: \(error.localizedDescription)")
        }
    }

    /// Creates the storage directory if it does not already exist.
    private func ensureDirectoryExists() {
        try? FileManager.default.createDirectory(
            at: storageDirectory,
            withIntermediateDirectories: true
        )
    }
}
