import Foundation

/// Reconciles the two build-status signals a client sees -- the periodic REST
/// poll and the live WebSocket `buildstatus` frame -- into a single "is a build
/// in progress?" answer.
///
/// Both signals ultimately come from the same in-process build status on the
/// server, but they have different failure modes:
///
/// - The **poll** (`GET /build/status`) reads the build status directly and is
///   authoritative for whether a build actually finished, but lags by up to the
///   poll interval.
/// - The **WebSocket frame** is low latency, but can get *stuck*: status
///   broadcasts are fire-and-forget, so a client that is briefly disconnected
///   when the terminal `success`/`failure` frame is sent never learns the build
///   ended and stays pinned to `"building"`.
///
/// Preferring the WebSocket frame outright (`live ?? polled`) let a stale frame
/// mask the correct polled state forever -- the spinning, un-cancellable
/// "Cancel Build" button. The rule here fixes that: a TERMINAL poll always wins,
/// so a stale `"building"` frame can never outlive the build (the UI self-heals
/// within one poll); otherwise the WebSocket leads, flipping to `"building"` the
/// instant a build starts, and falling back to the poll when no frame has
/// arrived yet.
///
/// (The server-side companion fix -- replaying the current status on subscribe
/// -- keeps the WebSocket frame from going stale in the first place; this rule
/// is the client-side safety net that guarantees the UI can never get *stuck*
/// even if a frame is still somehow missed.)
public enum BuildStateReconciler {

    /// - Parameters:
    ///   - polled: `BuildStatusInfo.state` from the REST poll, or nil if no poll
    ///     has completed yet.
    ///   - live: `BuildStatusInfo.state` from the most recent WebSocket frame, or
    ///     nil if none has arrived.
    /// - Returns: whether a build should be considered in progress.
    public static func isBuilding(polled: String?, live: String?) -> Bool {
        if polled == "success" || polled == "failure" { return false }
        return (live ?? polled) == "building"
    }
}
