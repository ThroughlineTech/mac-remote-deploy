// Validation helpers for the Setup Assistant's ProjectSetupStep.
// Extracted from ProjectSetupStep.swift so RemoteDeployTests can cover them
// without instantiating the SwiftUI view. TKT-014 / TKT-024.
//
// The `validateBundleID` regex is currently duplicated here; Commit 5 of
// TKT-024 (TKT-009 cleanup) will reroute it to a shared `BundleIDValidator`
// in RemoteDeployShared.
import Foundation

/// Input validators for the Setup Assistant's project step. Each function
/// returns `nil` for "valid or still-empty" and a user-facing error message
/// for "entered but malformed".
enum ProjectSetupValidators {

    /// Validates a bundle ID against the reverse-DNS pattern (e.g. com.example.app).
    /// Returns nil if valid or empty, an error message otherwise.
    static func validateBundleID(_ value: String) -> String? {
        if value.isEmpty { return nil }
        let pattern = #"^[A-Za-z][A-Za-z0-9-]*(\.[A-Za-z][A-Za-z0-9-]*)+$"#
        if value.range(of: pattern, options: .regularExpression) == nil {
            return "Must be reverse-DNS format (e.g. com.example.app)"
        }
        return nil
    }

    /// Validates an Apple Developer Team ID — exactly 10 uppercase alphanumeric characters.
    static func validateTeamID(_ value: String) -> String? {
        if value.isEmpty { return nil }
        if value.count != 10 {
            return "Team ID must be exactly 10 characters"
        }
        if value.range(of: #"^[A-Z0-9]+$"#, options: .regularExpression) == nil {
            return "Team ID must be uppercase alphanumeric"
        }
        return nil
    }

    /// Validates that the project path exists on disk.
    static func validatePath(_ value: String) -> String? {
        if value.isEmpty { return nil }
        if !FileManager.default.fileExists(atPath: value) {
            return "Path does not exist"
        }
        return nil
    }

    /// Validates that an Xcode scheme has been selected.
    /// Unlike the other validators, empty is an error here: scheme is
    /// required to build the project. TKT-014.
    static func validateScheme(_ value: String) -> String? {
        if value.isEmpty {
            return "Select a scheme to continue"
        }
        return nil
    }
}
