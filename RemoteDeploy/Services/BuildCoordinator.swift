// View-independent owner of the build lifecycle (TKT-054, Phase 1 of the
// backend-decoupling plan). Before this, a remote build round-tripped through
// MenuBarView.handleAPIBuildRequest via an .apiBuildRequested NotificationCenter
// post, so remote builds only worked once the popover had been opened, and
// cancel was a hard-coded no-op.
//
// The coordinator is the single entry point the API, the menu bar button, and
// any future client call to trigger or cancel a build. It resolves the project
// from the store by ID and sources server/TLS config itself (via
// BuildConfigProviding) instead of receiving it from a view. Orchestration still
// lives in BuildManager: it remains the @MainActor ObservableObject the build-log
// window and menu bar observe, and the coordinator delegates execution to it.
import Foundation
import RemoteDeployShared

@MainActor
final class BuildCoordinator {

    /// The orchestration executor + view-observable build state. The coordinator
    /// delegates execution here so the build-log window and menu bar keep
    /// observing the same @Published state.
    private let buildManager: BuildManager

    /// Persistent store the build project is resolved from by ID.
    private let projectStore: any ProjectStoring

    /// Live server/TLS config source (AppState today). Read on the main actor at
    /// trigger time.
    private let config: any BuildConfigProviding

    /// The build engine, used to cancel an in-progress build. `nonisolated` +
    /// Sendable so the API's BuildCanceling adapter can reach it off the main
    /// actor; the router's `status`/`cancelBuild()` are lock-protected.
    nonisolated let buildEngine: any BuildEngineProtocol

    init(
        buildManager: BuildManager,
        projectStore: any ProjectStoring,
        config: any BuildConfigProviding,
        buildEngine: any BuildEngineProtocol
    ) {
        self.buildManager = buildManager
        self.projectStore = projectStore
        self.config = config
        self.buildEngine = buildEngine
    }

    // MARK: - Trigger

    /// Triggers a build for the project with the given ID. View-independent:
    /// resolves the project from the store and sources server/TLS config itself.
    ///
    /// - Parameters:
    ///   - projectID: The project to build.
    ///   - configuration: Optional build-configuration override (e.g. "Debug").
    /// - Returns: `nil` on a successful trigger, or a human-readable error message
    ///   (e.g. "Project not found").
    @discardableResult
    func triggerBuild(projectID: UUID, configuration: String?) -> String? {
        guard var project = projectStore.project(withID: projectID) else {
            return "Project not found"
        }
        if let configuration, !configuration.isEmpty {
            project.buildConfiguration = configuration
        }

        buildManager.triggerBuild(
            project: project,
            serverURL: config.serverURL,
            serverPort: config.serverPort,
            certPath: config.certPath,
            keyPath: config.keyPath,
            serverRunning: config.serverRunning,
            onServerStarted: { [config] in config.serverRunning = true }
        )
        return nil
    }

    // MARK: - Cancel

    /// Cancels the in-progress build, if any. Safe to call off the main actor: it
    /// reads the engine's lock-protected status for the result and dispatches the
    /// async termination, which makes the in-flight `build(project:)` throw and
    /// drives BuildManager's status back to a terminal state.
    ///
    /// - Returns: `true` if a build was running when cancel was requested.
    @discardableResult
    nonisolated func cancelBuild() -> Bool {
        let wasBuilding: Bool
        if case .building = buildEngine.status {
            wasBuilding = true
        } else {
            wasBuilding = false
        }
        Task { await buildEngine.cancelBuild() }
        return wasBuilding
    }
}
