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

    /// Set to true by the per-invocation watchdog when an `xcodebuild` process
    /// runs past the build timeout. Reset at the start of each `runXcodebuild`.
    /// Mirrors `lockedIsCancelling`: the watchdog only terminates the process and
    /// sets this flag; the terminationHandler observes it and resumes with
    /// `BuildError.timedOut`, so there is exactly one continuation resume. TKT-075.
    private let lockedTimedOut = OSAllocatedUnfairLock<Bool>(initialState: false)

    /// Per-build override (in seconds) for the watchdog timeout, taken from the
    /// project's `buildTimeoutSeconds`. Set at the start of `build()` and consulted
    /// by `runXcodebuild`. Nil means use `defaultBuildTimeout`. Builds are
    /// serialized, so a single per-engine slot is sufficient. TKT-075.
    private let lockedTimeoutOverride = OSAllocatedUnfairLock<TimeInterval?>(initialState: nil)

    /// Ring buffer of the most recent stderr lines from xcodebuild. Capped at
    /// `stderrRingCapacity` entries and reset at the start of each `runXcodebuild`
    /// call. The tail of this buffer is included in `BuildError.xcodebuildFailed`'s
    /// message on a non-zero exit so the companion (and Prowl notification) can
    /// surface the actual xcodebuild error to the user instead of just an exit
    /// code. See TKT-045.
    private let lockedRecentStderrLines = OSAllocatedUnfairLock<[String]>(initialState: [])

    /// Maximum number of recent stderr lines retained for the failure message tail.
    private static let stderrRingCapacity = 8

    /// Default watchdog timeout, in seconds, applied to each `xcodebuild`
    /// invocation when a project doesn't override it. Generous enough for a large
    /// clean build but bounded so a hung invocation (e.g. `-allowProvisioningUpdates`
    /// blocking on Apple with an invalid team) can't pin the build to "building"
    /// forever. TKT-075.
    static let defaultBuildTimeout: TimeInterval = 20 * 60

    /// The watchdog timeout (in seconds) used when a project supplies no
    /// `buildTimeoutSeconds` override. Injectable so tests can drive the timeout
    /// path quickly. A value <= 0 disables the timeout (unbounded).
    private let defaultTimeout: TimeInterval

    /// Memoized active Xcode developer directory used to run xcodebuild via
    /// `DEVELOPER_DIR`. Computed lazily on first build/detect. The double
    /// optional distinguishes "not yet computed" (outer `nil`) from "computed,
    /// but no full Xcode found" (inner `nil`). See `developerDirectory()`.
    private let lockedDeveloperDir = OSAllocatedUnfairLock<String??>(initialState: nil)

    /// Per-build override for `DEVELOPER_DIR`, taken from the project's
    /// `developerDir`. Set at the start of `build()` and consulted by
    /// `applyXcodebuildEnvironment` so a project can pin a specific Xcode
    /// (e.g. a beta for a newer SDK). Nil means auto-resolve. TKT-072. Builds are
    /// serialized, so a single per-engine slot is sufficient.
    private let lockedDeveloperDirOverride = OSAllocatedUnfairLock<String?>(initialState: nil)

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

    /// - Parameter timeout: Default watchdog timeout (seconds) for each xcodebuild
    ///   invocation when a project doesn't override it via `buildTimeoutSeconds`.
    ///   Defaults to `defaultBuildTimeout` (20 minutes). A value <= 0 disables it.
    init(timeout: TimeInterval = XcodeBuildEngine.defaultBuildTimeout) {
        self.defaultTimeout = timeout
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
        // Reset cancellation flag at the start of every new build so a previous
        // cancellation doesn't carry over and immediately fail this build.
        lockedIsCancelling.withLock { $0 = false }
        // TKT-072: pin this build to the project's chosen Xcode toolchain, if any.
        lockedDeveloperDirOverride.withLock { $0 = project.developerDir }
        // TKT-075: apply the project's per-build watchdog override, if any.
        lockedTimeoutOverride.withLock { $0 = project.buildTimeoutSeconds.map(TimeInterval.init) }
        setStatus(.building(progress: "Preparing build…"))

        // TKT-072: resolve the directory that actually holds the project (so a path
        // pointing at a monorepo root resolves to the iOS app subdir) and regenerate
        // the .xcodeproj from project.yml first, so XcodeGen-managed projects build
        // from their current spec rather than a stale or missing generated project.
        // No-op for projects without a project.yml spec.
        let projectDir = XcodeGenSupport.resolveProjectDirectory(project.projectPath)
        // TKT-072: emit progress up front so the build log isn't blank during prep
        // (and an early failure still shows context, not an empty log).
        emitLog("Building \(project.scheme) [\(project.buildConfiguration)] for \(project.platform)")
        if projectDir != project.projectPath {
            emitLog("Resolved project directory: \(projectDir) (from \(project.projectPath))")
        }
        try regenerateXcodeGenProject(inDirectory: projectDir)

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
            // projectPath is a directory — scan the resolved project dir (TKT-072:
            // may be a monorepo subdir) for .xcworkspace or .xcodeproj inside it.
            let contents = (try? fm.contentsOfDirectory(atPath: projectDir)) ?? []
            if let ws = contents.first(where: { $0.hasSuffix(".xcworkspace") }) {
                archiveArgs += ["-workspace", (projectDir as NSString).appendingPathComponent(ws)]
            } else if let proj = contents.first(where: { $0.hasSuffix(".xcodeproj") }) {
                archiveArgs += ["-project", (projectDir as NSString).appendingPathComponent(proj)]
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

        // TKT-072: let xcodebuild register the App ID + capabilities and build a
        // managed profile from the CLI (needed when the bundle ID / entitlements
        // aren't already provisioned). Mirrors Xcode's automatic signing.
        if project.allowProvisioningUpdates {
            archiveArgs.append("-allowProvisioningUpdates")
        }

        emitLog("$ xcodebuild \(archiveArgs.dropFirst().joined(separator: " "))")
        try await runXcodebuild(arguments: Array(archiveArgs.dropFirst()))

        // Verify archive was created
        guard fm.fileExists(atPath: archivePath) else {
            let msg = "Archive not found at \(archivePath) after xcodebuild completed."
            setStatus(.failure(error: msg))
            throw BuildError.archiveFailed(msg)
        }

        // Branch by platform: macOS skips exportArchive and zips the .app bundle
        // directly from the archive; iOS continues through the IPA export pipeline.
        if project.platform.lowercased() == "macos" {
            setStatus(.building(progress: "Packaging macOS app…"))

            let zipPath = try zipAppBundle(archivePath: archivePath, serveDir: serveDir)

            setStatus(.success(ipaPath: zipPath))
            emitLog("Build complete: \(zipPath)")
            return zipPath
        } else {
            // -- Step 2: Generate ExportOptions.plist --
            setStatus(.building(progress: "Exporting IPA…"))

            let exportPlist = generateExportOptionsPlist(
                method: project.exportMethod,
                teamID: project.teamID
            )
            try exportPlist.write(toFile: exportPlistPath, atomically: true, encoding: .utf8)

            // -- Step 3: Export Archive → IPA --
            var exportArgs: [String] = [
                "-exportArchive",
                "-archivePath", archivePath,
                "-exportOptionsPlist", exportPlistPath,
                "-exportPath", exportDir
            ]
            // TKT-072: also allow managed-profile updates during export so signing
            // the IPA doesn't fall back to a wildcard profile missing entitlements.
            if project.allowProvisioningUpdates {
                exportArgs.append("-allowProvisioningUpdates")
            }

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
        // TKT-072: resolve the directory that actually holds the project (so a
        // monorepo root resolves to the iOS app subdir) and regenerate the
        // .xcodeproj from project.yml first, so XcodeGen-managed projects (whose
        // generated .xcodeproj is kept out of source control) are present and
        // current before xcodebuild reads them.
        let isBundle = projectPath.hasSuffix(".xcodeproj") || projectPath.hasSuffix(".xcworkspace")
        let projectDir = isBundle
            ? (projectPath as NSString).deletingLastPathComponent
            : XcodeGenSupport.resolveProjectDirectory(projectPath)
        try regenerateXcodeGenProject(inDirectory: projectDir)
        let resolved = try resolveXcodeProject(at: isBundle ? projectPath : projectDir)
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
        // TKT-075: reset the timed-out flag for this invocation.
        lockedTimedOut.withLock { $0 = false }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["xcodebuild"] + arguments
        applyXcodebuildEnvironment(to: process)

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

        // TKT-075: watchdog that terminates xcodebuild if it runs past the timeout.
        // Mirrors cancelBuild(): it only claims the timeout (atomically, and only
        // while the process is still alive) and terminates the process; the
        // terminationHandler observes `lockedTimedOut` and resumes the continuation
        // with BuildError.timedOut, so the continuation is resumed exactly once.
        // `process` is captured weakly so the cycle process -> terminationHandler
        // (which retains this watchdog) -> watchdog does not leak the Process; GCD
        // also retains the work item until the deadline, so a strong capture would
        // pin the Process for the full timeout after a fast build.
        let effectiveTimeout = lockedTimeoutOverride.withLock { $0 } ?? defaultTimeout
        let watchdog = DispatchWorkItem { [weak self, weak process] in
            guard let self, let process else { return }
            let claimed = self.lockedTimedOut.withLock { timedOut -> Bool in
                guard !timedOut, process.isRunning else { return false }
                timedOut = true
                return true
            }
            guard claimed else { return }
            let msg = "Build timed out after \(Int(effectiveTimeout))s; terminating xcodebuild."
            self.emitLog(msg)
            self.setStatus(.failure(error: "Build timed out after \(Int(effectiveTimeout))s."))
            process.terminate()
        }

        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { [weak self] proc in
                // TKT-075: the process has exited (normally, by cancel, or by the
                // watchdog's terminate). Stop the watchdog so it can't fire against
                // a future build; if it already fired, `lockedTimedOut` is set and
                // the timed-out branch below handles the resume.
                watchdog.cancel()
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

                // TKT-075: the watchdog terminated this process for exceeding the
                // timeout. Like the cancel branch, the watchdog already wrote the
                // failure status, so don't override it with the signal/exit-code
                // status; just finish the log stream and surface BuildError.timedOut.
                let didTimeOut = self?.lockedTimedOut.withLock { $0 } ?? false
                if didTimeOut {
                    self?.finishLogContinuation()
                    continuation.resume(throwing: BuildError.timedOut(effectiveTimeout))
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
                // TKT-075: arm the watchdog only after the process is actually
                // running, and only when a positive timeout is configured (a
                // value <= 0 means "unbounded"). If the process exits first, the
                // terminationHandler cancels this before it fires.
                if effectiveTimeout > 0 {
                    DispatchQueue.global().asyncAfter(deadline: .now() + effectiveTimeout, execute: watchdog)
                }
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
        applyXcodebuildEnvironment(to: process)

        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice

        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { proc in
                let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? ""

                if proc.terminationStatus != 0 {
                    let msg = Self.xcodebuildFailureHint(forExitCode: proc.terminationStatus)
                        ?? "xcodebuild -list failed with code \(proc.terminationStatus)"
                    continuation.resume(throwing: BuildError.xcodebuildFailed(
                        proc.terminationStatus,
                        msg
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

    /// Locates the `.app` bundle inside the archive's Products/Applications directory,
    /// zips it with `ditto`, and writes the result to `<serveDir>/app.zip`.
    ///
    /// - Parameter archivePath: Absolute path to the `.xcarchive` bundle.
    /// - Parameter serveDir: Absolute path to the project's serve directory.
    /// - Returns: The absolute path to the generated `app.zip`.
    /// - Throws: If the `.app` bundle is not found or `ditto` fails.
    private func zipAppBundle(archivePath: String, serveDir: String) throws -> String {
        let fm = FileManager.default
        let appsDir = "\(archivePath)/Products/Applications"

        guard let appBundle = (try? fm.contentsOfDirectory(atPath: appsDir))?
            .first(where: { $0.hasSuffix(".app") }) else {
            let msg = "No .app bundle found in \(appsDir)."
            setStatus(.failure(error: msg))
            throw BuildError.exportFailed(msg)
        }

        let appPath = "\(appsDir)/\(appBundle)"
        let zipPath = "\(serveDir)/app.zip"

        // Remove previous zip if present
        if fm.fileExists(atPath: zipPath) {
            try fm.removeItem(atPath: zipPath)
        }

        // Use ditto to create a zip preserving resource forks and metadata
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-ck", "--keepParent", appPath, zipPath]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let msg = "ditto failed to zip \(appBundle) (exit \(process.terminationStatus))."
            setStatus(.failure(error: msg))
            throw BuildError.exportFailed(msg)
        }

        emitLog("Zipped \(appBundle) → app.zip")
        return zipPath
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

    // MARK: - XcodeGen Integration

    /// Regenerates the `.xcodeproj` from a `project.yml` spec in `dir`, streaming
    /// xcodegen's output to the build log. A no-op for directories with no spec.
    /// TKT-072: delegates to the shared `XcodeGenSupport` so the build and
    /// scheme-detection paths can't drift; wraps its error as a `BuildError`.
    private func regenerateXcodeGenProject(inDirectory dir: String) throws {
        do {
            try XcodeGenSupport.regenerateIfNeeded(inDirectory: dir) { [weak self] line in
                self?.emitLog(line)
            }
        } catch {
            throw BuildError.xcodegenFailed(error.localizedDescription)
        }
    }

    // MARK: - Toolchain Resolution

    /// Sets `DEVELOPER_DIR` on the process when a usable full Xcode is found,
    /// so xcodebuild works regardless of what `xcode-select` points at. When no
    /// full Xcode can be located the environment is left untouched and the
    /// caller surfaces the resulting xcrun error (see `xcodebuildFailureHint`).
    ///
    /// TKT-072: a valid per-project override (`developerDir`) wins over the
    /// auto-resolved toolchain, so a project can pin a specific Xcode. An override
    /// that doesn't contain `xcodebuild` is ignored in favor of auto-resolution.
    private func applyXcodebuildEnvironment(to process: Process) {
        let override = lockedDeveloperDirOverride.withLock { $0 }
        let devDir: String?
        if let override, FileManager.default.isExecutableFile(atPath: override + "/usr/bin/xcodebuild") {
            devDir = override
        } else {
            devDir = developerDirectory()
        }
        guard let devDir else { return }
        var env = ProcessInfo.processInfo.environment
        env["DEVELOPER_DIR"] = devDir
        process.environment = env
    }

    /// Returns a developer directory that contains a runnable `xcodebuild`,
    /// memoizing the result for the lifetime of the engine.
    private func developerDirectory() -> String? {
        lockedDeveloperDir.withLock { cache in
            if let computed = cache { return computed }
            let resolved = Self.resolveDeveloperDir()
            cache = .some(resolved)
            return resolved
        }
    }

    /// Locates a developer directory that ships `xcodebuild`.
    ///
    /// Order: the active `xcode-select` directory (if it can actually build),
    /// then the well-known full-Xcode install paths, then a Spotlight query for
    /// any Xcode bundle. Returns `nil` if only the Command Line Tools (which
    /// have no `xcodebuild`) are available, which is exactly the state that
    /// makes `xcrun xcodebuild` fail with exit 72.
    private static func resolveDeveloperDir() -> String? {
        let fm = FileManager.default
        func canBuild(_ dir: String) -> Bool {
            fm.isExecutableFile(atPath: (dir as NSString).appendingPathComponent("usr/bin/xcodebuild"))
        }

        if let active = runCapturingTrimmed("/usr/bin/xcode-select", ["-p"]), canBuild(active) {
            return active
        }

        let known = [
            "/Applications/Xcode.app/Contents/Developer",
            "/Applications/Xcode-beta.app/Contents/Developer",
        ]
        if let hit = known.first(where: canBuild) {
            return hit
        }

        if let spotlighted = spotlightXcodeDeveloperDir(), canBuild(spotlighted) {
            return spotlighted
        }
        return nil
    }

    /// Uses Spotlight to find any installed Xcode bundle and returns its
    /// `Contents/Developer` directory, or `nil` if none is indexed.
    private static func spotlightXcodeDeveloperDir() -> String? {
        guard let app = runCapturingTrimmed(
            "/usr/bin/mdfind",
            ["kMDItemCFBundleIdentifier == 'com.apple.dt.Xcode'"]
        )?.components(separatedBy: .newlines).first(where: { $0.hasSuffix(".app") }) else {
            return nil
        }
        return (app as NSString).appendingPathComponent("Contents/Developer")
    }

    /// Maps a well-known non-zero xcodebuild/xcrun exit code to an actionable
    /// hint. Exit 72 (`EX_OSFILE`) is what xcrun returns when no full Xcode is
    /// selected as the active developer directory -- e.g. only the Command Line
    /// Tools are installed -- which is otherwise an opaque failure.
    private static func xcodebuildFailureHint(forExitCode code: Int32) -> String? {
        guard code == 72 else { return nil }
        return "no usable Xcode found (only the Command Line Tools are selected). "
            + "Install Xcode, then run: "
            + "sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
    }

    /// Runs a process and returns its trimmed stdout, or `nil` if it fails to
    /// launch, exits non-zero, or produces no output. Used for short toolchain
    /// probes (`xcode-select -p`, `mdfind`, `which`).
    private static func runCapturingTrimmed(_ launchPath: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let trimmed = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty == false) ? trimmed : nil
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
    /// `xcodegen generate` failed, or a project.yml spec was present but
    /// XcodeGen was not installed.
    case xcodegenFailed(String)
    /// The build was cancelled (process was terminated by signal).
    case cancelled
    /// An xcodebuild invocation ran past the watchdog timeout (in seconds) and was
    /// terminated. Carries the timeout that was exceeded. TKT-075.
    case timedOut(TimeInterval)

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
        case .xcodegenFailed(let msg):
            return "XcodeGen failed: \(msg)"
        case .cancelled:
            return "Build was cancelled."
        case .timedOut(let seconds):
            return "Build timed out after \(Int(seconds))s."
        }
    }
}
