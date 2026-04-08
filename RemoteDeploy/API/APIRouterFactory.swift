// Builds a fully wired APIRouter from a bag of protocol-typed dependencies.
// Extracted from RemoteDeployApp.configureAPIRouter() so individual handlers
// can be tested with mocks instead of needing the entire app environment.
import Foundation

/// Factory that constructs an `APIRouter` from injectable dependencies.
///
/// In production, `RemoteDeployApp.configureAPIRouter(...)` builds real adapters
/// (XcodebuildSchemeDetector, NotificationBuildTrigger, etc.) and calls `make(deps:)`.
/// Tests build the same `Dependencies` struct with mocks and dispatch requests through
/// the resulting router to assert end-to-end behavior of each route handler.
@MainActor
struct APIRouterFactory {

    /// Bundle of every dependency required to construct the router.
    struct Dependencies {
        let deviceStore: any PairedDeviceStoring
        let projectStore: any ProjectStoring
        let installTracker: any InstallTracking
        let schemeDetector: any SchemeDetecting
        let statusProvider: any StatusProviding
        let buildTrigger: any BuildTriggering
        let buildStatus: any BuildStatusProviding
        let buildCanceler: any BuildCanceling
        let buildHistory: any BuildHistoryProviding
        let settingsProvider: any SettingsProviding
        let settingsUpdater: any SettingsUpdating
        let serverName: String
    }

    /// The constructed router along with the pairing handler reference, which the
    /// caller stores on `ServiceContainer.pairingHandler` so the macOS PairDeviceView
    /// can register pending tokens before they're claimed.
    struct Output {
        let router: APIRouter
        let pairingHandler: PairingRouteHandler
        /// The bearer-token authenticator the router uses for REST routes.
        /// Exposed so the WebSocket upgrade path in `NIODeployServer` can
        /// reuse the same token validation logic. TKT-011 / TKT-024 Commit 6.
        let auth: AuthMiddleware
    }

    /// Builds an `APIRouter` from the given dependencies.
    ///
    /// - Parameter deps: The dependency bag.
    /// - Returns: The constructed router and the pairing handler instance it owns.
    static func make(deps: Dependencies) -> Output {
        let auth = AuthMiddleware(deviceStore: deps.deviceStore)

        let pairingHandler = PairingRouteHandler(
            deviceStore: deps.deviceStore,
            serverName: deps.serverName
        )
        let statusHandler = StatusRouteHandler(statusProvider: deps.statusProvider)
        let projectsHandler = ProjectsRouteHandler(projectStore: deps.projectStore)
        let buildHandler = BuildRouteHandler(
            buildTrigger: deps.buildTrigger,
            buildStatus: deps.buildStatus,
            buildCanceler: deps.buildCanceler,
            buildHistory: deps.buildHistory
        )
        let installsHandler = InstallsRouteHandler(installTracker: deps.installTracker)
        let settingsHandler = SettingsRouteHandler(
            settingsProvider: deps.settingsProvider,
            settingsUpdater: deps.settingsUpdater
        )
        let filesystemHandler = FilesystemRouteHandler(schemeDetector: deps.schemeDetector)
        let devicesHandler = DevicesRouteHandler(deviceStore: deps.deviceStore)

        let router = APIRouter(
            auth: auth,
            pairingHandler: pairingHandler,
            statusHandler: statusHandler,
            projectsHandler: projectsHandler,
            buildHandler: buildHandler,
            installsHandler: installsHandler,
            settingsHandler: settingsHandler,
            filesystemHandler: filesystemHandler,
            devicesHandler: devicesHandler
        )

        return Output(router: router, pairingHandler: pairingHandler, auth: auth)
    }
}
