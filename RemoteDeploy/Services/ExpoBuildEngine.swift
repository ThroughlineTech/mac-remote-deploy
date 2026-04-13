// Build engine for React Native / Expo projects.
// Runs: npm install -> expo prebuild -> pod install -> xcodebuild archive -> export IPA.
// Conforms to BuildEngineProtocol so BuildManager can use it interchangeably. TKT-048.
import Foundation
import os

final class ExpoBuildEngine: BuildEngineProtocol, @unchecked Sendable {

    // MARK: - Private State

    private let lockedStatus = OSAllocatedUnfairLock<BuildStatus>(initialState: .idle)
    private let lockedLogContinuation = OSAllocatedUnfairLock<AsyncStream<String>.Continuation?>(initialState: nil)

    /// Shared runner used across all phases of a single build.
    /// Cancel propagates to whichever phase is active.
    private let processRunner: any ProcessRunning

    /// Delegates the xcodebuild archive + export phase to the native engine.
    private let xcodeEngine: any BuildEngineProtocol

    // MARK: - Protocol Properties

    var status: BuildStatus {
        lockedStatus.withLock { $0 }
    }

    var buildLogStream: AsyncStream<String> {
        let (stream, continuation) = AsyncStream<String>.makeStream(of: String.self, bufferingPolicy: .unbounded)
        lockedLogContinuation.withLock {
            $0?.finish()
            $0 = continuation
        }
        return stream
    }

    // MARK: - Init

    /// Creates an Expo build engine.
    /// - Parameters:
    ///   - processRunner: The runner for shell commands. Defaults to a real `ProcessRunner`.
    ///   - xcodeEngine: The engine for the xcodebuild phase. Defaults to a real `XcodeBuildEngine`.
    init(processRunner: any ProcessRunning = ProcessRunner(),
         xcodeEngine: any BuildEngineProtocol = XcodeBuildEngine()) {
        self.processRunner = processRunner
        self.xcodeEngine = xcodeEngine
    }

    // MARK: - Build Pipeline

    /// Runs the full Expo build pipeline:
    /// 1. npm install (in project root)
    /// 2. npx expo prebuild --clean --no-install (in app directory)
    /// 3. pod install (in app/ios/)
    /// 4. xcodebuild archive + export (via XcodeBuildEngine)
    /// 5. Copy IPA to serve directory
    func build(project: ProjectConfig) async throws -> String {
        processRunner.reset()
        setStatus(.building(progress: "Preparing Expo build..."))

        let projectRoot = project.projectPath
        let appDir: String
        if let expoApp = project.expoAppDirectory, !expoApp.isEmpty {
            appDir = (projectRoot as NSString).appendingPathComponent(expoApp)
        } else {
            appDir = projectRoot
        }
        let iosDir = (appDir as NSString).appendingPathComponent("ios")

        // Validate app.json exists
        let appJsonPath = (appDir as NSString).appendingPathComponent("app.json")
        guard FileManager.default.fileExists(atPath: appJsonPath) else {
            let msg = "No app.json found at \(appDir). Is this an Expo project?"
            setStatus(.failure(error: msg))
            throw ExpoBuildError.missingAppJson(appDir)
        }

        // Phase 1: npm install
        try await runPhase("npm install", command: "npm", arguments: ["install"], workingDirectory: projectRoot)

        // Phase 2: expo prebuild
        try await runPhase("expo prebuild", command: "npx", arguments: ["expo", "prebuild", "--clean", "--no-install"], workingDirectory: appDir)

        // Phase 3: pod install
        try await runPhase("pod install", command: "pod", arguments: ["install"], workingDirectory: iosDir)

        // Phase 4: xcodebuild archive + export via XcodeBuildEngine
        // Configure a modified project config pointing at the generated ios/ workspace.
        var xcodeProject = project
        xcodeProject.projectPath = iosDir
        // Auto-detect the workspace in the ios/ directory
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: iosDir)) ?? []
        if let workspace = contents.first(where: { $0.hasSuffix(".xcworkspace") }) {
            xcodeProject.workspaceFile = workspace
        }
        // Clear projectFile to avoid conflicts
        xcodeProject.projectFile = nil

        setStatus(.building(progress: "Building with xcodebuild..."))
        emitLog("=== Phase 4/4: xcodebuild archive + export ===")

        // Subscribe to xcode engine's log stream and forward to our stream
        let xcodeLogStream = xcodeEngine.buildLogStream
        let forwardTask = Task { [weak self] in
            for await line in xcodeLogStream {
                self?.emitLog(line)
            }
        }

        let ipaPath: String
        do {
            ipaPath = try await xcodeEngine.build(project: xcodeProject)
        } catch {
            forwardTask.cancel()
            let msg = error.localizedDescription
            setStatus(.failure(error: msg))
            finishLogContinuation()
            throw error
        }

        forwardTask.cancel()
        setStatus(.success(ipaPath: ipaPath))
        emitLog("Expo build complete: \(ipaPath)")
        finishLogContinuation()

        return ipaPath
    }

    // MARK: - Cancel

    func cancelBuild() async {
        processRunner.cancel()
        await xcodeEngine.cancelBuild()
        emitLog("Build cancelled by user.")
        setStatus(.failure(error: "Build cancelled."))
    }

    // MARK: - Scheme Detection

    /// Detects schemes in an Expo project. If the ios/ directory doesn't exist,
    /// runs prebuild first, then delegates to xcodebuild -list.
    func detectSchemes(at projectPath: String) async throws -> [String] {
        // Determine where the ios/ dir should be
        let fm = FileManager.default

        // Check if this looks like a monorepo root with an app.json somewhere
        let appJsonDirect = (projectPath as NSString).appendingPathComponent("app.json")
        let iosDir: String

        if fm.fileExists(atPath: appJsonDirect) {
            iosDir = (projectPath as NSString).appendingPathComponent("ios")
        } else {
            // Scan immediate subdirectories for app.json
            let subdirs = (try? fm.contentsOfDirectory(atPath: projectPath)) ?? []
            if let appSubdir = subdirs.first(where: { sub in
                let candidate = (projectPath as NSString).appendingPathComponent(sub)
                    .appending("/app.json")
                return fm.fileExists(atPath: candidate)
            }) {
                iosDir = (projectPath as NSString).appendingPathComponent(appSubdir).appending("/ios")
            } else {
                iosDir = (projectPath as NSString).appendingPathComponent("ios")
            }
        }

        // If ios/ doesn't exist, run prebuild to generate it
        if !fm.fileExists(atPath: iosDir) {
            let appDir = (iosDir as NSString).deletingLastPathComponent
            try await processRunner.run(
                command: "npx",
                arguments: ["expo", "prebuild", "--no-install"],
                workingDirectory: appDir,
                onOutput: { _ in }
            )
        }

        return try await xcodeEngine.detectSchemes(at: iosDir)
    }

    // MARK: - Private Helpers

    /// Runs a named build phase with process streaming.
    private func runPhase(
        _ name: String,
        command: String,
        arguments: [String],
        workingDirectory: String
    ) async throws {
        guard !processRunner.isCancelled else { throw ProcessRunnerError.cancelled }

        let phaseIndex = phaseNumber(for: name)
        setStatus(.building(progress: "\(name)..."))
        emitLog("=== Phase \(phaseIndex): \(name) ===")

        do {
            try await processRunner.run(
                command: command,
                arguments: arguments,
                workingDirectory: workingDirectory,
                onOutput: { [weak self] line in
                    self?.emitLog("[\(name)] \(line)")
                }
            )
        } catch {
            let msg = "\(name) failed: \(error.localizedDescription)"
            setStatus(.failure(error: msg))
            finishLogContinuation()
            throw ExpoBuildError.phaseFailed(name, error.localizedDescription)
        }
    }

    /// Maps phase names to step numbers for display.
    private func phaseNumber(for name: String) -> String {
        switch name {
        case "npm install": return "1/4"
        case "expo prebuild": return "2/4"
        case "pod install": return "3/4"
        default: return "?/4"
        }
    }

    private func setStatus(_ newStatus: BuildStatus) {
        lockedStatus.withLock { $0 = newStatus }
    }

    private func emitLog(_ line: String) {
        let cont = lockedLogContinuation.withLock { $0 }
        cont?.yield(line)
    }

    private func finishLogContinuation() {
        lockedLogContinuation.withLock { cont in
            cont?.finish()
            cont = nil
        }
    }
}

// MARK: - Expo Build Errors

/// Errors specific to the Expo build pipeline.
enum ExpoBuildError: LocalizedError {
    /// No app.json found in the expected Expo app directory.
    case missingAppJson(String)
    /// A build phase (npm install, prebuild, pod install) failed.
    case phaseFailed(String, String)

    var errorDescription: String? {
        switch self {
        case .missingAppJson(let dir):
            return "No app.json found at \(dir). Is this an Expo project?"
        case .phaseFailed(let phase, let detail):
            return "\(phase) failed: \(detail)"
        }
    }
}
