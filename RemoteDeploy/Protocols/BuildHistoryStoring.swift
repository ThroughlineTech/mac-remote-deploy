// Protocol for persisting a rolling window of recent build results.
// Records are bounded (most recent first) and survive app relaunches.
import Foundation
import RemoteDeployShared

protocol BuildHistoryStoring: Sendable {

    /// Appends a new build result. Older records are trimmed beyond the store's cap.
    func append(_ result: BuildResult)

    /// Returns all recorded builds, most recent first.
    func recentBuilds() -> [BuildResult]
}
