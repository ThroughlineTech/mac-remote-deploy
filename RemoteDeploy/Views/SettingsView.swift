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
    @EnvironmentObject var serviceContainer: ServiceContainer

    var body: some View {
        TabView {
            ServerSettingsTab(appState: appState)
                .environmentObject(serviceContainer)
                .tabItem {
                    Label("Server", systemImage: "server.rack")
                }

            ProjectsSettingsTab(appState: appState)
                .environmentObject(serviceContainer)
                .tabItem {
                    Label("Projects", systemImage: "folder")
                }

            PushSettingsTab(appState: appState)
                .environmentObject(serviceContainer)
                .tabItem {
                    Label("Notifications", systemImage: "bell")
                }

            PairedDevicesTab()
                .environmentObject(serviceContainer)
                .environmentObject(appState)
                .tabItem {
                    Label("Devices", systemImage: "iphone")
                }

            GeneralSettingsTab()
                .tabItem {
                    Label("General", systemImage: "gear")
                }

            AboutSettingsTab()
                .tabItem {
                    Label("About", systemImage: "info.circle")
                }
        }
        .frame(width: 560, height: 450)
    }
}

// MARK: - Server Settings Tab

/// Configures the HTTPS server: port, hostname, and TLS certificate paths.
struct ServerSettingsTab: View {
    @ObservedObject var appState: AppState
    @EnvironmentObject var serviceContainer: ServiceContainer

    @State private var port: String = "8443"
    @State private var hostname: String = ""
    @State private var certPath: String = ""
    @State private var keyPath: String = ""
    @State private var isDetectingHostname = false

    var body: some View {
        Form {
            // Port number field
            TextField("Port:", text: $port)
                .frame(width: 80)
                .onChange(of: port) {
                    if let p = Int(port) {
                        appState.serverPort = p
                        updateServerURL()
                        requestSaveSettings()
                    }
                }

            // Hostname with auto-detect button
            HStack {
                TextField("Hostname:", text: $hostname)
                    .onChange(of: hostname) {
                        appState.hostname = hostname
                        updateServerURL()
                        requestSaveSettings()
                    }
                Button {
                    detectHostname()
                } label: {
                    if isDetectingHostname {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Auto-Detect")
                    }
                }
                .disabled(isDetectingHostname)
            }

            Divider()

            // TLS certificate file path with browse button
            HStack {
                TextField("Certificate:", text: $certPath)
                    .onChange(of: certPath) {
                        appState.certPath = certPath
                        requestSaveSettings()
                    }
                Button("Browse...") {
                    if let url = openFilePanel(title: "Select Certificate PEM", types: ["pem", "crt"]) {
                        certPath = url.path
                        appState.certPath = url.path
                        requestSaveSettings()
                    }
                }
            }

            // TLS private key file path with browse button
            HStack {
                TextField("Private Key:", text: $keyPath)
                    .onChange(of: keyPath) {
                        appState.keyPath = keyPath
                        requestSaveSettings()
                    }
                Button("Browse...") {
                    if let url = openFilePanel(title: "Select Private Key PEM", types: ["pem", "key"]) {
                        keyPath = url.path
                        appState.keyPath = url.path
                        requestSaveSettings()
                    }
                }
            }
        }
        .padding()
        .onAppear {
            // Load current values from appState
            port = String(appState.serverPort)
            hostname = appState.hostname
            certPath = appState.certPath
            keyPath = appState.keyPath
        }
    }

    /// Auto-detects the Tailscale hostname using the provider service.
    private func detectHostname() {
        isDetectingHostname = true
        Task {
            do {
                let detected = try await serviceContainer.tailscaleProvider.detectHostname()
                hostname = detected
                appState.hostname = detected
                updateServerURL()
                requestSaveSettings()
            } catch {
                Logger.tailscale.error("Hostname detection failed: \(error.localizedDescription, privacy: .public)")
            }
            isDetectingHostname = false
        }
    }

    /// Updates the server URL from hostname and port.
    private func updateServerURL() {
        if !appState.hostname.isEmpty {
            appState.serverURL = "https://\(appState.hostname):\(appState.serverPort)"
        }
    }

    /// Posts a notification to request settings persistence.
    private func requestSaveSettings() {
        NotificationCenter.default.post(name: .saveSettingsRequested, object: nil)
    }

    /// Presents an NSOpenPanel configured for selecting a single file.
    private func openFilePanel(title: String, types: [String]) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.allowedContentTypes = []
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }
}

// MARK: - Projects Settings Tab

/// Lists configured projects with add, edit, and delete controls.
struct ProjectsSettingsTab: View {
    @ObservedObject var appState: AppState
    @EnvironmentObject var serviceContainer: ServiceContainer

    /// Tracks the project currently being edited in the sheet.
    @State private var editingProject: ProjectConfig = ProjectConfig(name: "", projectPath: "")
    /// Controls whether the add/edit sheet is shown.
    @State private var showingProjectForm = false

    var body: some View {
        VStack {
            // Project list with selection highlighting
            List {
                ForEach(appState.projects) { project in
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
                    // Delete from persistent store then from appState
                    for index in indexSet {
                        let project = appState.projects[index]
                        try? serviceContainer.projectStore.delete(projectID: project.id)
                    }
                    appState.projects.remove(atOffsets: indexSet)
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
                    // Persist to store
                    try? serviceContainer.projectStore.save(project: savedProject)
                    // Update in-memory state
                    if let index = appState.projects.firstIndex(where: { $0.id == savedProject.id }) {
                        appState.projects[index] = savedProject
                    } else {
                        appState.projects.append(savedProject)
                    }
                    showingProjectForm = false
                },
                onCancel: {
                    showingProjectForm = false
                },
                onDelete: { deletedProject in
                    try? serviceContainer.projectStore.delete(projectID: deletedProject.id)
                    appState.projects.removeAll { $0.id == deletedProject.id }
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
    @ObservedObject var appState: AppState
    @EnvironmentObject var serviceContainer: ServiceContainer

    @State private var config = PushNotificationConfig()
    /// Error message from a failed test notification.
    @State private var testError: String?
    /// Whether a test notification is in progress.
    @State private var isSendingTest = false

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
                    Toggle("Build Started", isOn: $config.notifyOnBuildStarted)
                    Toggle("Build Success", isOn: $config.notifyOnBuildSuccess)
                    Toggle("Build Failure", isOn: $config.notifyOnBuildFailure)
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
        .onAppear {
            config = appState.pushNotificationConfig
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

    /// Syncs config to appState, reconfigures push notifiers, and requests save.
    private func syncConfig() {
        appState.pushNotificationConfig = config
        serviceContainer.configurePushNotifiers(from: config)
        NotificationCenter.default.post(name: .saveSettingsRequested, object: nil)
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
                .fill(enabled ? Color(.controlBackgroundColor) : Color.clear)
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

// MARK: - General Settings Tab

/// General app preferences: launch-at-login toggle.
struct GeneralSettingsTab: View {
    @State private var launchAtLogin = false

    var body: some View {
        Form {
            Toggle("Launch at Login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) {
                    setLaunchAtLogin(launchAtLogin)
                }
        }
        .padding()
        .onAppear {
            launchAtLogin = isLaunchAtLoginEnabled()
        }
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
                           url: "https://github.com/danrichardson/mac-remote-deploy")
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
