import Foundation

/// Identifies the type of project for build engine dispatch.
/// `.xcode` uses the standard xcodebuild pipeline; `.expo` prepends
/// npm install, expo prebuild, and pod install before archiving.
public enum ProjectType: String, Codable, Sendable, CaseIterable {
    /// Native Xcode project or workspace — built directly with xcodebuild.
    case xcode
    /// React Native / Expo project — prebuild + pod install + xcodebuild.
    case expo
}
