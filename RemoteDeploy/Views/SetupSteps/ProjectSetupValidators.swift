// Validation helpers for the Setup Assistant's ProjectSetupStep.
// Extracted from ProjectSetupStep.swift so RemoteDeployTests can cover them
// without instantiating the SwiftUI view. TKT-014 / TKT-024.
//
// `validateBundleID` delegates to the shared `BundleIDValidator` in
// `RemoteDeployShared` so the UI and the REST `ProjectsRouteHandler`
// boundary use the same regex. TKT-009 / TKT-024 Commit 5.
import Foundation
import RemoteDeployShared

/// Input validators for the Setup Assistant's project step. Each function
/// returns `nil` for "valid or still-empty" and a user-facing error message
/// for "entered but malformed".
enum ProjectSetupValidators {

    /// Validates a bundle ID against the reverse-DNS pattern (e.g. com.example.app).
    /// Delegates to the shared `BundleIDValidator`.
    static func validateBundleID(_ value: String) -> String? {
        BundleIDValidator.validate(value)
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

    // MARK: - Expo Validation (TKT-048)

    /// Validates that an Expo project's root directory contains `package.json`.
    /// Returns nil if the path is empty (not yet selected) or valid.
    static func validateExpoProjectPath(_ projectPath: String) -> String? {
        guard !projectPath.isEmpty else { return nil }
        let packageJsonPath = (projectPath as NSString).appendingPathComponent("package.json")
        if !FileManager.default.fileExists(atPath: packageJsonPath) {
            return "Expo projects must contain a package.json at the project root"
        }
        return nil
    }

    /// Validates that an Expo app directory (if set) contains `app.json` or `app.config.js`.
    /// - Parameters:
    ///   - projectPath: The project root directory.
    ///   - expoAppDirectory: Relative path to the Expo app directory (e.g. "app"). Empty or nil means root.
    /// - Returns: An error string, or nil if valid.
    static func validateExpoAppDirectory(_ projectPath: String, expoAppDirectory: String?) -> String? {
        guard !projectPath.isEmpty else { return nil }
        guard let appDir = expoAppDirectory, !appDir.isEmpty else { return nil }

        let fullPath = (projectPath as NSString).appendingPathComponent(appDir)
        let fm = FileManager.default

        let appJson = (fullPath as NSString).appendingPathComponent("app.json")
        let appConfigJs = (fullPath as NSString).appendingPathComponent("app.config.js")

        if !fm.fileExists(atPath: appJson) && !fm.fileExists(atPath: appConfigJs) {
            return "App directory must contain app.json or app.config.js"
        }
        return nil
    }
}
