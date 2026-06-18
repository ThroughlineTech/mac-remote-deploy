// Protocol for providing the current BuildStatusInfo to API consumers.
// Decouples BuildRouteHandler from the concrete status source (BuildManagerBuildStatusProvider).
import Foundation
import RemoteDeployShared

protocol BuildStatusProviding: Sendable {

    /// Returns the current build status snapshot.
    ///
    /// - Returns: A `BuildStatusInfo` reflecting whether a build is idle, in progress,
    ///   succeeded, or failed.
    func currentBuildStatus() -> BuildStatusInfo
}
