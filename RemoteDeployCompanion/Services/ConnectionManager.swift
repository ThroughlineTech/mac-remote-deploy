// Central manager for the connection to a RemoteDeploy Mac server.
// Handles pairing, connection state, and provides the APIClient to views.
import Foundation
import SwiftUI
import os
import RemoteDeployShared

// Use the shared Logger.pairing extension defined in RemoteDeployCompanion/Logging.swift.
private let logger = Logger.pairing

/// Manages the connection to a paired RemoteDeploy Mac server.
@MainActor
final class ConnectionManager: ObservableObject {

    /// Whether we have a valid connection to a server.
    @Published var isConnected = false

    /// The name of the connected server.
    @Published var serverName = ""

    /// The current server status.
    @Published var serverStatus: ServerStatus?

    /// Error message for display.
    @Published var error: String?

    /// The API client for making requests to the server.
    private(set) var apiClient: APIClient?

    /// The WebSocket client for live updates.
    let webSocketClient = WebSocketClient()

    /// The Bonjour browser for local network discovery.
    let bonjourBrowser = BonjourBrowser()

    /// Shared build state manager — observed by both Build tab and ProjectDetailView.
    let buildManager = BuildManager()

    init() {
        // Support auto-pairing via environment variables or UserDefaults for testing/screenshots.
        // XCUITest uses launchEnvironment, simctl uses UserDefaults.
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments

        // --reset-pairing: clear saved credentials for fresh discovery screenshots
        if args.contains("--reset-pairing") {
            KeychainStore.clear()
            logger.info("Pairing reset via launch argument")
        }

        // --auto-pair: connect directly from launch arguments, bypassing Keychain
        // (Keychain returns -34018 in XCUITest without code signing)
        if args.contains("--auto-pair"),
           let urlIndex = args.firstIndex(of: "--pair-url"), urlIndex + 1 < args.count,
           let tokenIndex = args.firstIndex(of: "--pair-token"), tokenIndex + 1 < args.count {
            let url = args[urlIndex + 1]
            let token = args[tokenIndex + 1]
            let name: String
            if let nameIndex = args.firstIndex(of: "--pair-name"), nameIndex + 1 < args.count {
                name = args[nameIndex + 1]
            } else {
                name = "Mac"
            }
            logger.info("Auto-pairing via launch args: \(url, privacy: .public)")
            if let baseURL = URL(string: url) {
                apiClient = APIClient(baseURL: baseURL, token: token)
                buildManager.setClient(apiClient)
                serverName = name
                isConnected = true
                Task { await refreshStatus() }
                return
            }
        }
        #endif

        // Try to restore a saved connection
        restoreConnection()
    }

    /// Attempts to connect using saved Keychain credentials.
    func restoreConnection() {
        guard let saved = KeychainStore.load(),
              let url = URL(string: saved.url) else {
            return
        }

        apiClient = APIClient(baseURL: url, token: saved.token)
        buildManager.setClient(apiClient)
        serverName = saved.serverName
        isConnected = true

        // Verify the connection works
        Task {
            await refreshStatus()
        }
    }

    /// Pairs with a server using QR code data.
    ///
    /// - Parameter url: The server's base URL.
    /// - Parameter token: The bearer token from the QR code.
    /// - Parameter serverName: The Mac's display name.
    func pair(url: String, token: String, serverName: String) async throws {
        logger.info("Pairing: attempting with url=\(url, privacy: .public) token=\(token.prefix(4), privacy: .public)...")
        guard let baseURL = URL(string: url) else {
            logger.error("Pairing: invalid URL '\(url, privacy: .public)'")
            throw ConnectionError.invalidURL
        }

        let client = APIClient(baseURL: baseURL, token: token)

        // Complete the pairing handshake
        let deviceName = UIDevice.current.name
        logger.info("Pairing: sending pair request as '\(deviceName, privacy: .public)'")
        let response = try await client.completePairing(deviceName: deviceName)

        guard response.paired else {
            logger.error("Pairing: server rejected pairing")
            throw ConnectionError.pairingFailed
        }

        logger.info("Pairing: success! Server name: \(response.serverName, privacy: .public)")
        // Save credentials and connect
        KeychainStore.save(url: url, token: token, serverName: response.serverName)

        self.apiClient = client
        self.buildManager.setClient(client)
        self.serverName = response.serverName
        self.isConnected = true

        // Connect WebSocket (best-effort, don't block pairing if it fails)
        webSocketClient.connect(baseURL: baseURL, token: token)

        // Verify the connection works by fetching status
        await refreshStatus()
    }

    /// Manually connects to a server URL with a token.
    func connect(url: String, token: String) async throws {
        guard let baseURL = URL(string: url) else {
            throw ConnectionError.invalidURL
        }

        let client = APIClient(baseURL: baseURL, token: token)

        // Test the connection
        let status = try await client.getStatus()

        KeychainStore.save(url: url, token: token, serverName: "RemoteDeploy Server")

        self.apiClient = client
        self.buildManager.setClient(client)
        self.serverStatus = status
        self.isConnected = true

        webSocketClient.connect(baseURL: baseURL, token: token)
    }

    /// Disconnects and clears saved credentials.
    func disconnect() {
        webSocketClient.disconnect()
        KeychainStore.clear()
        apiClient = nil
        serverName = ""
        serverStatus = nil
        isConnected = false
    }

    /// Refreshes the server status.
    func refreshStatus() async {
        guard let client = apiClient else { return }
        do {
            serverStatus = try await client.getStatus()
            error = nil
        } catch {
            self.error = error.localizedDescription
            // Don't disconnect on transient errors
        }
    }
}

/// Errors from the connection manager.
enum ConnectionError: LocalizedError {
    case invalidURL
    case pairingFailed

    var errorDescription: String? {
        switch self {
        case .invalidURL: "Invalid server URL"
        case .pairingFailed: "Pairing was rejected by the server"
        }
    }
}
