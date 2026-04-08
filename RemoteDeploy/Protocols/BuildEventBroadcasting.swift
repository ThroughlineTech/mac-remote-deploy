// Protocol for fanning out build-related events (log lines, status transitions,
// install downloads) over a transport. The production implementation is
// `NIODeployServer`, which broadcasts via its `webSocketManager` to subscribed
// WebSocket clients. Tests pass `MockBuildEventBroadcaster` which records calls.
// TKT-027.
import Foundation
import RemoteDeployShared

/// Fans out host-side build and install events to connected WebSocket clients.
/// Called from `BuildManager` (for build log and status changes) and from
/// `AppDelegate.configureAPIRouter`'s `onIPADownload` closure (for installs).
///
/// `Sendable` so `BuildManager` can hold a reference across the @MainActor
/// boundary. Implementations are fire-and-forget — none of these methods
/// throw or block the caller.
protocol BuildEventBroadcasting: Sendable {
    /// Publishes a single build log line (one call per xcodebuild output line).
    /// Channel: `"buildlog"`. Payload: the raw line text.
    func broadcastBuildLog(_ line: String)

    /// Publishes a build status transition (.idle → .building → .success/.failure).
    /// Channel: `"buildstatus"`. Payload: JSON-encoded `BuildStatusInfo`.
    func broadcastBuildStatus(_ status: BuildStatus)

    /// Publishes an IPA download event.
    /// Channel: `"install"`. Payload: JSON-encoded dict with `slug` and `sourceIP` keys.
    func broadcastInstall(slug: String, sourceIP: String)
}
