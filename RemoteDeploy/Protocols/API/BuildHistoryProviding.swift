// Protocol for retrieving recent build history via the API.
// The real persistent implementation lands in TKT-008; the current production
// adapter returns an empty array.
import Foundation
import RemoteDeployShared

protocol BuildHistoryProviding: Sendable {

    /// Returns recent build results, most recent first.
    ///
    /// - Returns: An array of `BuildResult` records.
    func recentBuilds() -> [BuildResult]
}
