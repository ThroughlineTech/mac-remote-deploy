// NIODeployServer conformance to BuildEventBroadcasting. Maps each
// high-level event type to a WebSocketManager.broadcast call with the
// appropriate JSON payload. TKT-027.
import Foundation
import RemoteDeployShared

extension NIODeployServer: BuildEventBroadcasting {

    /// Broadcasts a single build log line on the `"buildlog"` channel.
    /// Payload is the raw line text — no JSON wrapping. Subscribers (the
    /// iOS companion's WebSocketClient, currently) append each payload
    /// to their local buildLogLines array.
    func broadcastBuildLog(_ line: String) {
        webSocketManager.broadcast(type: "buildlog", payload: line)
    }

    /// Broadcasts a build status transition on the `"buildstatus"` channel.
    /// Payload is a JSON-encoded `BuildStatusInfo` — same shape the REST
    /// `GET /api/v1/build/status` endpoint returns, so companion code can
    /// reuse the same decoder for both paths.
    func broadcastBuildStatus(_ status: BuildStatus) {
        let info = Self.buildStatusInfo(from: status)
        guard let data = try? JSONEncoder().encode(info),
              let json = String(data: data, encoding: .utf8) else {
            return
        }
        webSocketManager.broadcast(type: "buildstatus", payload: json)
    }

    /// Broadcasts an IPA download event on the `"install"` channel.
    /// Payload is a small JSON dict `{"slug": ..., "sourceIP": ...}`.
    func broadcastInstall(slug: String, sourceIP: String) {
        let payload: [String: String] = ["slug": slug, "sourceIP": sourceIP]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else {
            return
        }
        webSocketManager.broadcast(type: "install", payload: json)
    }

    // MARK: - Helpers

    /// Converts an internal `BuildStatus` enum to the wire-format
    /// `BuildStatusInfo` struct. Mirrors the mapping in
    /// `BuildManagerBuildStatusProvider` so both the REST and WS paths
    /// agree on payload shape.
    static func buildStatusInfo(from status: BuildStatus) -> BuildStatusInfo {
        switch status {
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
