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
    /// under the running app. The headless server mints the record under this
    /// name; the canonical string lives in LoopbackTokenStore so both processes
    /// agree without the menu bar depending on server-side code. TKT-060.
    static let localDeviceName = LoopbackTokenStore.deviceName

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

    /// Lines shown in the build-log window. Prefers the live WebSocket stream;
    /// when nothing is streaming (fresh launch, between builds) it backfills
    /// from the most recent completed build's persisted log so the window is
    /// never blank. While a build is in progress the live stream is always
    /// authoritative, even momentarily empty, so we don't flash a stale log.
    var buildLogLines: [String] {
        let live = webSocket.buildLogLines
        if !live.isEmpty || isBuilding { return live }
        guard let log = lastBuildResult?.buildLog, !log.isEmpty else { return [] }
        return log.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    /// Whether a build is in progress. Reconciles the live WebSocket status
    /// frame against the polled REST snapshot via `BuildStateReconciler` so a
    /// stale `"building"` frame (e.g. one that missed the terminal transition
    /// across a reconnect) can never keep the spinner alive past the build.
    var isBuilding: Bool {
        BuildStateReconciler.isBuilding(
            polled: status?.buildStatus.state,
            live: webSocket.latestStatus?.state
        )
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

    /// Paired-device ids known as of the last successful `refreshDevices()`. Nil
    /// until the first fetch, so the initial population never fires a "new device"
    /// notification for devices that were already paired before launch.
    private var knownDeviceIDs: Set<UUID>?

    /// Poll cadence while the menu bar popover is OPEN: refresh everything the user
    /// is looking at, quickly.
    private let activePollInterval: Duration = .seconds(3)

    /// Poll cadence while the popover is CLOSED: a lightweight status (+devices)
    /// call, infrequently, so an idle background app stops hammering the server
    /// every few seconds. The every-3s full poll kept CFNetwork busy (preventing
    /// the Mac from idle-sleeping) and burned energy refreshing data nobody can
    /// see. The full project/install/history refresh is skipped while closed; live
    /// build status still arrives over the WebSocket. TKT-073.
    private let idlePollInterval: Duration = .seconds(30)

    /// True while the menu bar popover is open (set by the popover content's
    /// appear/disappear). Drives the poll cadence above.
    private var isActive = false

    init() {
        // Forward ONLY the WebSocket's build-status changes, not its log stream
        // (TKT-074). Forwarding every `objectWillChange` re-rendered all views
        // bound to this client (projects list, build controls, ...) on every
        // streamed `buildlog` line; during a build that fired dozens of times a
        // second. The menu bar only depends on `latestStatus` (via `isBuilding`
        // and the backfill in `buildLogLines`), so forward that, deduped -- the
        // build-log window observes `webSocket.buildLogLines` directly for the
        // high-frequency log stream.
        webSocket.$latestStatus
            .removeDuplicates()
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
        pollTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // Full refresh on every (re)start -- covers launch and popover-open so
            // the menu is populated immediately rather than after the first sleep.
            await self.refreshAll()
            while !Task.isCancelled {
                let interval = self.isActive ? self.activePollInterval : self.idlePollInterval
                try? await Task.sleep(for: interval)
                if Task.isCancelled { break }
                if self.isActive {
                    await self.refreshAll()
                } else {
                    // Closed: just keep the icon current and surface out-of-band
                    // device pairings (TKT-070) -- the rest is invisible.
                    await self.refreshStatus()
                    if self.connectionState == .connected { await self.refreshDevices() }
                }
            }
        }
    }

    /// Called by the menu bar popover when it opens/closes. Open -> snap to fresh
    /// data and switch to the fast poll; closed -> drop to the slow status poll so
    /// the app stops working in the background. TKT-073.
    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        // On open, restart so the loop does an immediate full refresh and enters the
        // fast branch. On close, the running loop notices `isActive` on its next
        // tick and switches to the slow branch -- no restart needed.
        if active { startPolling() }
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
        // Keep the Devices list live and surface out-of-band pairings (TKT-070).
        await refreshDevices()
    }

    // Each poll tick reassigns these @Published projections. Guarding on equality
    // (publish-on-change) keeps an unchanged poll from firing `objectWillChange`
    // and re-rendering the whole menu every few seconds -- the steady-state idle
    // case (TKT-074). The model types are Equatable.

    func refreshStatus() async {
        guard let client else { return }
        do {
            let status = try await client.getStatus()
            if self.status != status { self.status = status }
            if connectionState != .connected { connectionState = .connected }
            if lastError != nil { lastError = nil }
        } catch {
            if connectionState != .disconnected { connectionState = .disconnected }
        }
    }

    func refreshProjects() async {
        guard let client else { return }
        do {
            let fetched = try await client.listProjects()
            if projects != fetched { projects = fetched }
            normalizeSelection()
        } catch {
            recordError(error)
        }
    }

    func refreshInstalls() async {
        guard let client else { return }
        do {
            let fetched = try await client.getInstalls()
            if installs != fetched { installs = fetched }
        } catch {
            recordError(error)
        }
    }

    func refreshBuildHistory() async {
        guard let client else { return }
        do {
            let fetched = try await client.getBuildHistory()
            if buildHistory != fetched { buildHistory = fetched }
        } catch {
            recordError(error)
        }
    }

    /// Keeps the build picker's selection valid: if the selected project no
    /// longer exists (or none is selected), fall back to the first project.
    private func normalizeSelection() {
        let resolved: UUID?
        if let id = selectedProjectID, !projects.contains(where: { $0.id == id }) {
            resolved = projects.first?.id
        } else if selectedProjectID == nil {
            resolved = projects.first?.id
        } else {
            resolved = selectedProjectID
        }
        // Publish-on-change: a steady poll leaves the selection untouched, so don't
        // re-render the build picker every tick (TKT-074).
        if resolved != selectedProjectID { selectedProjectID = resolved }
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
    /// loopback record. Called by the Devices tab on appear AND on every status
    /// poll (see `refreshAll`), so a device that pairs out-of-band -- e.g. via a
    /// phone's "Pair Another Device" flow -- shows up on the Mac within a poll
    /// interval instead of only when the Devices tab is reopened (TKT-070).
    ///
    /// Any device that appears since the last successful fetch also fires a
    /// desktop notification, so the Mac surfaces an out-of-band pairing even when
    /// no window is open. The first fetch only seeds the baseline (no alerts for
    /// devices already paired before launch).
    func refreshDevices() async {
        guard let fetched = await perform({ try await $0.listDevices() }) else { return }
        let visible = fetched.filter { $0.name != Self.localDeviceName }

        if let known = knownDeviceIDs {
            for device in visible where !known.contains(device.id) {
                NotificationManager.shared.postNotification(
                    title: "New Device Paired",
                    body: "\(device.name) can now control builds.",
                    identifier: "device-paired-\(device.id.uuidString)"
                )
            }
        }
        knownDeviceIDs = Set(visible.map(\.id))
        // Publish-on-change: the device list is stable between out-of-band
        // pairings, so don't re-render the Devices tab on every poll (TKT-074).
        if devices != visible { devices = visible }
    }

    func revokeDevice(id: UUID) async {
        await performVoid { try await $0.revokeDevice(id: id) }
        await refreshDevices()
    }

    // MARK: - Filesystem (setup wizard + project form). TKT-060 (Phase 6).

    /// Browses a directory on the server host for the project path picker.
    func browseFilesystem(path: String?) async -> FilesystemBrowseResponse? {
        await perform { try await $0.browseFilesystem(path: path) }
    }

    /// Detects Xcode schemes for a chosen .xcodeproj/.xcworkspace path.
    func detectSchemes(projectPath: String) async -> [String]? {
        await perform { try await $0.detectSchemes(path: projectPath).schemes }
    }

    // MARK: - Pairing mint (setup wizard + Pair Browser/Device). TKT-060.

    /// Mints a one-time pairing token on the server for another device to claim.
    func mintPairingToken() async -> PendingPairingResponse? {
        await perform { try await $0.mintPairingToken() }
    }

    // MARK: - Certificate provisioning (setup wizard). TKT-060.

    /// Starts server-side Tailscale cert provisioning. Poll `certificateStatus()`.
    @discardableResult
    func provisionCertificate() async -> CertProvisioningState? {
        await perform { try await $0.provisionCertificate() }
    }

    /// Returns the current Tailscale cert provisioning state.
    func certificateStatus() async -> CertProvisioningState? {
        await perform { try await $0.certificateStatus() }
    }

    // MARK: - IPA upload (Utilities). TKT-060.

    /// Uploads a prebuilt .ipa to the server for the given project.
    func uploadIPA(projectID: UUID, fileName: String, data: Data) async -> IPAUploadResponse? {
        await perform { try await $0.uploadIPA(projectID: projectID, fileName: fileName, data: data) }
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
            if lastError != nil { lastError = nil }
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
            if lastError != nil { lastError = nil }
        } catch {
            recordError(error)
        }
    }

    private func recordError(_ error: Error) {
        lastError = error.localizedDescription
        Logger.server.error("MenuBarClient request failed: \(error.localizedDescription, privacy: .public)")
    }
}
