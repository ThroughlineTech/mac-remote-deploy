// Provides the current build status to API consumers by reading BuildManager's
// status off the server's event loop. Replaces AppStateBridgeBuildStatusProvider
// in production so the build-status path no longer depends on AppStateBridge
// (TKT-054, Phase 1; clears one consumer ahead of AppStateBridge's removal in
// Phase 2).
import Foundation
import RemoteDeployShared

/// Reads the live build status the BuildCoordinator drives (BuildManager owns the
/// persistent success/failure status after a build ends). Captures the read
/// closure on the main actor in init; BuildStatus is a Sendable value type, so
/// the deferred read is a single value load -- the same pattern AppStateBridge
/// uses for off-event-loop reads.
final class BuildManagerBuildStatusProvider: BuildStatusProviding, @unchecked Sendable {

    private let statusSnapshot: () -> BuildStatus

    @MainActor
    init(buildManager: BuildManager) {
        nonisolated(unsafe) let manager = buildManager
        self.statusSnapshot = { manager.buildStatus }
    }

    func currentBuildStatus() -> BuildStatusInfo {
        switch statusSnapshot() {
        case .idle:
            return BuildStatusInfo(state: "idle")
        case .building(let progress):
            return BuildStatusInfo(state: "building", message: progress)
        case .success(let ipaPath):
            return BuildStatusInfo(state: "success", message: ipaPath)
        case .failure(let error):
            return BuildStatusInfo(state: "failure", message: error)
        }
    }
}
