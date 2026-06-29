// Shared XcodeGen support: spec detection, binary resolution, project
// regeneration, and resolving a user-supplied path to the directory that
// actually holds a buildable project. TKT-072.
//
// XcodeGen-managed projects keep the generated `.xcodeproj` out of source
// control (it is rebuilt from `project.yml`), so a fresh checkout has no
// `.xcodeproj` at all. Both the build engine (build time) and the scheme
// detector (config time) need to regenerate it before xcodebuild reads it; this
// type is the single implementation they share so the two paths can't drift.
import Foundation

/// Why XcodeGen project generation could not run or produce a project.
enum XcodeGenError: LocalizedError {
    /// A `project.yml` spec was found but the XcodeGen binary is not installed.
    case notInstalled(specName: String)
    /// `xcodegen generate` exited non-zero; carries a short message.
    case generateFailed(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled(let specName):
            return "Found \(specName) but XcodeGen is not installed. Install it with: brew install xcodegen"
        case .generateFailed(let detail):
            return "xcodegen generate failed: \(detail)"
        }
    }
}

enum XcodeGenSupport {

    /// Candidate XcodeGen spec filenames, in preference order.
    static let specCandidates = ["project.yml", "project.yaml"]

    /// Returns the XcodeGen spec filename present directly in `dir`, or nil.
    static func specName(inDirectory dir: String) -> String? {
        let fm = FileManager.default
        return specCandidates.first {
            fm.fileExists(atPath: (dir as NSString).appendingPathComponent($0))
        }
    }

    /// Returns the directory that may hold an XcodeGen spec for `path`. If `path`
    /// is a `.xcodeproj`/`.xcworkspace` bundle, the spec lives in the bundle's
    /// parent directory; otherwise `path` is itself the project directory.
    static func specDirectory(for path: String) -> String {
        if path.hasSuffix(".xcodeproj") || path.hasSuffix(".xcworkspace") {
            return (path as NSString).deletingLastPathComponent
        }
        return path
    }

    /// True when `dir` directly contains a buildable project: an XcodeGen spec, a
    /// `.xcworkspace`, or a `.xcodeproj`.
    static func isBuildableDirectory(_ dir: String) -> Bool {
        if specName(inDirectory: dir) != nil { return true }
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        return contents.contains { $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".xcworkspace") }
    }

    /// Directory names never treated as a nested project when auto-discovering.
    private static let ignoredChildren: Set<String> = [
        "Pods", "node_modules", "build", "DerivedData", ".build", ".worktrees", ".git",
    ]

    /// Resolves a user-supplied path to the directory that actually holds a
    /// buildable project. If the path (or its bundle's parent) is itself buildable
    /// it is returned; otherwise the immediate subdirectories are scanned and the
    /// single buildable one is returned (so pointing at a monorepo root like
    /// `rejog-lending` resolves to `rejog-lending-ios`). Returns the input
    /// directory unchanged when there is no match or the choice is ambiguous, so
    /// the caller's "no project found" error still surfaces. TKT-072.
    static func resolveProjectDirectory(_ path: String) -> String {
        let dir = specDirectory(for: path)
        if isBuildableDirectory(dir) { return dir }

        let fm = FileManager.default
        let children = ((try? fm.contentsOfDirectory(atPath: dir)) ?? [])
            .filter { !$0.hasPrefix(".") && !ignoredChildren.contains($0) }
            .map { (dir as NSString).appendingPathComponent($0) }
            .filter { child in
                var isDir: ObjCBool = false
                return fm.fileExists(atPath: child, isDirectory: &isDir) && isDir.boolValue
            }
        let buildable = children.filter(isBuildableDirectory)
        return buildable.count == 1 ? buildable[0] : dir
    }

    /// Resolves the `xcodegen` executable, preferring the standard Homebrew
    /// install locations (the server runs under launchd with a minimal PATH that
    /// usually omits `/opt/homebrew/bin`) and falling back to a PATH lookup.
    static func resolveBinary() -> String? {
        let fm = FileManager.default
        let candidates = ["/opt/homebrew/bin/xcodegen", "/usr/local/bin/xcodegen"]
        if let hit = candidates.first(where: { fm.isExecutableFile(atPath: $0) }) {
            return hit
        }
        return runCapturingTrimmed("/usr/bin/which", ["xcodegen"])
    }

    /// Runs `xcodegen generate` in `dir` when it contains an XcodeGen spec, so the
    /// `.xcodeproj` is rebuilt from its source of truth. A no-op for directories
    /// with no spec (hand-maintained projects are left untouched).
    ///
    /// - Parameter dir: The project directory to (re)generate in.
    /// - Parameter log: Optional sink for xcodegen's progress lines.
    /// - Throws: `XcodeGenError` if a spec is present but XcodeGen is missing or
    ///   `xcodegen generate` fails.
    static func regenerateIfNeeded(inDirectory dir: String, log: ((String) -> Void)? = nil) throws {
        guard let specName = specName(inDirectory: dir) else {
            return  // Not an XcodeGen project; nothing to regenerate.
        }
        guard let xcodegen = resolveBinary() else {
            throw XcodeGenError.notInstalled(specName: specName)
        }

        log?("Generating Xcode project from \(specName) (xcodegen)…")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: xcodegen)
        process.arguments = ["generate", "--spec", specName, "--quiet"]
        process.currentDirectoryURL = URL(fileURLWithPath: dir)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            throw XcodeGenError.generateFailed("could not launch xcodegen at \(xcodegen): \(error.localizedDescription)")
        }
        process.waitUntilExit()

        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let lines = output.components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        lines.forEach { log?($0) }

        guard process.terminationStatus == 0 else {
            throw XcodeGenError.generateFailed("exit \(process.terminationStatus): \(lines.last ?? "")")
        }
    }

    /// Runs a process and returns its trimmed stdout, or nil on any failure.
    private static func runCapturingTrimmed(_ launchPath: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
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
        guard process.terminationStatus == 0 else { return nil }
        let trimmed = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty == false) ? trimmed : nil
    }
}
