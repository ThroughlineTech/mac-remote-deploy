// TKT-056 (Phase 3): the menu bar is now an API client of its own server, on the
// same footing as the web PWA and the iOS companion. MenuBarClient fronts the
// loopback APIClient + WebSocketClient and publishes the state the menu bar views
// observe -- replacing their old in-process reads of AppState / BuildManager.
//
// It is created as a @StateObject by RemoteDeployApp and `configure`d by
// AppDelegate at startup once the loopback token has been minted (mirroring how
// BuildManager is wired). Until then -- and whenever the server is not reachable
// (cert not configured, :8080 unbound) -- `connectionState` is .connecting /
// .disconnected and the views show a degraded state rather than crashing.
import Foundation
import Combine
import os
import RemoteDeployShared

@MainActor
final class MenuBarClient: ObservableObject {

    /// Name of the menu bar's own paired-device record (its loopback token).
    /// Excluded from the Devices list so the user can't revoke it out from
    /// under the running app. AppDelegate mints the record under this name.
    static let localDeviceName = "Menu bar (local)"

    /// Reachability of the loopback server, driven by the status poll.
    enum ConnectionState: Equatable {
        /// Not yet configured, or the first poll has not completed.
        case connecting
        /// The last status poll succeeded.
        case connected
        /// The last status poll failed (server down or not configured).
        case disconnected
    }

    // MARK: - Published state (observed by the menu bar views)

    @Published private(set) var connectionState: ConnectionState = .connecting
    @Published private(set) var status: ServerStatus?
    @Published private(set) var projects: [ProjectConfig] = []
    @Published private(set) var installs: [InstallRecord] = []
    @Published private(set) var buildHistory: [BuildResult] = []
    @Published private(set) var lastError: String?

    /// Current server settings, fetched on demand by the Settings window (not
    /// part of the menu bar poll). Cached so settings writes preserve unrelated
    /// fields.
    @Published private(set) var settings: SettingsData?

    /// Paired devices, fetched on demand by the Devices tab. The menu bar's own
    /// loopback record is filtered out.
    @Published private(set) var devices: [PairedDevice] = []

    /// The project the menu bar's build controls act on. Pure UI selection,
    /// normalized against `projects` whenever the list changes.
    @Published var selectedProjectID: UUID?

    /// The build configuration the menu bar's Build button uses.
    @Published var buildConfiguration: String = "Release"

    /// Exposed so the build-log window can observe live log/status frames.
    let webSocket = WebSocketClient()

    // MARK: - Derived

    var selectedProject: ProjectConfig? {
        projects.first { $0.id == selectedProjectID }
    }

    /// Most recent build outcome, from history (replaces BuildManager.lastBuildResult).
    var lastBuildResult: BuildResult? {
        buildHistory.max { $0.endTime < $1.endTime }
    }

    /// Most recent install event (replaces AppState.lastInstall).
    var lastInstall: InstallRecord? {
        installs.max { $0.timestamp < $1.timestamp }
    }

    /// Live build log lines streamed over the WebSocket.
    var buildLogLines: [String] { webSocket.buildLogLines }

    /// Whether a build is in progress. Prefers the live WebSocket status frame,
    /// falling back to the polled status snapshot.
    var isBuilding: Bool {
        let state = webSocket.latestStatus?.state ?? status?.buildStatus.state
        return state == "building"
    }

    /// SF Symbol for the menu bar icon, derived from the server's reported
    /// status (replaces AppState's derivation). Shows the "disconnected" glyph
    /// until the first status poll succeeds.
    var menuBarIconName: String {
        guard let status, status.tailscaleConnected else {
            return "antenna.radiowaves.left.and.right.slash"
        }
        return status.serverRunning ? "shippingbox.fill" : "shippingbox"
    }

    // MARK: - Private

    private var client: APIClient?
    private var baseURL: URL?
    private var pollTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    /// How often the status poll runs while the popover/app is alive.
    private let pollInterval: Duration = .seconds(3)

    init() {
        // Forward the WebSocket's published changes (live log + status) so views
        // that observe only this object re-render when WS frames arrive.
        webSocket.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    // MARK: - Lifecycle

    /// Wires the client against the loopback server and starts the status poll
    /// and WebSocket. Idempotent enough to be called again after a restart.
    func configure(baseURL: URL, token: String) {
        self.baseURL = baseURL
        self.client = APIClient(baseURL: baseURL, token: token)
        webSocket.connect(baseURL: baseURL, token: token)
        startPolling()
    }

    /// Begins (or restarts) the periodic status poll. Each tick also refreshes
    /// projects + installs so the menu bar reflects changes made by any client.
    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshAll()
                try? await Task.sleep(for: self?.pollInterval ?? .seconds(3))
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        webSocket.disconnect()
    }

    /// Forces an immediate refresh (e.g. when the popover opens).
    func refreshNow() {
        Task { [weak self] in await self?.refreshAll() }
    }

    // MARK: - Reads

    private func refreshAll() async {
        await refreshStatus()
        // Only fan out the rest once we know the server is reachable.
        guard connectionState == .connected else { return }
        await refreshProjects()
        await refreshInstalls()
        await refreshBuildHistory()
    }

    func refreshStatus() async {
        guard let client else { return }
        do {
            let status = try await client.getStatus()
            self.status = status
            self.connectionState = .connected
            self.lastError = nil
        } catch {
            self.connectionState = .disconnected
        }
    }

    func refreshProjects() async {
        guard let client else { return }
        do {
            projects = try await client.listProjects()
            normalizeSelection()
        } catch {
            recordError(error)
        }
    }

    func refreshInstalls() async {
        guard let client else { return }
        do {
            installs = try await client.getInstalls()
        } catch {
            recordError(error)
        }
    }

    func refreshBuildHistory() async {
        guard let client else { return }
        do {
            buildHistory = try await client.getBuildHistory()
        } catch {
            recordError(error)
        }
    }

    /// Keeps the build picker's selection valid: if the selected project no
    /// longer exists (or none is selected), fall back to the first project.
    private func normalizeSelection() {
        if let id = selectedProjectID, !projects.contains(where: { $0.id == id }) {
            selectedProjectID = projects.first?.id
        } else if selectedProjectID == nil {
            selectedProjectID = projects.first?.id
        }
    }

    // MARK: - Project mutations

    @discardableResult
    func createProject(_ project: ProjectConfig) async -> ProjectConfig? {
        let created = await perform { try await $0.createProject(project) }
        await refreshProjects()
        return created
    }

    @discardableResult
    func updateProject(_ project: ProjectConfig) async -> ProjectConfig? {
        let updated = await perform { try await $0.updateProject(project) }
        await refreshProjects()
        return updated
    }

    func deleteProject(_ id: UUID) async {
        await performVoid { try await $0.deleteProject(id) }
        await refreshProjects()
    }

    // MARK: - Build

    func triggerBuild(projectID: UUID, configuration: String?) async {
        await performVoid { _ = try await $0.triggerBuild(projectID: projectID, configuration: configuration) }
        await refreshStatus()
    }

    func cancelBuild(projectID: UUID) async {
        await performVoid { try await $0.cancelBuild(projectID: projectID) }
        await refreshStatus()
    }

    // MARK: - Settings

    /// Fetches the current settings into `settings` (cached). Called by the
    /// Settings window on appear.
    func refreshSettings() async {
        if let fetched = await perform({ try await $0.getSettings() }) {
            settings = fetched
        }
    }

    /// Reads the freshest settings, applies `mutate`, and PUTs the result --
    /// preserving fields the caller did not touch. The server's settings write
    /// posts `.settingsDidChange`, which makes the host (re)start HTTPS and
    /// reconfigure push notifiers as needed.
    @discardableResult
    func applySettings(_ mutate: (inout SettingsData) -> Void) async -> SettingsData? {
        var base: SettingsData
        if let cached = settings {
            base = cached
        } else if let fetched = await perform({ try await $0.getSettings() }) {
            base = fetched
        } else {
            return nil
        }
        mutate(&base)
        let updated = await perform { try await $0.updateSettings(base) }
        if let updated { settings = updated }
        return updated
    }

    // MARK: - Devices

    /// Fetches paired devices into `devices`, excluding the menu bar's own
    /// loopback record. Called by the Devices tab on appear.
    func refreshDevices() async {
        if let fetched = await perform({ try await $0.listDevices() }) {
            devices = fetched.filter { $0.name != Self.localDeviceName }
        }
    }

    func revokeDevice(id: UUID) async {
        await performVoid { try await $0.revokeDevice(id: id) }
        await refreshDevices()
    }

    // MARK: - Installs

    func deleteInstall(id: UUID) async {
        await performVoid { try await $0.deleteInstall(id: id) }
        await refreshInstalls()
    }

    func deleteAllInstalls() async {
        await performVoid { try await $0.deleteAllInstalls() }
        await refreshInstalls()
    }

    // MARK: - Helpers

    /// Runs a client call that returns a value, recording any error and
    /// refreshing the relevant projections on success.
    private func perform<T>(_ body: (APIClient) async throws -> T) async -> T? {
        guard let client else { return nil }
        do {
            let result = try await body(client)
            lastError = nil
            return result
        } catch {
            recordError(error)
            return nil
        }
    }

    private func performVoid(_ body: (APIClient) async throws -> Void) async {
        guard let client else { return }
        do {
            try await body(client)
            lastError = nil
        } catch {
            recordError(error)
        }
    }

    private func recordError(_ error: Error) {
        lastError = error.localizedDescription
        Logger.server.error("MenuBarClient request failed: \(error.localizedDescription, privacy: .public)")
    }
}
