// WebSocket client for receiving live build log and status updates from the Mac.
// Uses URLSessionWebSocketTask for native WebSocket support.
//
// TKT-011 / TKT-024 Commit 6: reconnect-with-backoff. When the connection
// drops (e.g. server restart, Tailscale hiccup, transient network blip), the
// client retries with exponential backoff capped at 16 seconds while the
// caller still considers the client "active". Reconnect stops when
// `disconnect()` is called explicitly.
//
// TKT-056 (Phase 3): moved from RemoteDeployCompanion into the shared package so
// the macOS menu bar and the iOS companion share one WebSocket implementation.
import Foundation
import Combine

/// Receives live updates from the Mac server via WebSocket.
@MainActor
public final class WebSocketClient: ObservableObject {

    /// The latest build log lines received.
    @Published public var buildLogLines: [String] = []

    /// The latest build status update.
    @Published public var latestStatus: BuildStatusInfo?

    /// Whether the WebSocket is connected.
    @Published public var isConnected = false

    private var task: URLSessionWebSocketTask?
    private var session: URLSession?

    // MARK: - Reconnect state (TKT-011 / TKT-024 Commit 6)

    /// True between `connect(...)` and `disconnect()`. Reconnect attempts
    /// only run while this is true, so an explicit disconnect halts the
    /// backoff loop even if a retry Task is already scheduled.
    private var isActive = false

    /// The last base URL passed to `connect(...)`. Retained so the
    /// reconnect loop can rebuild the request.
    private var savedBaseURL: URL?

    /// The last bearer token passed to `connect(...)`. Retained so the
    /// reconnect loop can rebuild the request.
    private var savedToken: String?

    /// Current backoff delay in seconds. Starts at 1, doubles after each
    /// failure, caps at `maxReconnectDelay`. Reset to 1 on successful
    /// connection.
    private var reconnectDelay: TimeInterval = 1.0

    /// Maximum backoff delay (16s per TKT-024 plan).
    private static let maxReconnectDelay: TimeInterval = 16.0

    public init() {}

    /// Connects to the server's WebSocket endpoint.
    ///
    /// - Parameter baseURL: The server's base URL.
    /// - Parameter token: The bearer token for authentication.
    public func connect(baseURL: URL, token: String) {
        isActive = true
        savedBaseURL = baseURL
        savedToken = token
        reconnectDelay = 1.0
        openSocket()
    }

    /// Opens (or re-opens) the WebSocket task using the saved baseURL/token.
    /// Internal to `connect(...)` + the reconnect loop -- external callers
    /// always go through `connect(...)` so `isActive` is correctly set.
    private func openSocket() {
        guard let baseURL = savedBaseURL, let token = savedToken else { return }

        // Tear down any prior task/session without clearing isActive --
        // we're mid-reconnect, not shutting down.
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil

        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.scheme = baseURL.scheme == "https" ? "wss" : "ws"
        components.path = "/api/v1/ws"

        guard let wsURL = components.url else { return }

        var request = URLRequest(url: wsURL)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let config = URLSessionConfiguration.default
        session = URLSession(configuration: config, delegate: CertValidatingSessionDelegate(), delegateQueue: nil)
        task = session?.webSocketTask(with: request)
        task?.resume()

        // NOTE: do NOT clear buildLogLines here. openSocket() also runs on every
        // reconnect (the backoff loop), so clearing here wiped the log on any
        // transient drop. The log is instead reset when a new build starts (see
        // the "buildstatus" -> "building" transition in handleMessage).

        // Subscribe to channels and start receiving.
        // If the handshake fails, receiveMessages() will schedule a reconnect.
        subscribe(to: "buildlog")
        subscribe(to: "buildstatus")
        receiveMessages()
    }

    /// Schedules a reconnect attempt after the current backoff delay, then
    /// doubles the delay for the next failure (capped at `maxReconnectDelay`).
    /// No-op if `isActive` is false (disconnect was called).
    private func scheduleReconnect() {
        guard isActive else { return }
        let delay = reconnectDelay
        reconnectDelay = min(delay * 2, Self.maxReconnectDelay)
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, self.isActive else { return }
            self.openSocket()
        }
    }

    /// Disconnects from the WebSocket and stops any pending reconnect attempts.
    public func disconnect() {
        isActive = false
        savedBaseURL = nil
        savedToken = nil
        reconnectDelay = 1.0
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
        isConnected = false
    }

    /// Clears the build log.
    public func clearLog() {
        buildLogLines = []
    }

    // MARK: - Private

    private func subscribe(to channel: String) {
        let msg = WSMessage(type: "subscribe", payload: channel)
        guard let data = try? JSONEncoder().encode(msg),
              let text = String(data: data, encoding: .utf8) else { return }
        task?.send(.string(text)) { _ in }
    }

    private func receiveMessages() {
        task?.receive { [weak self] result in
            Task { @MainActor [weak self] in
                switch result {
                case .success(.string(let text)):
                    self?.isConnected = true
                    // Successful frame = known-good connection. Reset backoff
                    // so the next failure restarts from 1s. TKT-011 / TKT-024.
                    self?.reconnectDelay = 1.0
                    self?.handleMessage(text)
                    self?.receiveMessages()
                case .success(.data(let data)):
                    self?.isConnected = true
                    self?.reconnectDelay = 1.0
                    if let text = String(data: data, encoding: .utf8) {
                        self?.handleMessage(text)
                    }
                    self?.receiveMessages()
                case .failure:
                    // Handshake or mid-stream failure. Mark disconnected and
                    // -- if we're still supposed to be connected -- schedule
                    // a reconnect with the current backoff delay.
                    // TKT-011 / TKT-024 Commit 6.
                    self?.isConnected = false
                    self?.scheduleReconnect()
                @unknown default:
                    break
                }
            }
        }
    }

    private func handleMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let msg = try? JSONDecoder().decode(WSMessage.self, from: data) else { return }

        switch msg.type {
        case "buildlog":
            buildLogLines.append(msg.payload)
        case "buildstatus":
            if let statusData = msg.payload.data(using: .utf8),
               let status = try? JSONDecoder().decode(BuildStatusInfo.self, from: statusData) {
                // A fresh build starting clears the prior build's lines so the
                // live stream shows only the current build. Gated on the
                // transition (not every "building" frame) so reconnects mid-
                // build -- which re-broadcast "building" -- preserve the log.
                if status.state == "building", latestStatus?.state != "building" {
                    buildLogLines = []
                }
                latestStatus = status
            }
        default:
            break
        }
    }
}
