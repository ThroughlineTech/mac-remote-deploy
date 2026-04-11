// Concrete implementation of BuildEngineProtocol that wraps xcodebuild CLI commands.
// Handles the full pipeline: archive → export IPA → copy to serve directory.
// Uses Process to run xcodebuild and streams output via AsyncStream for real-time log display.
import Foundation
import os

final class XcodeBuildEngine: BuildEngineProtocol, @unchecked Sendable {

    // MARK: - Private State

    /// The currently running xcodebuild process, if any. Protected by lock.
    private let lockedRunningProcess = OSAllocatedUnfairLock<Process?>(initialState: nil)

    /// Backing storage for `status`. Protected by lock.
    private let lockedStatus = OSAllocatedUnfairLock<BuildStatus>(initialState: .idle)

    /// The continuation used to yield lines into `buildLogStream`. Protected by lock.
    private let lockedLogContinuation = OSAllocatedUnfairLock<AsyncStream<String>.Continuation?>(initialState: nil)

    /// Set to true when `cancelBuild()` is invoked, reset at the start of each `build()`.
    /// Used to make `cancelBuild()` idempotent and to prevent the xcodebuild
    /// terminationHandler from racing the cancel and overwriting the cancellation
    /// status with a success or unrelated failure. See TKT-016.
    private let lockedIsCancelling = OSAllocatedUnfairLock<Bool>(initialState: false)

    /// Ring buffer of the most recent stderr lines from xcodebuild. Capped at
    /// `stderrRingCapacity` entries and reset at the start of each `runXcodebuild`
    /// call. The tail of this buffer is included in `BuildError.xcodebuildFailed`'s
    /// message on a non-zero exit so the companion (and Prowl notification) can
    /// surface the actual xcodebuild error to the user instead of just an exit
    /// code. See TKT-045.
    private let lockedRecentStderrLines = OSAllocatedUnfairLock<[String]>(initialState: [])

    /// Maximum number of recent stderr lines retained for the failure message tail.
    private static let stderrRingCapacity = 8

    // MARK: - Protocol Properties

    /// The current build status (idle, building, success, or failure).
    /// Thread-safe: reads are protected by the internal lock.
    var status: BuildStatus {
        lockedStatus.withLock { $0 }
    }

    /// Creates a new async stream for consuming build log output.
    /// Each call returns a fresh stream -- call this before starting a build,
    /// then iterate it in a Task to receive real-time log lines.
    /// The continuation is set synchronously so emitLog() can yield immediately.
    var buildLogStream: AsyncStream<String> {
        let (stream, continuation) = AsyncStream<String>.makeStream(of: String.self, bufferingPolicy: .unbounded)
        lockedLogContinuation.withLock {
            $0?.finish()
            $0 = continuation
        }
        return stream
    }

    // MARK: - Init

    init() {}

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
        // Reset cancellation flag at the start of every new build so a previous
        // cancellation doesn't carry over and immediately fail this build.
        lockedIsCancelling.withLock { $0 = false }
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

        // Set the destination based on the project's target platform
        let destination: String
        switch project.platform.lowercased() {
        case "macos":
            destination = "generic/platform=macOS"
        case "tvos":
            destination = "generic/platform=tvOS"
        case "watchos":
            destination = "generic/platform=watchOS"
        default:
            destination = "generic/platform=iOS"
        }

        archiveArgs += [
            "-scheme", project.scheme,
            "-archivePath", archivePath,
            "-destination", destination,
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
    /// If no build is currently running, this is a no-op. Idempotent — calling it twice
    /// in a row only terminates the process once. After cancellation, the build status
    /// is set to `.failure(error: "Build cancelled.")` and the xcodebuild
    /// terminationHandler will skip its normal status updates so the cancellation
    /// message wins regardless of the actual exit code (TKT-016).
    func cancelBuild() async {
        // Atomic check-and-set: if cancellation is already in progress, no-op.
        let alreadyCancelling = lockedIsCancelling.withLock { state -> Bool in
            if state { return true }
            state = true
            return false
        }
        guard !alreadyCancelling else { return }

        let process = lockedRunningProcess.withLock { $0 }

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
    /// - Parameter projectPath: Absolute path to a directory containing an Xcode project,
    ///   or a direct path to a `.xcodeproj` or `.xcworkspace` bundle.
    /// - Returns: An array of scheme name strings found in the project.
    /// - Throws: If xcodebuild fails to parse the project or the path is invalid.
    func detectSchemes(at projectPath: String) async throws -> [String] {
        let resolved = try resolveXcodeProject(at: projectPath)
        let flag = resolved.hasSuffix(".xcworkspace") ? "-workspace" : "-project"
        let args = [flag, resolved, "-list"]

        let output = try await runXcodebuildCapturing(arguments: args)
        return parseSchemesFromOutput(output)
    }

    /// Resolves a path to the actual `.xcworkspace` or `.xcodeproj` bundle.
    ///
    /// If the path already points to a bundle, returns it as-is. Otherwise treats it as a
    /// directory and scans for `.xcworkspace` (preferred) or `.xcodeproj` inside it.
    private func resolveXcodeProject(at path: String) throws -> String {
        if path.hasSuffix(".xcworkspace") || path.hasSuffix(".xcodeproj") {
            return path
        }

        let fm = FileManager.default
        let contents = (try? fm.contentsOfDirectory(atPath: path)) ?? []
        let xcworkspaces = contents.filter { $0.hasSuffix(".xcworkspace") }
        let xcprojects = contents.filter { $0.hasSuffix(".xcodeproj") }

        if let workspace = xcworkspaces.first {
            return "\(path)/\(workspace)"
        } else if let project = xcprojects.first {
            return "\(path)/\(project)"
        }

        throw BuildError.xcodebuildFailed(1, "No .xcodeproj or .xcworkspace found in \(path)")
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
        // TKT-045: reset the stderr ring buffer at the start of every invocation
        // so the failure message only reflects the current xcodebuild run.
        lockedRecentStderrLines.withLock { $0.removeAll(keepingCapacity: true) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["xcodebuild"] + arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        lockedRunningProcess.withLock { $0 = process }

        // Stream stdout lines
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            for line in text.components(separatedBy: .newlines) where !line.isEmpty {
                self?.emitLog(line)
            }
        }

        // Stream stderr lines and capture each into the ring buffer so the
        // termination handler can include the tail in the thrown error
        // message on a non-zero exit. TKT-045.
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            for line in text.components(separatedBy: .newlines) where !line.isEmpty {
                self?.appendStderrLine(line)
                self?.emitLog("[stderr] \(line)")
            }
        }

        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { [weak self] proc in
                // Drain any final bytes still buffered on the pipes before we
                // detach the readability handlers, so the last stderr line
                // (which on a preflight failure is usually the informative
                // error) is captured into the ring buffer rather than racing
                // the handler teardown. TKT-045.
                let stdoutTail = stdoutPipe.fileHandleForReading.availableData
                if !stdoutTail.isEmpty, let text = String(data: stdoutTail, encoding: .utf8) {
                    for line in text.components(separatedBy: .newlines) where !line.isEmpty {
                        self?.emitLog(line)
                    }
                }
                let stderrTail = stderrPipe.fileHandleForReading.availableData
                if !stderrTail.isEmpty, let text = String(data: stderrTail, encoding: .utf8) {
                    for line in text.components(separatedBy: .newlines) where !line.isEmpty {
                        self?.appendStderrLine(line)
                        self?.emitLog("[stderr] \(line)")
                    }
                }

                // Clean up readability handlers
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil

                self?.lockedRunningProcess.withLock { $0 = nil }

                // TKT-016: if cancellation is in progress, the cancel-failure status
                // already wrote to lockedStatus. Don't overwrite it with success or an
                // unrelated failure based on the actual exit code — always throw
                // .cancelled and let the build pipeline propagate it up.
                let isCancelling = self?.lockedIsCancelling.withLock { $0 } ?? false
                if isCancelling {
                    // TKT-045: deterministically finish the log stream so any
                    // in-flight `for await` consumer in BuildManager exits on
                    // its next iteration rather than racing logTask.cancel().
                    self?.finishLogContinuation()
                    continuation.resume(throwing: BuildError.cancelled)
                    return
                }

                if proc.terminationReason == .uncaughtSignal {
                    // TKT-045: drain log stream symmetrically on the
                    // signal-cancellation branch.
                    self?.finishLogContinuation()
                    continuation.resume(throwing: BuildError.cancelled)
                } else if proc.terminationStatus != 0 {
                    // TKT-045: surface the last stderr line(s) in the failure
                    // message so the companion's status frame and the Prowl
                    // notification show the actual xcodebuild error rather
                    // than just "exit code N".
                    let msg = self?.failureMessage(forExitCode: proc.terminationStatus)
                        ?? "xcodebuild failed (exit \(proc.terminationStatus))"
                    self?.setStatus(.failure(error: msg))
                    self?.finishLogContinuation()
                    continuation.resume(throwing: BuildError.xcodebuildFailed(proc.terminationStatus, msg))
                } else {
                    // Note: do NOT finish the log continuation on the
                    // success branch — `build(project:)` calls
                    // `runXcodebuild` twice (archive + export), and the
                    // continuation must stay alive across both phases so
                    // the export step's log lines still reach the consumer.
                    continuation.resume()
                }
            }

            do {
                try process.run()
            } catch {
                lockedRunningProcess.withLock { $0 = nil }
                continuation.resume(throwing: error)
            }
        }
    }

    /// Appends a stderr line to the ring buffer, trimming to the most recent
    /// `stderrRingCapacity` entries. Thread-safe.
    private func appendStderrLine(_ line: String) {
        lockedRecentStderrLines.withLock { lines in
            lines.append(line)
            if lines.count > Self.stderrRingCapacity {
                lines.removeFirst(lines.count - Self.stderrRingCapacity)
            }
        }
    }

    /// Builds the failure message for a non-zero xcodebuild exit, appending the
    /// last meaningful stderr line from the ring buffer when one is available.
    /// Falls back to the bare exit-code message if no stderr lines were captured.
    private func failureMessage(forExitCode code: Int32) -> String {
        let recent = lockedRecentStderrLines.withLock { $0 }
        // Prefer the last non-empty, non-whitespace line so we don't surface
        // stray blank trailers from xcodebuild.
        let meaningful = recent.last { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        if let tail = meaningful {
            return "xcodebuild failed (exit \(code)): \(tail)"
        }
        return "xcodebuild failed (exit \(code))"
    }

    /// Finishes the engine's current log-stream continuation (if any) so that
    /// `for await` consumers exit deterministically. Called from every exit
    /// branch of `runXcodebuild`'s termination handler.
    private func finishLogContinuation() {
        lockedLogContinuation.withLock { cont in
            cont?.finish()
            cont = nil
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
        let safeMethod = xmlEscape(method)
        let safeTeamID = xmlEscape(teamID)
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" \
        "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>method</key>
            <string>\(safeMethod)</string>
            <key>teamID</key>
            <string>\(safeTeamID)</string>
            <key>stripSwiftSymbols</key>
            <true/>
            <key>compileBitcode</key>
            <false/>
        </dict>
        </plist>
        """
    }

    /// Escapes XML special characters to prevent injection in plist generation.
    private func xmlEscape(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
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
        lockedStatus.withLock { $0 = newStatus }
    }

    /// Emits a single log line to the async build log stream.
    ///
    /// - Parameter line: The log message to emit.
    private func emitLog(_ line: String) {
        let cont = lockedLogContinuation.withLock { $0 }
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
