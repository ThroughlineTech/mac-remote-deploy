import SwiftUI
import Foundation

// MARK: - Settings View

/// The main settings window, organized as a tabbed interface.
/// Covers server configuration, project management, push notification providers,
/// and general preferences.
struct SettingsView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        TabView {
            ServerSettingsTab(appState: appState)
                .tabItem {
                    Label("Server", systemImage: "server.rack")
                }

            ProjectsSettingsTab(appState: appState)
                .tabItem {
                    Label("Projects", systemImage: "folder")
                }

            PushSettingsTab(appState: appState)
                .tabItem {
                    Label("Notifications", systemImage: "bell")
                }

            GeneralSettingsTab()
                .tabItem {
                    Label("General", systemImage: "gear")
                }
        }
        .frame(width: 520, height: 420)
    }
}

// MARK: - Server Settings Tab

/// Configures the HTTPS server: port, hostname, and TLS certificate paths.
struct ServerSettingsTab: View {
    @ObservedObject var appState: AppState

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

            // Hostname with auto-detect button
            HStack {
                TextField("Hostname:", text: $hostname)
                Button {
                    isDetectingHostname = true
                    // Auto-detect via TailscaleProviderProtocol
                    // Placeholder: hostname detection is wired up by the coordinator
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                        isDetectingHostname = false
                    }
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
                Button("Browse...") {
                    if let url = openFilePanel(title: "Select Certificate PEM", types: ["pem", "crt"]) {
                        certPath = url.path
                    }
                }
            }

            // TLS private key file path with browse button
            HStack {
                TextField("Private Key:", text: $keyPath)
                Button("Browse...") {
                    if let url = openFilePanel(title: "Select Private Key PEM", types: ["pem", "key"]) {
                        keyPath = url.path
                    }
                }
            }
        }
        .padding()
        .onAppear {
            port = String(appState.serverPort)
        }
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
                    if let index = appState.projects.firstIndex(where: { $0.id == savedProject.id }) {
                        appState.projects[index] = savedProject
                    } else {
                        appState.projects.append(savedProject)
                    }
                    showingProjectForm = false
                },
                onCancel: {
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

    @State private var config = PushNotificationConfig()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // --- Prowl ---
                PushProviderSection(
                    providerName: "Prowl",
                    providerType: .prowl,
                    enabled: $config.prowlEnabled
                ) {
                    TextField("API Key:", text: $config.prowlAPIKey)
                }

                Divider()

                // --- Pushover ---
                PushProviderSection(
                    providerName: "Pushover",
                    providerType: .pushover,
                    enabled: $config.pushoverEnabled
                ) {
                    TextField("App Token:", text: $config.pushoverAppToken)
                    TextField("User Key:", text: $config.pushoverUserKey)
                }

                Divider()

                // --- ntfy ---
                PushProviderSection(
                    providerName: "ntfy",
                    providerType: .ntfy,
                    enabled: $config.ntfyEnabled
                ) {
                    TextField("Server URL:", text: $config.ntfyServerURL)
                    TextField("Topic:", text: $config.ntfyTopic)
                }

                Divider()

                // --- Event Toggles ---
                GroupBox("Notify On") {
                    Toggle("Build Started", isOn: $config.notifyOnBuildStarted)
                    Toggle("Build Success", isOn: $config.notifyOnBuildSuccess)
                    Toggle("Build Failure", isOn: $config.notifyOnBuildFailure)
                }
            }
            .padding()
        }
    }
}

/// A reusable section for a single push notification provider.
/// Includes an enable toggle, configuration fields (injected via content closure),
/// a "Send Test" button, and a "?" help popover.
struct PushProviderSection<Content: View>: View {
    let providerName: String
    let providerType: PushProvider
    @Binding var enabled: Bool
    @ViewBuilder var content: Content

    @State private var showHelp = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                // Enable/disable toggle for this provider
                Toggle(providerName, isOn: $enabled)
                    .font(.headline)

                Spacer()

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

                // Send test notification button
                Button("Send Test") {
                    // Wired up by coordinator via PushNotifying protocol
                }
                .disabled(!enabled)
            }

            // Provider-specific configuration fields, dimmed when disabled
            if enabled {
                content
                    .textFieldStyle(.roundedBorder)
            }
        }
    }
}

// MARK: - General Settings Tab

/// General app preferences: launch-at-login toggle.
struct GeneralSettingsTab: View {
    @State private var launchAtLogin = false

    var body: some View {
        Form {
            // Launch at login toggle using SMAppService (macOS 13+)
            Toggle("Launch at Login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _ in
                    // SMAppService registration handled by the coordinator
                }
        }
        .padding()
    }
}
