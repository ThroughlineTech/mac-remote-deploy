// WebSocket client for receiving live build log and status updates from the Mac.
// Uses URLSessionWebSocketTask for native iOS WebSocket support.
import Foundation
import RemoteDeployShared

/// Receives live updates from the Mac server via WebSocket.
@MainActor
final class WebSocketClient: ObservableObject {

    /// The latest build log lines received.
    @Published var buildLogLines: [String] = []

    /// The latest build status update.
    @Published var latestStatus: BuildStatusInfo?

    /// Whether the WebSocket is connected.
    @Published var isConnected = false

    private var task: URLSessionWebSocketTask?
    private var session: URLSession?

    /// Connects to the server's WebSocket endpoint.
    ///
    /// - Parameter baseURL: The server's base URL.
    /// - Parameter token: The bearer token for authentication.
    func connect(baseURL: URL, token: String) {
        disconnect()

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

        buildLogLines = []

        // Subscribe to channels and start receiving.
        // If the handshake fails, we silently set isConnected = false.
        subscribe(to: "buildlog")
        subscribe(to: "buildstatus")
        receiveMessages()
    }

    /// Disconnects from the WebSocket.
    func disconnect() {
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
        isConnected = false
    }

    /// Clears the build log.
    func clearLog() {
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
                    self?.handleMessage(text)
                    self?.receiveMessages()
                case .success(.data(let data)):
                    self?.isConnected = true
                    if let text = String(data: data, encoding: .utf8) {
                        self?.handleMessage(text)
                    }
                    self?.receiveMessages()
                case .failure:
                    // Silently mark as disconnected — WS is optional
                    self?.isConnected = false
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
                latestStatus = status
            }
        default:
            break
        }
    }
}
