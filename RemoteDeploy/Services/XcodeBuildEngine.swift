// Concrete implementation of BuildEngineProtocol that wraps xcodebuild CLI commands.
// Handles the full pipeline: archive → export IPA → copy to serve directory.
// Uses Process to run xcodebuild and streams output via AsyncStream for real-time log display.
import Foundation

final class XcodeBuildEngine: BuildEngineProtocol, @unchecked Sendable {

    // MARK: - Private State

    /// Lock protecting mutable state accessed from multiple threads/tasks.
    private let lock = NSLock()

    /// The currently running xcodebuild process, if any. Protected by `lock`.
    private var runningProcess: Process?

    /// Backing storage for `status`. Protected by `lock`.
    private var _status: BuildStatus = .idle

    /// The continuation used to yield lines into `buildLogStream`. Protected by `lock`.
    private var logContinuation: AsyncStream<String>.Continuation?

    /// Backing storage for the async log stream, created once at init.
    private let _buildLogStream: AsyncStream<String>

    // MARK: - Protocol Properties

    /// The current build status (idle, building, success, or failure).
    /// Thread-safe: reads are protected by the internal lock.
    var status: BuildStatus {
        lock.lock()
        defer { lock.unlock() }
        return _status
    }

    /// An async stream that emits individual lines of xcodebuild stdout/stderr output
    /// as they arrive. Consumers (e.g. a log view) can iterate this to show real-time
    /// build output. The stream is long-lived and survives across multiple builds.
    var buildLogStream: AsyncStream<String> {
        _buildLogStream
    }

    // MARK: - Init

    init() {
        var continuation: AsyncStream<String>.Continuation!
        _buildLogStream = AsyncStream<String> { cont in
            continuation = cont
        }
        logContinuation = continuation
    }

    // MARK: - Build Pipeline

    /// Runs the full build pipeline for a project: archive → export IPA → copy to serve dir.
    ///
    /// Steps performed:
    /// 1. Creates a temporary archive directory under `/tmp/RemoteDeploy/`.
    /// 2. Runs `xcodebuild archive` with the project's scheme, team ID, and configuration.
    /// 3. Generates an `ExportOptions.plist` with the appropriate signing method.
    /// 4. Runs `xcodebuild -exportArchive` to produce the IPA from the archive.
    /// 5. Copies the resulting IPA to the project's serve directory under
    ///    `~/Library/Application Support/RemoteDeploy/serve/<slug>/app.ipa`.
    ///
    /// - Parameter project: A `ProjectConfig` containing the .xcodeproj/.xcworkspace path,
    ///   scheme name, team ID, and other build settings.
    /// - Returns: The absolute file path to the exported `.ipa` file in the serve directory.
    /// - Throws: If archiving, exporting, or copying the IPA fails for any reason
    ///   (missing scheme, code-sign error, disk full, process termination, etc.).
    func build(project: ProjectConfig) async throws -> String {
        setStatus(.building(progress: "Preparing build…"))

        let fm = FileManager.default

        // -- Paths --
        let archiveDir = "/tmp/RemoteDeploy"
        let archiveName = project.name.replacingOccurrences(of: " ", with: "_")
        let archivePath = "\(archiveDir)/\(archiveName).xcarchive"
        let exportDir = "\(archiveDir)/\(archiveName)_export"
        let exportPlistPath = "\(archiveDir)/ExportOptions.plist"

        let serveDir = serveDirectory(for: project.urlSlug)
        let finalIPAPath = "\(serveDir)/app.ipa"

        // Ensure directories exist
        try fm.createDirectory(atPath: archiveDir, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: exportDir, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: serveDir, withIntermediateDirectories: true)

        // Clean previous archive/export if present
        if fm.fileExists(atPath: archivePath) {
            try fm.removeItem(atPath: archivePath)
        }

        // -- Step 1: Archive --
        setStatus(.building(progress: "Archiving \(project.scheme)…"))

        var archiveArgs = ["xcodebuild", "archive"]

        // Determine whether to use -workspace or -project.
        // First check explicit config, then auto-detect from projectPath.
        if let workspace = project.workspaceFile {
            let workspacePath = (project.projectPath as NSString).appendingPathComponent(workspace)
            archiveArgs += ["-workspace", workspacePath]
        } else if let projectFile = project.projectFile {
            let projectFilePath = (project.projectPath as NSString).appendingPathComponent(projectFile)
            archiveArgs += ["-project", projectFilePath]
        } else if project.projectPath.hasSuffix(".xcworkspace") {
            archiveArgs += ["-workspace", project.projectPath]
        } else if project.projectPath.hasSuffix(".xcodeproj") {
            archiveArgs += ["-project", project.projectPath]
        } else {
            // projectPath is a directory — scan for .xcworkspace or .xcodeproj inside it
            let contents = (try? fm.contentsOfDirectory(atPath: project.projectPath)) ?? []
            if let ws = contents.first(where: { $0.hasSuffix(".xcworkspace") }) {
                archiveArgs += ["-workspace", (project.projectPath as NSString).appendingPathComponent(ws)]
            } else if let proj = contents.first(where: { $0.hasSuffix(".xcodeproj") }) {
                archiveArgs += ["-project", (project.projectPath as NSString).appendingPathComponent(proj)]
            } else {
                throw BuildError.missingProjectFile(project.projectPath)
            }
        }

        archiveArgs += [
            "-scheme", project.scheme,
            "-archivePath", archivePath,
            "-destination", "generic/platform=iOS",
            "-configuration", project.buildConfiguration,
            "DEVELOPMENT_TEAM=\(project.teamID)"
        ]

        try await runXcodebuild(arguments: Array(archiveArgs.dropFirst()))

        // Verify archive was created
        guard fm.fileExists(atPath: archivePath) else {
            let msg = "Archive not found at \(archivePath) after xcodebuild completed."
            setStatus(.failure(error: msg))
            throw BuildError.archiveFailed(msg)
        }

        // -- Step 2: Generate ExportOptions.plist --
        setStatus(.building(progress: "Exporting IPA…"))

        let exportPlist = generateExportOptionsPlist(
            method: project.exportMethod,
            teamID: project.teamID
        )
        try exportPlist.write(toFile: exportPlistPath, atomically: true, encoding: .utf8)

        // -- Step 3: Export Archive → IPA --
        let exportArgs: [String] = [
            "-exportArchive",
            "-archivePath", archivePath,
            "-exportOptionsPlist", exportPlistPath,
            "-exportPath", exportDir
        ]

        try await runXcodebuild(arguments: exportArgs)

        // Find the IPA in the export directory
        guard let ipaFile = try fm.contentsOfDirectory(atPath: exportDir).first(where: { $0.hasSuffix(".ipa") }) else {
            let msg = "No .ipa file found in export directory \(exportDir)."
            setStatus(.failure(error: msg))
            throw BuildError.exportFailed(msg)
        }

        let exportedIPAPath = "\(exportDir)/\(ipaFile)"

        // -- Step 4: Copy IPA to serve directory --
        setStatus(.building(progress: "Copying IPA to serve directory…"))

        if fm.fileExists(atPath: finalIPAPath) {
            try fm.removeItem(atPath: finalIPAPath)
        }
        try fm.copyItem(atPath: exportedIPAPath, toPath: finalIPAPath)

        setStatus(.success(ipaPath: finalIPAPath))
        emitLog("Build complete: \(finalIPAPath)")

        return finalIPAPath
    }

    /// Cancels any in-progress build by terminating the underlying xcodebuild process.
    /// If no build is currently running, this is a no-op.
    /// After cancellation, the build status is set to failure with a cancellation message.
    func cancelBuild() async {
        lock.lock()
        let process = runningProcess
        lock.unlock()

        if let process = process, process.isRunning {
            process.terminate()
            emitLog("Build cancelled by user.")
            setStatus(.failure(error: "Build cancelled."))
        }
    }

    /// Asks xcodebuild to list the schemes available in a project or workspace.
    ///
    /// Runs `xcodebuild -list -project <path>` (or `-workspace` for .xcworkspace bundles)
    /// and parses the "Schemes:" section from the text output, returning each scheme name
    /// as a trimmed string.
    ///
    /// - Parameter projectPath: Absolute path to a `.xcodeproj` or `.xcworkspace` bundle.
    /// - Returns: An array of scheme name strings found in the project.
    /// - Throws: If xcodebuild fails to parse the project or the path is invalid.
    func detectSchemes(at projectPath: String) async throws -> [String] {
        let isWorkspace = projectPath.hasSuffix(".xcworkspace")
        let flag = isWorkspace ? "-workspace" : "-project"
        let args = [flag, projectPath, "-list"]

        let output = try await runXcodebuildCapturing(arguments: args)
        return parseSchemesFromOutput(output)
    }

    // MARK: - Private Helpers

    /// Runs xcodebuild with the given arguments, streaming stdout/stderr to the log stream.
    ///
    /// Blocks the current async context until the process exits. If the process exits
    /// with a non-zero status, throws `BuildError.xcodebuildFailed`.
    ///
    /// - Parameter arguments: Arguments to pass to xcodebuild (not including "xcodebuild" itself).
    /// - Throws: `BuildError.xcodebuildFailed` if the exit code is non-zero,
    ///   or `BuildError.cancelled` if the process was terminated.
    private func runXcodebuild(arguments: [String]) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["xcodebuild"] + arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        lock.lock()
        runningProcess = process
        lock.unlock()

        // Stream stdout lines
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            for line in text.components(separatedBy: .newlines) where !line.isEmpty {
                self?.emitLog(line)
            }
        }

        // Stream stderr lines
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            for line in text.components(separatedBy: .newlines) where !line.isEmpty {
                self?.emitLog("[stderr] \(line)")
            }
        }

        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { [weak self] proc in
                // Clean up readability handlers
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil

                self?.lock.lock()
                self?.runningProcess = nil
                self?.lock.unlock()

                if proc.terminationReason == .uncaughtSignal {
                    continuation.resume(throwing: BuildError.cancelled)
                } else if proc.terminationStatus != 0 {
                    let msg = "xcodebuild exited with code \(proc.terminationStatus)"
                    self?.setStatus(.failure(error: msg))
                    continuation.resume(throwing: BuildError.xcodebuildFailed(proc.terminationStatus, msg))
                } else {
                    continuation.resume()
                }
            }

            do {
                try process.run()
            } catch {
                lock.lock()
                runningProcess = nil
                lock.unlock()
                continuation.resume(throwing: error)
            }
        }
    }

    /// Runs xcodebuild and captures all stdout output into a single string.
    ///
    /// Used for non-build commands like `-list` where we need to parse the full output
    /// rather than stream it line-by-line.
    ///
    /// - Parameter arguments: Arguments to pass to xcodebuild (not including "xcodebuild" itself).
    /// - Returns: The complete stdout output as a string.
    /// - Throws: If xcodebuild exits with a non-zero status.
    private func runXcodebuildCapturing(arguments: [String]) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["xcodebuild"] + arguments

        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice

        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { proc in
                let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? ""

                if proc.terminationStatus != 0 {
                    continuation.resume(throwing: BuildError.xcodebuildFailed(
                        proc.terminationStatus,
                        "xcodebuild -list failed with code \(proc.terminationStatus)"
                    ))
                } else {
                    continuation.resume(returning: output)
                }
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    /// Parses the "Schemes:" section from xcodebuild -list output.
    ///
    /// The output format from xcodebuild looks like:
    /// ```
    /// Information about project "MyApp":
    ///     Targets:
    ///         MyApp
    ///     Build Configurations:
    ///         Debug
    ///         Release
    ///     Schemes:
    ///         MyApp
    ///         MyAppTests
    /// ```
    /// This method extracts only the lines under "Schemes:" until the next section or end of output.
    ///
    /// - Parameter output: The raw stdout text from `xcodebuild -list`.
    /// - Returns: An array of trimmed scheme names.
    private func parseSchemesFromOutput(_ output: String) -> [String] {
        let lines = output.components(separatedBy: .newlines)
        var inSchemesSection = false
        var schemes: [String] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed == "Schemes:" {
                inSchemesSection = true
                continue
            }

            if inSchemesSection {
                // A new section header (ends with ":") or an empty line terminates the schemes block
                if trimmed.isEmpty || trimmed.hasSuffix(":") {
                    break
                }
                schemes.append(trimmed)
            }
        }

        return schemes
    }

    /// Generates the ExportOptions.plist XML string used by `xcodebuild -exportArchive`.
    ///
    /// The plist specifies the code-signing method (ad-hoc or development), the team ID,
    /// and optimization flags (strip Swift symbols, disable bitcode).
    ///
    /// - Parameter method: The export method, typically "ad-hoc" or "development".
    /// - Parameter teamID: The Apple Developer Team ID for code signing.
    /// - Returns: A complete XML plist string ready to be written to disk.
    private func generateExportOptionsPlist(method: String, teamID: String) -> String {
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" \
        "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>method</key>
            <string>\(method)</string>
            <key>teamID</key>
            <string>\(teamID)</string>
            <key>stripSwiftSymbols</key>
            <true/>
            <key>compileBitcode</key>
            <false/>
        </dict>
        </plist>
        """
    }

    /// Returns the serve directory path for a given project slug.
    ///
    /// The directory is located at `~/Library/Application Support/RemoteDeploy/serve/<slug>/`.
    /// This is where the exported IPA is copied so the deploy server can serve it.
    ///
    /// - Parameter slug: The URL-safe slug identifying the project.
    /// - Returns: The absolute path to the serve directory for this slug.
    private func serveDirectory(for slug: String) -> String {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!.path
        return "\(appSupport)/RemoteDeploy/serve/\(slug)"
    }

    /// Thread-safe setter for the build status.
    ///
    /// - Parameter newStatus: The new status to assign.
    private func setStatus(_ newStatus: BuildStatus) {
        lock.lock()
        _status = newStatus
        lock.unlock()
    }

    /// Emits a single log line to the async build log stream.
    ///
    /// - Parameter line: The log message to emit.
    private func emitLog(_ line: String) {
        lock.lock()
        let cont = logContinuation
        lock.unlock()
        cont?.yield(line)
    }
}

// MARK: - Build Errors

/// Errors specific to the xcodebuild-based build pipeline.
enum BuildError: LocalizedError {
    /// The project directory does not contain a .xcodeproj or .xcworkspace file.
    case missingProjectFile(String)
    /// xcodebuild archive step failed to produce an .xcarchive bundle.
    case archiveFailed(String)
    /// xcodebuild -exportArchive failed to produce an .ipa file.
    case exportFailed(String)
    /// xcodebuild exited with a non-zero status code.
    case xcodebuildFailed(Int32, String)
    /// The build was cancelled (process was terminated by signal).
    case cancelled

    var errorDescription: String? {
        switch self {
        case .missingProjectFile(let path):
            return "No .xcodeproj or .xcworkspace found at \(path)."
        case .archiveFailed(let msg):
            return "Archive failed: \(msg)"
        case .exportFailed(let msg):
            return "Export failed: \(msg)"
        case .xcodebuildFailed(let code, let msg):
            return "xcodebuild failed (exit \(code)): \(msg)"
        case .cancelled:
            return "Build was cancelled."
        }
    }
}
