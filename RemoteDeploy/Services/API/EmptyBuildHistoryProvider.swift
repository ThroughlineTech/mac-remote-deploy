// Stub implementation of BuildHistoryProviding that always returns an empty array.
// The real persistent implementation lands in TKT-008 (build history persistence).
import Foundation
import RemoteDeployShared

/// Empty build history provider used until TKT-008 lands a persistent store.
final class EmptyBuildHistoryProvider: BuildHistoryProviding, @unchecked Sendable {
    func recentBuilds() -> [BuildResult] {
        return []
    }
}
