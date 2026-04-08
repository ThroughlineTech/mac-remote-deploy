// Adapter that exposes a BuildHistoryStoring instance as the BuildHistoryProviding
// protocol consumed by BuildRouteHandler. After TKT-008, this is backed by the
// real JSONBuildHistoryStore; the original stub-returning-[] implementation has
// been replaced. The filename is retained to avoid churning the pbxproj.
import Foundation
import RemoteDeployShared

/// Adapts a BuildHistoryStoring to BuildHistoryProviding so the API layer can
/// read persisted build records without knowing about the storage protocol.
final class EmptyBuildHistoryProvider: BuildHistoryProviding, @unchecked Sendable {
    private let store: any BuildHistoryStoring

    /// Creates a new provider backed by the given store.
    init(store: any BuildHistoryStoring) {
        self.store = store
    }

    /// Creates a no-op provider that returns an empty array. Used as a fallback
    /// when no store is wired up (e.g. in tests that don't need build history).
    static func empty() -> EmptyBuildHistoryProvider {
        EmptyBuildHistoryProvider(store: EmptyStore())
    }

    func recentBuilds() -> [BuildResult] {
        store.recentBuilds()
    }

    private final class EmptyStore: BuildHistoryStoring, @unchecked Sendable {
        func append(_ result: BuildResult) {}
        func recentBuilds() -> [BuildResult] { [] }
    }
}
