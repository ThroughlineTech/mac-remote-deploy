// Stub implementation of BuildCanceling that always returns false.
// The real implementation that actually terminates the running xcodebuild
// process lands in TKT-016 (build cancellation race-condition safeguards).
import Foundation

/// No-op build canceler. Always reports that no build was canceled.
final class NoopBuildCanceler: BuildCanceling, @unchecked Sendable {
    func cancelCurrentBuild() -> Bool {
        return false
    }
}
