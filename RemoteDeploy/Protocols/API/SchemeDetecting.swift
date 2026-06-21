// Protocol for detecting Xcode build schemes at a given project or workspace path.
// Used by FilesystemRouteHandler to expose scheme discovery to companion devices
// without coupling the handler to xcodebuild process invocation.
import Foundation

protocol SchemeDetecting: Sendable {

    /// Detects available Xcode schemes at the given project or workspace path.
    ///
    /// - Parameter atPath: The absolute filesystem path to a `.xcodeproj` or `.xcworkspace`.
    /// - Returns: An array of scheme names found at the path. Empty only when detection
    ///   succeeds but the project defines no schemes.
    /// - Throws: An error describing why detection could not run (e.g. no Xcode available)
    ///   so callers can surface an actionable message rather than an empty result.
    func detectSchemes(atPath path: String) throws -> [String]
}
