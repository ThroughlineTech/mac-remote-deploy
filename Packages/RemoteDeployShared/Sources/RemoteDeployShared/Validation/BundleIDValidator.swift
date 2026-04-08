// Shared bundle-ID validation used by both the SwiftUI Setup Assistant
// (macOS host) and the REST `ProjectsRouteHandler` boundary. TKT-009 / TKT-024.
//
// Before this extraction, the reverse-DNS regex only lived in the SwiftUI
// project-setup step, so a programmatic `POST /api/v1/projects` or
// `PUT /api/v1/projects/:id` call could persist a malformed bundle ID
// without rejection. This validator is the single source of truth;
// `ProjectSetupValidators.validateBundleID` and `ProjectsRouteHandler`
// both delegate to it.
import Foundation

/// Validates iOS bundle identifiers against the reverse-DNS format
/// (e.g. `com.example.app`). The empty string is treated as "not entered
/// yet" and returns `nil` so UI flows can allow incomplete input before
/// the user finishes typing. Programmatic callers that require a
/// non-empty value should check that separately.
public enum BundleIDValidator {

    /// Regex matching the reverse-DNS bundle ID format:
    /// - Segments separated by dots
    /// - At least two segments total
    /// - Each segment starts with a letter
    /// - Segments contain letters, digits, and hyphens
    ///
    /// Kept as a private static to avoid re-compiling the pattern on each call.
    private static let pattern = #"^[A-Za-z][A-Za-z0-9-]*(\.[A-Za-z][A-Za-z0-9-]*)+$"#

    /// Validates a bundle ID.
    /// - Parameter value: The candidate bundle identifier.
    /// - Returns: `nil` if valid or empty; a user-facing error string otherwise.
    public static func validate(_ value: String) -> String? {
        if value.isEmpty { return nil }
        if value.range(of: pattern, options: .regularExpression) == nil {
            return "Must be reverse-DNS format (e.g. com.example.app)"
        }
        return nil
    }
}
