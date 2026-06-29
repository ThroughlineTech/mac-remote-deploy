// Real implementation of SchemeDetecting that shells out to `xcodebuild -list`
// and parses the "Schemes:" section of its output.
//
// It resolves a usable Xcode developer directory rather than trusting the
// `/usr/bin/xcodebuild` shim blindly: if the active developer directory points
// at a Command Line Tools instance (which has no `xcodebuild`), it falls back to
// a full Xcode discovered in /Applications. Failures are surfaced as a thrown
// `SchemeDetectionError` so the caller can show an actionable message instead of
// an empty, indistinguishable result.
import Foundation

/// Error describing why scheme detection could not run or produce a result.
enum SchemeDetectionError: LocalizedError {
    /// No usable Xcode could be found (active dir is Command Line Tools and no Xcode in /Applications).
    case xcodeNotInstalled
    /// The xcodebuild process could not be launched.
    case launchFailed(String)
    /// xcodebuild ran but exited non-zero; carries a summary of its stderr.
    case xcodebuildFailed(status: Int32, message: String)
    /// No `.xcodeproj`/`.xcworkspace` (and no XcodeGen `project.yml`) was found. TKT-072.
    case noProjectFound(String)
    /// An XcodeGen `project.yml` was present but generation failed. TKT-072.
    case xcodegenFailed(String)

    var errorDescription: String? {
        switch self {
        case .xcodeNotInstalled:
            return "Xcode is required to detect schemes but none is selected. Install Xcode, then run: "
                + "sudo xcode-select -s /Applications/Xcode.app"
        case .launchFailed(let detail):
            return "Could not run xcodebuild: \(detail)"
        case .xcodebuildFailed(let status, let message):
            return message.isEmpty
                ? "xcodebuild failed (exit \(status))."
                : "xcodebuild failed: \(message)"
        case .noProjectFound(let path):
            return "No Xcode project found at \(path). Expected a .xcodeproj, .xcworkspace, "
                + "or an XcodeGen project.yml (directly or one level below)."
        case .xcodegenFailed(let detail):
            return detail
        }
    }
}

/// Detects Xcode schemes by invoking `xcodebuild -list` and parsing its output.
final class XcodebuildSchemeDetector: SchemeDetecting, @unchecked Sendable {

    /// Detects schemes at the given path by running `xcodebuild -list`.
    ///
    /// TKT-072: the path may be a `.xcodeproj`/`.xcworkspace` bundle, the directory
    /// containing one, an XcodeGen project directory (whose `.xcodeproj` is
    /// regenerated from `project.yml` first), or a monorepo root one level above
    /// the iOS app. This makes freshly-cloned XcodeGen projects detectable without
    /// a checked-in `.xcodeproj`.
    ///
    /// - Parameter atPath: Absolute path to a project bundle or a directory.
    /// - Returns: Parsed scheme names. Empty only when xcodebuild succeeds but the project has no schemes.
    /// - Throws: `SchemeDetectionError` when no Xcode/project is available, generation fails, or xcodebuild fails.
    func detectSchemes(atPath path: String) throws -> [String] {
        let isBundle = path.hasSuffix(".xcodeproj") || path.hasSuffix(".xcworkspace")
        let projectDir = isBundle
            ? (path as NSString).deletingLastPathComponent
            : XcodeGenSupport.resolveProjectDirectory(path)

        // Regenerate the .xcodeproj from project.yml if this is an XcodeGen project.
        do {
            try XcodeGenSupport.regenerateIfNeeded(inDirectory: projectDir)
        } catch {
            throw SchemeDetectionError.xcodegenFailed(error.localizedDescription)
        }

        let (flag, projectArg) = try Self.resolveProjectArgument(path: path, projectDir: projectDir, isBundle: isBundle)

        let developerDir = try Self.resolveDeveloperDir()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: developerDir + "/usr/bin/xcodebuild")
        process.arguments = ["-list", flag, projectArg]
        // Pin the chosen toolchain so the shim/subprocesses don't fall back to the active dir.
        var env = ProcessInfo.processInfo.environment
        env["DEVELOPER_DIR"] = developerDir
        process.environment = env

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            throw SchemeDetectionError.launchFailed(error.localizedDescription)
        }

        // Drain both pipes concurrently to avoid a deadlock if either fills its buffer.
        var errData = Data()
        let errHandle = errPipe.fileHandleForReading
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            errData = errHandle.readDataToEndOfFile()
            group.leave()
        }
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        group.wait()

        guard process.terminationStatus == 0 else {
            let stderr = String(data: errData, encoding: .utf8) ?? ""
            throw SchemeDetectionError.xcodebuildFailed(
                status: process.terminationStatus,
                message: Self.summarize(stderr)
            )
        }

        let output = String(data: outData, encoding: .utf8) ?? ""
        return Self.parseSchemes(from: output)
    }

    /// Resolves which `-project`/`-workspace` argument to pass `xcodebuild -list`.
    /// A bundle path is used directly; a directory is scanned for a `.xcworkspace`
    /// (preferred) or `.xcodeproj`. Throws `.noProjectFound` when neither exists.
    /// TKT-072.
    static func resolveProjectArgument(
        path: String,
        projectDir: String,
        isBundle: Bool
    ) throws -> (flag: String, path: String) {
        if isBundle {
            return (path.hasSuffix(".xcworkspace") ? "-workspace" : "-project", path)
        }
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: projectDir)) ?? []
        if let workspace = contents.first(where: { $0.hasSuffix(".xcworkspace") }) {
            return ("-workspace", (projectDir as NSString).appendingPathComponent(workspace))
        }
        if let project = contents.first(where: { $0.hasSuffix(".xcodeproj") }) {
            return ("-project", (projectDir as NSString).appendingPathComponent(project))
        }
        throw SchemeDetectionError.noProjectFound(path)
    }

    // MARK: - Developer directory resolution

    /// Resolves a developer directory that actually contains `xcodebuild`.
    ///
    /// Prefers the active developer dir when it points at a full Xcode, then
    /// falls back to a discovered `/Applications/Xcode*.app` (preferring the
    /// stable `Xcode.app` over betas).
    static func resolveDeveloperDir() throws -> String {
        let fm = FileManager.default
        func hasXcodebuild(_ dev: String) -> Bool {
            fm.isExecutableFile(atPath: dev + "/usr/bin/xcodebuild")
        }

        // 1. Honor the active developer directory if it is a full Xcode.
        if let active = runCapturing("/usr/bin/xcode-select", ["-p"])?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !active.isEmpty,
            !active.contains("CommandLineTools"),
            hasXcodebuild(active) {
            return active
        }

        // 2. Fall back to a discovered Xcode in /Applications, preferring the stable one.
        var apps = ((try? fm.contentsOfDirectory(atPath: "/Applications")) ?? [])
            .filter { $0.hasPrefix("Xcode") && $0.hasSuffix(".app") }
            .sorted()
        if let stableIndex = apps.firstIndex(of: "Xcode.app") {
            apps.insert(apps.remove(at: stableIndex), at: 0)
        }
        for app in apps {
            let dev = "/Applications/\(app)/Contents/Developer"
            if hasXcodebuild(dev) { return dev }
        }

        throw SchemeDetectionError.xcodeNotInstalled
    }

    /// Runs a command and returns its stdout, or nil if it could not be launched.
    private static func runCapturing(_ launchPath: String, _ args: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Parsing

    /// Parses the scheme names from `xcodebuild -list` output.
    static func parseSchemes(from output: String) -> [String] {
        var schemes: [String] = []
        var inSchemes = false
        for line in output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "Schemes:" {
                inSchemes = true
            } else if inSchemes {
                if trimmed.isEmpty || trimmed.hasSuffix(":") { break }
                schemes.append(trimmed)
            }
        }
        return schemes
    }

    /// Reduces xcodebuild stderr to the most useful single line for display.
    static func summarize(_ stderr: String) -> String {
        let lines = stderr
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let summary = lines.last(where: { $0.lowercased().contains("error:") }) ?? lines.last ?? ""
        return summary.count > 300 ? String(summary.prefix(300)) + "..." : summary
    }
}
