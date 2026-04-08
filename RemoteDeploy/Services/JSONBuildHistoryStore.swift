// Concrete BuildHistoryStoring implementation that persists build records
// as a JSON file in Application Support. Mirrors JSONPairedDeviceStore's
// file-based lock pattern.
import Foundation
import os
import RemoteDeployShared

/// Persists the last N build results as a JSON array in
/// `~/Library/Application Support/RemoteDeploy/build-history.json`.
final class JSONBuildHistoryStore: BuildHistoryStoring, @unchecked Sendable {

    /// Maximum number of records to retain on disk. Older records are trimmed.
    private static let maxRecords = 100

    /// The directory containing build-history.json.
    private let directory: URL

    /// Lock protecting the in-memory record cache + file I/O.
    private let lockedRecords = OSAllocatedUnfairLock<[BuildResult]?>(initialState: nil)

    /// Creates a new store. If `directory` is nil, defaults to the standard
    /// Application Support/RemoteDeploy path.
    init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let appSupport = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first!
            self.directory = appSupport.appendingPathComponent("RemoteDeploy")
        }
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    private var fileURL: URL {
        directory.appendingPathComponent("build-history.json")
    }

    // MARK: - BuildHistoryStoring

    func append(_ result: BuildResult) {
        lockedRecords.withLock { cache in
            var records = cache ?? loadFromDisk()
            records.insert(result, at: 0)
            if records.count > Self.maxRecords {
                records = Array(records.prefix(Self.maxRecords))
            }
            cache = records
            persistToDisk(records)
        }
    }

    func recentBuilds() -> [BuildResult] {
        lockedRecords.withLock { cache in
            if let cache { return cache }
            let loaded = loadFromDisk()
            cache = loaded
            return loaded
        }
    }

    // MARK: - Private I/O

    /// Reads the records file from disk, returning [] if missing or corrupt.
    private func loadFromDisk() -> [BuildResult] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode([BuildResult].self, from: data)
        } catch {
            Logger.storage.error("Failed to load build history: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    /// Writes the records atomically to disk with 0600 permissions.
    private func persistToDisk(_ records: [BuildResult]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(records)
            try data.write(to: fileURL, options: .atomic)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: fileURL.path
            )
        } catch {
            Logger.storage.error("Failed to persist build history: \(error.localizedDescription, privacy: .public)")
        }
    }
}
