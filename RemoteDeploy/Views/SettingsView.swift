import SwiftUI
import Foundation
import ServiceManagement
import os

// MARK: - Settings View

/// The main settings window, organized as a tabbed interface.
/// Covers server configuration, project management, push notification providers,
/// and general preferences.
struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var menuBarClient: MenuBarClient

    var body: some View {
        // TKT-056 (Phase 3): the data tabs read/write through the MenuBarClient.
        // `appState.selectedSettingsTab` is pure UI navigation (which tab the menu
        // bar asked to open). TKT-060 (Phase 6): scheme detection + path picking
        // also go through the client (server-side over the API), so no
        // ServiceContainer is needed anymore.
        TabView(selection: $appState.selectedSettingsTab) {
            ServerSettingsTab()
                .environmentObject(menuBarClient)
                .tabItem {
                    Label("Server", systemImage: "server.rack")
                }
                .tag("server")

            ProjectsSettingsTab()
                .environmentObject(menuBarClient)
                .tabItem {
                    Label("Projects", systemImage: "folder")
                }
                .tag("projects")

            PushSettingsTab()
                .environmentObject(menuBarClient)
                .tabItem {
                    Label("Notifications", systemImage: "bell")
                }
                .tag("notifications")

            PairedDevicesTab()
                .environmentObject(menuBarClient)
                .tabItem {
                    Label("Devices", systemImage: "iphone")
                }
                .tag("devices")

            AboutSettingsTab()
                .tabItem {
                    Label("About", systemImage: "info.circle")
                }
                .tag("about")
        }
        .frame(width: 560, height: 450)
    }
}

// MARK: - Server Settings Tab

/// Configures the HTTPS server: port, hostname, TLS certificate paths,
/// and launch-at-login preference. Grouped into visual sections with a
/// server status card at the top. TKT-037.
struct ServerSettingsTab: View {
    @EnvironmentObject var menuBarClient: MenuBarClient

    @State private var port: String = "8443"
    @State private var hostname: String = ""
    @State private var certPath: String = ""
    @State private var keyPath: String = ""
    @State private var launchAtLogin = false
    /// Debounces field edits so per-keystroke typing coalesces into one PUT.
    @State private var saveTask: Task<Void, Never>?

    /// Whether the HTTPS install server is running, from the status payload.
    private var isRunning: Bool { menuBarClient.status?.serverRunning ?? false }

    /// The install URL, only meaningful when reachable over Tailscale.
    private var serverURL: String {
        guard let status = menuBarClient.status, status.tailscaleConnected, !status.hostname.isEmpty else { return "" }
        return "https://\(status.hostname):\(status.serverPort)"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {

                // MARK: Server Status Card

                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(isRunning ? Color.green : Color.red)
                            .frame(width: 8, height: 8)
                        Text(isRunning ? "Server Running" : "Server Stopped")
                            .font(.headline)
                        Spacer()
                        if let status = menuBarClient.status, isRunning {
                            Text("Port \(status.serverPort)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    if !serverURL.isEmpty {
                        Text(serverURL)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }

                    HStack {
                        Button("Restart Server") {
                            // TKT-060 (Phase 6): the server is a separate process,
                            // so the menu bar can't post an in-process restart. Re-
                            // apply the current settings through the API; the
                            // server's settings-change reconcile rebinds HTTPS if
                            // the port or cert/key path changed.
                            Task { await menuBarClient.applySettings { _ in } }
                        }
                        .disabled(!isRunning)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color(.controlBackgroundColor))
                )

                // MARK: Server Identity

                GroupBox("Server Identity") {
                    VStack(alignment: .leading, spacing: 10) {
                        // Port number field
                        HStack {
                            Text("Port:")
                                .frame(width: 70, alignment: .trailing)
                            TextField("", text: $port)
                                .frame(width: 80)
                                .textFieldStyle(.roundedBorder)
                                .onChange(of: port) { scheduleSave() }
                        }

                        // Hostname (auto-detected server-side; editable to override)
                        HStack {
                            Text("Hostname:")
                                .frame(width: 70, alignment: .trailing)
                            TextField("", text: $hostname)
                                .textFieldStyle(.roundedBorder)
                                .onChange(of: hostname) { scheduleSave() }
                        }
                    }
                    .padding(.vertical, 4)
                }

                // MARK: TLS Certificate

                GroupBox("TLS Certificate") {
                    VStack(alignment: .leading, spacing: 10) {
                        // Certificate file path with browse button
                        HStack {
                            Text("Certificate:")
                                .frame(width: 70, alignment: .trailing)
                            Text(certFilename)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .help(certPath)
                            Button("Browse...") {
                                if let url = openFilePanel(title: "Select Certificate PEM") {
                                    certPath = url.path
                                    scheduleSave()
                                }
                            }
                        }

                        // Private key file path with browse button
                        HStack {
                            Text("Private Key:")
                                .frame(width: 70, alignment: .trailing)
                            Text(keyFilename)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .help(keyPath)
                            Button("Browse...") {
                                if let url = openFilePanel(title: "Select Private Key PEM") {
                                    keyPath = url.path
                                    scheduleSave()
                                }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }

                // MARK: General

                GroupBox("General") {
                    Toggle("Launch at Login", isOn: $launchAtLogin)
                        .onChange(of: launchAtLogin) {
                            setLaunchAtLogin(launchAtLogin)
                        }
                        .padding(.vertical, 4)
                }
            }
            .padding()
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .task {
            // Load current values from the server via the client.
            await menuBarClient.refreshSettings()
            if let settings = menuBarClient.settings {
                port = String(settings.serverPort)
                hostname = settings.hostname
                certPath = settings.certPath
                keyPath = settings.keyPath
            }
            launchAtLogin = isLaunchAtLoginEnabled()
        }
    }

    /// The filename portion of the certificate path, or a placeholder.
    private var certFilename: String {
        certPath.isEmpty ? "No certificate selected" : URL(fileURLWithPath: certPath).lastPathComponent
    }

    /// The filename portion of the private key path, or a placeholder.
    private var keyFilename: String {
        keyPath.isEmpty ? "No key selected" : URL(fileURLWithPath: keyPath).lastPathComponent
    }

    /// Persists the server fields through the API client after a short debounce
    /// so rapid typing (and a cert + key pick in quick succession) coalesce into
    /// one write. The server's settings write brings HTTPS up once certs exist.
    private func scheduleSave() {
        saveTask?.cancel()
        let portValue = Int(port)
        let host = hostname, cert = certPath, key = keyPath
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            await menuBarClient.applySettings { settings in
                if let portValue { settings.serverPort = portValue }
                settings.hostname = host
                settings.certPath = cert
                settings.keyPath = key
            }
        }
    }

    /// Presents an NSOpenPanel configured for selecting a single file.
    private func openFilePanel(title: String) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.allowedContentTypes = []
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Checks whether the app is currently registered as a login item.
    private func isLaunchAtLoginEnabled() -> Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return false
    }

    /// Registers or unregisters the app as a login item using SMAppService.
    /// - Parameter enabled: Whether to enable or disable launch at login.
    private func setLaunchAtLogin(_ enabled: Bool) {
        if #available(macOS 13.0, *) {
            do {
                if enabled {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                Logger.ui.error("Failed to \(enabled ? "enable" : "disable", privacy: .public) launch at login: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

// MARK: - Projects Settings Tab

/// Lists configured projects with add, edit, and delete controls.
struct ProjectsSettingsTab: View {
    // TKT-060 (Phase 6): ProjectFormView does scheme detection + path browsing
    // through the client (server-side over the API), so no ServiceContainer here.
    @EnvironmentObject var menuBarClient: MenuBarClient

    /// Tracks the project currently being edited in the sheet.
    @State private var editingProject: ProjectConfig = ProjectConfig(name: "", projectPath: "")
    /// Controls whether the add/edit sheet is shown.
    @State private var showingProjectForm = false

    var body: some View {
        VStack {
            // Project list with selection highlighting
            List {
                ForEach(menuBarClient.projects) { project in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(project.name)
                                .font(.headline)
                            Text(project.projectPath)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        // Edit button for each row
                        Button("Edit") {
                            editingProject = project
                            showingProjectForm = true
                        }
                        .buttonStyle(.borderless)
                    }
                }
                .onDelete { indexSet in
                    // TKT-056 (Phase 3): delete via the API client.
                    let toDelete = indexSet.map { menuBarClient.projects[$0] }
                    Task { for project in toDelete { await menuBarClient.deleteProject(project.id) } }
                }
            }

            // Bottom toolbar with add and remove buttons
            HStack {
                Button {
                    editingProject = ProjectConfig(name: "", projectPath: "")
                    showingProjectForm = true
                } label: {
                    Label("Add Project", systemImage: "plus")
                }
                Spacer()
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
        .sheet(isPresented: $showingProjectForm) {
            ProjectFormView(
                project: $editingProject,
                onSave: { savedProject in
                    // TKT-056 (Phase 3): create vs. update through the API client.
                    let isExisting = menuBarClient.projects.contains { $0.id == savedProject.id }
                    Task {
                        if isExisting {
                            await menuBarClient.updateProject(savedProject)
                        } else {
                            await menuBarClient.createProject(savedProject)
                        }
                    }
                    showingProjectForm = false
                },
                onCancel: {
                    showingProjectForm = false
                },
                onDelete: { deletedProject in
                    Task { await menuBarClient.deleteProject(deletedProject.id) }
                    showingProjectForm = false
                }
            )
        }
    }
}

// MARK: - Push Notifications Settings Tab

/// Per-provider push notification configuration with enable toggles,
/// credential fields, test buttons, and help popovers.
struct PushSettingsTab: View {
    @EnvironmentObject var menuBarClient: MenuBarClient

    @State private var config = PushNotificationConfig()
    /// Error message from a failed test notification.
    @State private var testError: String?
    /// Whether a test notification is in progress.
    @State private var isSendingTest = false
    /// Debounces credential typing into one settings write.
    @State private var saveTask: Task<Void, Never>?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                // --- Prowl ---
                PushProviderSection(
                    providerName: "Prowl",
                    providerType: .prowl,
                    enabled: $config.prowlEnabled,
                    onSendTest: { sendTest(for: .prowl) }
                ) {
                    SecretField(label: "API Key:", text: $config.prowlAPIKey)
                }

                // --- Pushover ---
                PushProviderSection(
                    providerName: "Pushover",
                    providerType: .pushover,
                    enabled: $config.pushoverEnabled,
                    onSendTest: { sendTest(for: .pushover) }
                ) {
                    SecretField(label: "App Token:", text: $config.pushoverAppToken)
                    SecretField(label: "User Key:", text: $config.pushoverUserKey)
                }

                // --- ntfy ---
                PushProviderSection(
                    providerName: "ntfy",
                    providerType: .ntfy,
                    enabled: $config.ntfyEnabled,
                    onSendTest: { sendTest(for: .ntfy) }
                ) {
                    TextField("Server URL:", text: $config.ntfyServerURL)
                    TextField("Topic:", text: $config.ntfyTopic)
                }

                // --- Event Toggles ---
                GroupBox("Notify On") {
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle("Build Started", isOn: $config.notifyOnBuildStarted)
                        Toggle("Build Success", isOn: $config.notifyOnBuildSuccess)
                        Toggle("Build Failure", isOn: $config.notifyOnBuildFailure)
                    }
                    .toggleStyle(.checkbox)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                // Display test error if any
                if let testError {
                    Text(testError)
                        .font(.caption)
                        .foregroundColor(.red)
                }
            }
            .padding()
        }
        .task {
            await menuBarClient.refreshSettings()
            if let settings = menuBarClient.settings {
                config = settings.pushNotificationConfig
            }
        }
        .onChange(of: config.prowlEnabled) { syncConfig() }
        .onChange(of: config.prowlAPIKey) { syncConfig() }
        .onChange(of: config.pushoverEnabled) { syncConfig() }
        .onChange(of: config.pushoverAppToken) { syncConfig() }
        .onChange(of: config.pushoverUserKey) { syncConfig() }
        .onChange(of: config.ntfyEnabled) { syncConfig() }
        .onChange(of: config.ntfyServerURL) { syncConfig() }
        .onChange(of: config.ntfyTopic) { syncConfig() }
        .onChange(of: config.notifyOnBuildStarted) { syncConfig() }
        .onChange(of: config.notifyOnBuildSuccess) { syncConfig() }
        .onChange(of: config.notifyOnBuildFailure) { syncConfig() }
    }

    /// Persists the push config through the API client after a short debounce.
    /// The server's settings write reconfigures its push notifiers (AppDelegate
    /// observes `.settingsDidChange`). TKT-056 (Phase 3).
    private func syncConfig() {
        saveTask?.cancel()
        let snapshot = config
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await menuBarClient.applySettings { $0.pushNotificationConfig = snapshot }
        }
    }

    /// Sends a test notification for the given provider.
    private func sendTest(for provider: PushProvider) {
        isSendingTest = true
        testError = nil

        Task {
            do {
                switch provider {
                case .prowl:
                    let notifier = ProwlNotifier(apiKey: config.prowlAPIKey)
                    try await notifier.sendTest()
                case .pushover:
                    let notifier = PushoverNotifier(appToken: config.pushoverAppToken, userKey: config.pushoverUserKey)
                    try await notifier.sendTest()
                case .ntfy:
                    let notifier = NtfyNotifier(serverURL: config.ntfyServerURL, topic: config.ntfyTopic)
                    try await notifier.sendTest()
                }
            } catch {
                testError = "Test failed: \(error.localizedDescription)"
            }
            isSendingTest = false
        }
    }
}

/// A reusable section for a single push notification provider.
/// Includes an enable toggle, configuration fields (injected via content closure),
/// a "Send Test" button, and a "?" help popover.
/// Styled as a rounded card with subtle background when enabled.
struct PushProviderSection<Content: View>: View {
    let providerName: String
    let providerType: PushProvider
    @Binding var enabled: Bool
    /// Callback invoked when the Send Test button is tapped.
    var onSendTest: (() -> Void)?
    @ViewBuilder var content: Content

    @State private var showHelp = false
    @State private var showSecret = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Enable/disable toggle for this provider
            Toggle(providerName, isOn: $enabled)
                .font(.headline)

            // Provider-specific configuration fields, help, and test button
            if enabled {
                content
                    .textFieldStyle(.roundedBorder)

                HStack {
                    // Help popover button showing setup instructions
                    Button {
                        showHelp.toggle()
                    } label: {
                        Image(systemName: "questionmark.circle")
                    }
                    .buttonStyle(.borderless)
                    .popover(isPresented: $showHelp) {
                        PushNotifHelpPopover(provider: providerType)
                    }

                    Spacer()

                    // Send test notification button
                    Button("Send Test") {
                        onSendTest?()
                    }
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(enabled ? Color.gray.opacity(0.1) : Color.clear)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .opacity(enabled ? 1.0 : 0.6)
    }
}

/// A text field that toggles between SecureField (masked) and TextField (plain)
/// for displaying sensitive credentials like API keys and tokens.
private struct SecretField: View {
    let label: String
    @Binding var text: String
    @State private var showSecret = false

    var body: some View {
        HStack(spacing: 4) {
            if showSecret {
                TextField(label, text: $text)
            } else {
                SecureField(label, text: $text)
            }
            Button {
                showSecret.toggle()
            } label: {
                Image(systemName: showSecret ? "eye.slash" : "eye")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.borderless)
        }
    }
}

// MARK: - About Tab

/// About page with app info, links, and company branding.
struct AboutSettingsTab: View {
    private let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    private let buildNumber = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            // App icon
            Image("AboutIcon")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 100, height: 100)
                .clipShape(RoundedRectangle(cornerRadius: 22))
                .shadow(color: .black.opacity(0.15), radius: 8, y: 4)

            // App name + version
            VStack(spacing: 4) {
                Text("RemoteDeploy")
                    .font(.title)
                    .fontWeight(.bold)
                Text("Version \(appVersion) (\(buildNumber))")
                    .font(.callout)
                    .foregroundColor(.secondary)
            }

            Text("Build, sign, and deploy iOS and macOS apps to your devices from anywhere.\nControl builds from your phone or any browser.")
                .font(.callout)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 420)

            // Links
            HStack(spacing: 16) {
                LinkButton(title: "GitHub", systemImage: "chevron.left.forwardslash.chevron.right",
                           url: "https://github.com/ThroughlineTech/mac-remote-deploy")
                LinkButton(title: "Deep Dive", systemImage: "doc.text.magnifyingglass",
                           url: "https://www.throughlinetech.net/deep-dives/remotedeploy")
                LinkButton(title: "Website", systemImage: "globe",
                           url: "https://www.throughlinetech.net")
            }

            Spacer()

            // Company branding
            VStack(spacing: 4) {
                Text("Made by")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Button("Throughline Tech, LLC") {
                    NSWorkspace.shared.open(URL(string: "https://www.throughlinetech.net")!)
                }
                .buttonStyle(.link)
                .font(.callout)
            }

            // Credits
            HStack(spacing: 20) {
                Text("SwiftNIO")
                Text("Tailscale")
                Text("Let's Encrypt")
            }
            .font(.caption2)
            .foregroundColor(.secondary)
            .padding(.bottom, 8)
        }
        .padding()
    }
}

/// A small button that opens a URL.
private struct LinkButton: View {
    let title: String
    let systemImage: String
    let url: String

    var body: some View {
        Button {
            NSWorkspace.shared.open(URL(string: url)!)
        } label: {
            VStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.title3)
                Text(title)
                    .font(.caption)
            }
            .frame(width: 80, height: 50)
        }
        .buttonStyle(.bordered)
    }
}
