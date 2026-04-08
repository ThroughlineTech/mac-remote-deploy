// Real implementation of SchemeDetecting that shells out to /usr/bin/xcodebuild -list
// and parses the "Schemes:" section of its output.
import Foundation

/// Detects Xcode schemes by invoking `xcodebuild -list` and parsing its output.
final class XcodebuildSchemeDetector: SchemeDetecting, @unchecked Sendable {

    /// Detects schemes at the given project path by running `xcodebuild -list -project <path>`.
    ///
    /// - Parameter atPath: Absolute path to a `.xcodeproj` directory.
    /// - Returns: Parsed scheme names, or an empty array if the process fails or no schemes are found.
    func detectSchemes(atPath path: String) -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcodebuild")
        process.arguments = ["-list", "-project", path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try? process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""

        // Parse schemes from xcodebuild -list output
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
}
