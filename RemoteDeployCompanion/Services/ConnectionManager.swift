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

    /// The currently selected tab index — settable from any view to
    /// programmatically switch tabs (e.g. "View Build Log" button).
    @Published var selectedTab: Int = 0

    /// Error message for display.
    @Published var error: String?

    /// TKT-066 diagnostic: the keychain save/read status from the last restore
    /// attempt, surfaced on the pairing screen to pinpoint the re-pair-on-cold-
    /// start bug. Empty until a restore is attempted.
    @Published var restoreDiagnostic: String = ""

    /// The API client for making requests to the server.
    private(set) var apiClient: APIClient?

    /// Guards against overlapping restore attempts (the scene can fire
    /// `.active` more than once while a Face ID / passcode prompt is up).
    private var isRestoring = false

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

        // NOTE: restore is intentionally NOT kicked off from init(). The keychain
        // read is gated by LAContext.evaluatePolicy (Face ID / passcode, TKT-022),
        // and firing that from init -- before the scene is reliably interactive --
        // can fail with `notInteractive`, present no prompt, and silently drop to
        // the pairing screen with no retry. The app now calls
        // `restoreConnectionIfNeeded()` once the scene is `.active`, and again on
        // each foreground while still disconnected (see RemoteDeployCompanionApp).
    }

    /// Restores the saved connection when appropriate. Safe to call repeatedly:
    /// no-ops if already connected or a restore is in flight, and -- crucially --
    /// does NOT prompt for Face ID when there are no saved credentials, so a
    /// never-paired user goes straight to the pairing screen without a prompt.
    /// Called on scene activation (and re-called on each foreground while
    /// disconnected), which doubles as the retry path the old init-time call
    /// lacked.
    func restoreConnectionIfNeeded() async {
        guard !isConnected, !isRestoring else { return }
        guard KeychainStore.hasStoredCredentials() else {
            logger.info("restore: no saved credentials; showing pairing screen")
            restoreDiagnostic = KeychainStore.diagnosticSummary()
            return
        }
        isRestoring = true
        defer { isRestoring = false }
        await restoreConnection()
        if !isConnected {
            restoreDiagnostic = KeychainStore.diagnosticSummary()
        }
    }

    /// Attempts to connect using saved Keychain credentials. Async because the
    /// keychain read is gated by LAContext.evaluatePolicy (Face ID / passcode).
    func restoreConnection() async {
        guard let saved = await KeychainStore.load() else {
            // We only get here when hasStoredCredentials() said an item exists,
            // so a nil load means the Face ID / passcode auth was cancelled or
            // the keychain read failed (the OSStatus is logged in KeychainStore).
            // Leaving the user on the pairing screen; a foreground retries.
            logger.error("restore: credentials present but load returned nil (auth cancelled or read failed)")
            return
        }
        guard let url = URL(string: saved.url) else {
            logger.error("restore: saved URL is invalid: \(saved.url, privacy: .public)")
            return
        }

        apiClient = APIClient(baseURL: url, token: saved.token)
        buildManager.setClient(apiClient)
        serverName = saved.serverName
        isConnected = true

        // Connect WebSocket so live build log and status updates work
        // from app launch, not just after fresh pairing (TKT-040).
        webSocketClient.connect(baseURL: url, token: saved.token)
        buildManager.observeWebSocketStatus(webSocketClient)

        // Verify the connection works
        await refreshStatus()
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

        // Haptic feedback to celebrate the successful pairing (TKT-017).
        UINotificationFeedbackGenerator().notificationOccurred(.success)

        // Save credentials and connect
        KeychainStore.save(url: url, token: token, serverName: response.serverName)

        self.apiClient = client
        self.buildManager.setClient(client)
        self.serverName = response.serverName
        self.isConnected = true

        // Connect WebSocket (best-effort, don't block pairing if it fails)
        webSocketClient.connect(baseURL: baseURL, token: token)
        buildManager.observeWebSocketStatus(webSocketClient)

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
        buildManager.observeWebSocketStatus(webSocketClient)
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
