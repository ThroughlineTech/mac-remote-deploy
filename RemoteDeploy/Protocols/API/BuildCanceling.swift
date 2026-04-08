// Protocol for canceling an in-progress build via the API.
// The real implementation that actually terminates xcodebuild lands in TKT-016;
// the current production adapter is a no-op stub that always returns false.
import Foundation

protocol BuildCanceling: Sendable {

    /// Attempts to cancel the currently running build.
    ///
    /// - Returns: `true` if a build was in progress and was canceled, `false` otherwise.
    func cancelCurrentBuild() -> Bool
}
