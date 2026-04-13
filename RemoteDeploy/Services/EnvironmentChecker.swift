// Checks that required tools (node, npm, cocoapods, expo) are available
// on the host Mac. Used by the project setup UI to warn when Expo builds
// won't work due to missing dependencies. TKT-048.
import Foundation

/// Detects whether required CLI tools are installed and returns their versions.
enum EnvironmentChecker {

    /// Returns the installed Node.js version, or nil if node is not found.
    static func nodeVersion() -> String? {
        runVersionCheck("node", ["--version"])
    }

    /// Returns the installed npm version, or nil if npm is not found.
    static func npmVersion() -> String? {
        runVersionCheck("npm", ["--version"])
    }

    /// Returns the installed CocoaPods version, or nil if pod is not found.
    static func cocoapodsVersion() -> String? {
        runVersionCheck("pod", ["--version"])
    }

    /// Returns the Expo CLI version (via npx), or nil if not available.
    static func expoVersion() -> String? {
        runVersionCheck("npx", ["expo", "--version"])
    }

    /// Returns a list of human-readable warnings for any missing Expo dependencies.
    /// Empty array means all required tools are present.
    static func expoEnvironmentWarnings() -> [String] {
        var warnings: [String] = []

        if nodeVersion() == nil {
            warnings.append("Node.js is not installed. Install it from https://nodejs.org or via Homebrew: brew install node")
        }
        if npmVersion() == nil {
            warnings.append("npm is not installed. It ships with Node.js — install Node first.")
        }
        if cocoapodsVersion() == nil {
            warnings.append("CocoaPods is not installed. Install it via: gem install cocoapods (or brew install cocoapods)")
        }

        return warnings
    }

    // MARK: - Private

    /// Runs a tool with the given arguments and returns trimmed stdout, or nil on failure.
    private static func runVersionCheck(_ command: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [command] + arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()

            guard process.terminationStatus == 0 else { return nil }

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return output?.isEmpty == false ? output : nil
        } catch {
            return nil
        }
    }
}
