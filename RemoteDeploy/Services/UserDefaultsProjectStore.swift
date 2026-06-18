// Concrete implementation of ProjectStoring that persists project
// configurations as a JSON file in Application Support.
// Despite the "UserDefaults" name, this uses file-based storage for
// better handling of complex structured data.
import Foundation

final class UserDefaultsProjectStore: ProjectStoring, @unchecked Sendable {

    /// Lock protecting file reads and writes for thread safety.
    private let lock = NSLock()

    /// Directory where the projects JSON file is stored.
    private let storageDirectory: URL

    /// Full path to the projects JSON file.
    private var storageURL: URL {
        storageDirectory.appendingPathComponent("projects.json")
    }

    /// Creates a new project store. Automatically creates the Application Support
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

    // MARK: - ProjectStoring

    /// Loads all saved project configurations from the JSON file on disk.
    /// Returns an empty array if the file does not exist yet.
    ///
    /// - Returns: An array of every persisted `ProjectConfig`.
    /// - Throws: If the file exists but cannot be decoded.
    public func loadProjects() throws -> [ProjectConfig] {
        try withLock { try readProjectsFromDisk() }
    }

    /// Saves a project configuration. If a project with the same ID already
    /// exists it is updated in place; otherwise the project is appended.
    ///
    /// - Parameter project: The `ProjectConfig` to save.
    /// - Throws: If writing the JSON file to disk fails.
    public func save(project: ProjectConfig) throws {
        try withLock {
            var projects = (try? readProjectsFromDisk()) ?? []

            if let index = projects.firstIndex(where: { $0.id == project.id }) {
                projects[index] = project
            } else {
                projects.append(project)
            }

            try writeProjectsToDisk(projects)
        }
        notifyProjectsDidChange()
    }

    /// Deletes a project configuration by its unique identifier.
    ///
    /// - Parameter projectID: The UUID of the project to remove.
    /// - Throws: If the project does not exist or the file cannot be written.
    public func delete(projectID: UUID) throws {
        try withLock {
            var projects = try readProjectsFromDisk()
            guard let index = projects.firstIndex(where: { $0.id == projectID }) else {
                throw ProjectStoreError.projectNotFound(projectID)
            }
            projects.remove(at: index)
            try writeProjectsToDisk(projects)
        }
        notifyProjectsDidChange()
    }

    /// Looks up a project configuration by its unique identifier.
    ///
    /// - Parameter id: The UUID of the project to find.
    /// - Returns: The matching `ProjectConfig`, or `nil` if no project with that ID exists.
    public func project(withID id: UUID) -> ProjectConfig? {
        withLock { try? readProjectsFromDisk().first(where: { $0.id == id }) }
    }

    // MARK: - Locking + change notification

    /// Runs `body` while holding the file lock and releases it before returning.
    /// Mutators post `.projectsDidChange` only AFTER this returns -- never inside
    /// the lock -- so an observer is free to read the store back synchronously.
    /// `NSLock` is not reentrant, so posting under the lock would deadlock such an
    /// observer. TKT-055 (Phase 2).
    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    /// Posts `.projectsDidChange` so observers (the menu bar projection and the
    /// deploy-server slug registry) refresh after any write, regardless of which
    /// path made it. NotificationCenter posting is thread-safe; the observer is
    /// responsible for hopping to the main actor. Always called outside `withLock`.
    private func notifyProjectsDidChange() {
        NotificationCenter.default.post(name: .projectsDidChange, object: nil)
    }

    // MARK: - Private helpers

    /// Reads and decodes the projects JSON file from disk.
    /// Returns an empty array if the file does not exist.
    private func readProjectsFromDisk() throws -> [ProjectConfig] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: storageURL.path) else {
            return []
        }

        let data = try Data(contentsOf: storageURL)
        let decoder = JSONDecoder()
        return try decoder.decode([ProjectConfig].self, from: data)
    }

    /// Encodes and writes the projects array to the JSON file on disk.
    private func writeProjectsToDisk(_ projects: [ProjectConfig]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(projects)
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

enum ProjectStoreError: LocalizedError {
    case projectNotFound(UUID)

    var errorDescription: String? {
        switch self {
        case .projectNotFound(let id):
            return "No project found with ID \(id)"
        }
    }
}
