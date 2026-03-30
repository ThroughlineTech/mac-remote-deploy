// Service for importing pre-built .ipa files without building from source.
// Reads bundle metadata from the embedded Info.plist inside the IPA zip archive
// and copies the file into the project's serve directory.
import Foundation

/// Metadata extracted from an imported IPA file.
struct IPAInfo: Sendable {
    /// The app's CFBundleIdentifier (e.g. "com.example.MyApp").
    let bundleID: String
    /// The app's CFBundleShortVersionString (e.g. "1.2.0").
    let version: String
    /// The app's CFBundleVersion build number (e.g. "42").
    let buildNumber: String
}

/// Errors that can occur during IPA import.
enum IPAImportError: LocalizedError {
    case fileNotFound(URL)
    case notAValidIPA(String)
    case infoPlistNotFound
    case infoPlistUnreadable
    case missingBundleField(String)
    case copyFailed(String)

    var errorDescription: String? {
        switch self {
        case .fileNotFound(let url):
            return "IPA file not found at \(url.path)."
        case .notAValidIPA(let detail):
            return "Not a valid IPA archive: \(detail)"
        case .infoPlistNotFound:
            return "Could not find Info.plist inside the IPA's Payload/*.app bundle."
        case .infoPlistUnreadable:
            return "Found Info.plist but could not parse it as a property list."
        case .missingBundleField(let field):
            return "Info.plist is missing required field: \(field)"
        case .copyFailed(let detail):
            return "Failed to copy IPA to serve directory: \(detail)"
        }
    }
}

final class IPAImporter: Sendable {

    /// Imports a pre-built .ipa file by extracting its bundle metadata and copying
    /// the file into the serve directory for the given project.
    ///
    /// An IPA is a zip archive containing `Payload/<AppName>.app/Info.plist`.
    /// This method unzips to a temporary directory, locates the Info.plist,
    /// reads CFBundleIdentifier, CFBundleShortVersionString, and CFBundleVersion,
    /// then copies the original IPA into `<serveDirectory>/<projectSlug>/`.
    ///
    /// - Parameter sourceURL: The local file URL of the .ipa to import.
    /// - Parameter projectSlug: The URL slug for the project (used as the subdirectory name).
    /// - Parameter serveDirectory: The root directory where project files are served from.
    /// - Returns: An `IPAInfo` containing the extracted bundle metadata.
    /// - Throws: `IPAImportError` if the file is missing, not a valid IPA, or cannot be copied.
    func importIPA(from sourceURL: URL, to projectSlug: String, serveDirectory: String) throws -> IPAInfo {
        let fileManager = FileManager.default

        // Verify the source file exists.
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            throw IPAImportError.fileNotFound(sourceURL)
        }

        // Create a temporary directory for extraction.
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempDir) }

        // Unzip the IPA (which is a standard zip archive) using Foundation's built-in support.
        try unzip(ipaURL: sourceURL, to: tempDir)

        // Locate Info.plist inside Payload/*.app/
        let payloadDir = tempDir.appendingPathComponent("Payload")
        guard fileManager.fileExists(atPath: payloadDir.path) else {
            throw IPAImportError.notAValidIPA("No Payload directory found in archive.")
        }

        let payloadContents = try fileManager.contentsOfDirectory(
            at: payloadDir,
            includingPropertiesForKeys: nil
        )
        guard let appBundle = payloadContents.first(where: { $0.pathExtension == "app" }) else {
            throw IPAImportError.notAValidIPA("No .app bundle found inside Payload/.")
        }

        let infoPlistURL = appBundle.appendingPathComponent("Info.plist")
        guard fileManager.fileExists(atPath: infoPlistURL.path) else {
            throw IPAImportError.infoPlistNotFound
        }

        // Parse Info.plist.
        let infoPlistData = try Data(contentsOf: infoPlistURL)
        guard let plist = try PropertyListSerialization.propertyList(
            from: infoPlistData,
            options: [],
            format: nil
        ) as? [String: Any] else {
            throw IPAImportError.infoPlistUnreadable
        }

        // Extract required fields.
        guard let bundleID = plist["CFBundleIdentifier"] as? String else {
            throw IPAImportError.missingBundleField("CFBundleIdentifier")
        }
        guard let version = plist["CFBundleShortVersionString"] as? String else {
            throw IPAImportError.missingBundleField("CFBundleShortVersionString")
        }
        guard let buildNumber = plist["CFBundleVersion"] as? String else {
            throw IPAImportError.missingBundleField("CFBundleVersion")
        }

        // Copy the IPA to the serve directory.
        let projectDir = URL(fileURLWithPath: serveDirectory)
            .appendingPathComponent(projectSlug)
        try fileManager.createDirectory(at: projectDir, withIntermediateDirectories: true)

        let destinationURL = projectDir.appendingPathComponent(sourceURL.lastPathComponent)

        // Remove any existing file at the destination.
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }

        do {
            try fileManager.copyItem(at: sourceURL, to: destinationURL)
        } catch {
            throw IPAImportError.copyFailed(error.localizedDescription)
        }

        return IPAInfo(bundleID: bundleID, version: version, buildNumber: buildNumber)
    }

    // MARK: - Private

    /// Unzips a file at `sourceURL` into `destinationDir` using the `ditto` command,
    /// which is available on all macOS systems and handles zip extraction natively.
    ///
    /// We use Process/ditto rather than a third-party library to stay Foundation-only.
    /// (`ditto -xk` is the standard macOS approach for programmatic zip extraction.)
    private func unzip(ipaURL: URL, to destinationDir: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-xk", ipaURL.path, destinationDir.path]

        let errorPipe = Pipe()
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorMessage = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            throw IPAImportError.notAValidIPA("ditto extraction failed: \(errorMessage)")
        }
    }
}
