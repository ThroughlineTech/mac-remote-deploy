import SwiftUI
import Foundation

// MARK: - App State

/// Central observable state for the entire app.
/// Published properties drive all SwiftUI view updates across the menu bar,
/// settings window, and setup assistant.
@MainActor
class AppState: ObservableObject {
    @Published var serverRunning = false
    @Published var tailscaleConnected = false
    @Published var serverURL = ""
    @Published var serverPort: Int = 8443
    @Published var projects: [ProjectConfig] = []
    @Published var selectedProjectID: UUID?
    @Published var buildStatus: BuildStatus = .idle
    @Published var lastBuildResult: BuildResult?
    @Published var lastInstall: InstallRecord?
    @Published var buildLog: String = ""
    @Published var showSetupAssistant = false
    @Published var showSettings = false
    @Published var showBuildLog = false
    @Published var buildConfiguration: String = "Release"
    /// Absolute path to the TLS certificate PEM file.
    @Published var certPath: String = ""
    /// Absolute path to the TLS private key PEM file.
    @Published var keyPath: String = ""
    /// The Tailscale MagicDNS hostname for this machine.
    @Published var hostname: String = ""
    /// Push notification provider configuration.
    @Published var pushNotificationConfig = PushNotificationConfig()

    /// Returns the currently selected project, if any.
    var selectedProject: ProjectConfig? {
        projects.first { $0.id == selectedProjectID }
    }
}

// MARK: - Menu Bar View

/// The primary menu bar dropdown displayed when the user clicks the status item.
/// Provides a consolidated view of server status, project list, build controls,
/// and navigation to settings/setup.
struct MenuBarView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var serviceContainer: ServiceContainer
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // --- Header ---
            headerSection

            Divider().padding(.vertical, 4)

            // --- Project List ---
            projectsSection

            Divider().padding(.vertical, 4)

            // --- Build Controls ---
            buildSection

            Divider().padding(.vertical, 4)

            // --- Utility Buttons ---
            utilitySection
        }
        .padding(8)
        .frame(width: 300)
        .onReceive(NotificationCenter.default.publisher(for: .openSetupAssistant)) { _ in
            openWindow(id: "setup-assistant")
        }
    }

    // MARK: - Header Section

    /// Server and Tailscale connection status indicators with the server URL.
    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Remote Deploy Server")
                .font(.headline)
                .padding(.bottom, 2)

            // Server running status with colored indicator dot
            HStack(spacing: 6) {
                Circle()
                    .fill(appState.serverRunning ? Color.green : Color.red)
                    .frame(width: 8, height: 8)
                Text(appState.serverRunning ? "Server Running" : "Server Stopped")
                    .font(.subheadline)
                Spacer()
                if appState.serverRunning {
                    Text("Port \(appState.serverPort)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            // Tailscale connection status with colored indicator dot
            HStack(spacing: 6) {
                Circle()
                    .fill(appState.tailscaleConnected ? Color.green : Color.red)
                    .frame(width: 8, height: 8)
                Text(appState.tailscaleConnected ? "Tailscale Connected" : "Tailscale Disconnected")
                    .font(.subheadline)
            }

            // Server URL display with copy button
            if !appState.serverURL.isEmpty {
                HStack {
                    // Truncate long URLs with ellipsis in the middle
                    Text(appState.serverURL)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer()

                    Button("Copy URL") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(appState.serverURL, forType: .string)
                    }
                    .font(.caption)
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Projects Section

    /// Lists all configured projects and a button to add new ones.
    private var projectsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            if appState.projects.isEmpty {
                Text("No projects configured")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.vertical, 2)
            } else {
                ForEach(appState.projects) { project in
                    ProjectRowView(
                        project: project,
                        isSelected: project.id == appState.selectedProjectID
                    )
                    .onTapGesture {
                        appState.selectedProjectID = project.id
                    }
                    .contextMenu {
                        Button("Remove Project") {
                            removeProject(project)
                        }
                    }
                }
            }

            // Add project button — opens Settings window
            SettingsLink {
                Label("Add Project...", systemImage: "plus")
                    .font(.subheadline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .simultaneousGesture(TapGesture().onEnded { NSApp.activate() })
            .padding(.top, 2)
        }
    }

    // MARK: - Build Section

    /// Build controls: configuration picker, build button, and last build/install info.
    private var buildSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Project picker shown when multiple projects exist
            if appState.projects.count > 1 {
                Picker("Project:", selection: $appState.selectedProjectID) {
                    ForEach(appState.projects) { project in
                        Text(project.name).tag(Optional(project.id))
                    }
                }
                .pickerStyle(.menu)
                .font(.subheadline)
            }

            // Build configuration picker (Debug / Release)
            Picker("Configuration:", selection: $appState.buildConfiguration) {
                Text("Debug").tag("Debug")
                Text("Release").tag("Release")
            }
            .pickerStyle(.segmented)
            .font(.subheadline)

            // Build & Deploy button -- disabled when no project is selected or build is in progress
            Button {
                performBuild()
            } label: {
                HStack {
                    if case .building = appState.buildStatus {
                        ProgressView()
                            .controlSize(.small)
                            .padding(.trailing, 2)
                        Text("Building...")
                    } else {
                        Image(systemName: "hammer.fill")
                        Text("Build & Deploy")
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(appState.selectedProject == nil || isBuildInProgress)

            // Last build result summary
            if let result = appState.lastBuildResult {
                lastBuildInfoView(result)
            }

            // Last install record summary
            if let install = appState.lastInstall {
                lastInstallInfoView(install)
            }

            // View build log button
            Button(action: { openWindow(id: "build-log") }) {
                Label("View Build Log", systemImage: "doc.text")
                    .font(.subheadline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Utility Section

    /// Import, setup, settings, and quit buttons.
    private var utilitySection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(action: importIPA) {
                Label("Import IPA...", systemImage: "square.and.arrow.down")
                    .font(.subheadline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(action: { openWindow(id: "setup-assistant") }) {
                Label("Setup Guide", systemImage: "questionmark.circle")
                    .font(.subheadline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            SettingsLink {
                Label("Settings...", systemImage: "gear")
                    .font(.subheadline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .simultaneousGesture(TapGesture().onEnded { NSApp.activate() })

            Divider().padding(.vertical, 2)

            Button(action: { NSApplication.shared.terminate(nil) }) {
                Label("Quit", systemImage: "power")
                    .font(.subheadline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Actions

    /// Removes a project from the store and app state.
    /// - Parameter project: The project to remove.
    private func removeProject(_ project: ProjectConfig) {
        try? serviceContainer.projectStore.delete(projectID: project.id)
        appState.projects.removeAll { $0.id == project.id }
        serviceContainer.deployServer.unregisterProject(slug: project.urlSlug)
        if appState.selectedProjectID == project.id {
            appState.selectedProjectID = appState.projects.first?.id
        }
        NotificationCenter.default.post(name: .saveSettingsRequested, object: nil)
    }

    /// Kicks off a build for the currently selected project.
    private func performBuild() {
        guard let project = appState.selectedProject else { return }

        // Update the project's build configuration from the picker
        var buildProject = project
        buildProject.buildConfiguration = appState.buildConfiguration

        Task {
            appState.buildStatus = .building(progress: "Starting build...")
            appState.buildLog = ""

            // Get the log stream BEFORE starting the build so the continuation is ready
            let logStream = serviceContainer.buildEngine.buildLogStream

            // Consume build log stream in a background task
            let logTask = Task {
                for await line in logStream {
                    await MainActor.run {
                        appState.buildLog += line + "\n"
                    }
                }
            }

            // Post build-started notification
            serviceContainer.notificationManager.notifyBuildStarted(projectName: project.name)

            let startTime = Date()
            let installURL = appState.serverURL + "/" + project.urlSlug + "/"

            do {
                let ipaPath = try await serviceContainer.buildEngine.build(project: buildProject)
                let endTime = Date()
                logTask.cancel()
                appState.buildStatus = .success(ipaPath: ipaPath)
                appState.lastBuildResult = BuildResult(
                    id: UUID(),
                    projectID: project.id,
                    success: true,
                    ipaPath: ipaPath,
                    errorSummary: nil,
                    buildLog: appState.buildLog,
                    startTime: startTime,
                    endTime: endTime,
                    version: nil,
                    buildNumber: nil
                )

                // Register project with deploy server and start server if needed
                serviceContainer.deployServer.registerProject(buildProject)
                serviceContainer.deployServer.setBaseURL(appState.serverURL)
                if !appState.serverRunning, !appState.certPath.isEmpty, !appState.keyPath.isEmpty {
                    do {
                        try await serviceContainer.deployServer.start(
                            port: appState.serverPort,
                            certPath: appState.certPath,
                            keyPath: appState.keyPath
                        )
                        appState.serverRunning = true
                    } catch {
                        print("Server failed to start after build: \(error)")
                    }
                }

                // Post success notification (local)
                serviceContainer.notificationManager.notifyBuildSuccess(
                    projectName: project.name,
                    installURL: installURL
                )

                // Send push notifications to configured providers
                await serviceContainer.sendPushNotification(
                    title: "Build Succeeded",
                    message: "\(project.name) is ready to install",
                    priority: .normal,
                    url: installURL
                )
            } catch {
                let endTime = Date()
                logTask.cancel()
                appState.buildStatus = .failure(error: error.localizedDescription)
                appState.lastBuildResult = BuildResult(
                    id: UUID(),
                    projectID: project.id,
                    success: false,
                    ipaPath: nil,
                    errorSummary: error.localizedDescription,
                    buildLog: appState.buildLog,
                    startTime: startTime,
                    endTime: endTime,
                    version: nil,
                    buildNumber: nil
                )

                // Post failure notification (local)
                serviceContainer.notificationManager.notifyBuildFailure(
                    projectName: project.name,
                    error: error.localizedDescription
                )

                // Send push notifications for failure
                await serviceContainer.sendPushNotification(
                    title: "Build Failed",
                    message: "\(project.name): \(error.localizedDescription)",
                    priority: .high,
                    url: nil
                )
            }
        }
    }

    /// Opens a file picker to import a pre-built .ipa file.
    private func importIPA() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "ipa")!]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.message = "Select an .ipa file to serve"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        // If we have a selected project, import into its slug directory
        let slug = appState.selectedProject?.urlSlug ?? "imported"
        let serveDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("RemoteDeploy/serve").path

        do {
            let info = try serviceContainer.ipaImporter.importIPA(from: url, to: slug, serveDirectory: serveDir)
            appState.buildStatus = .success(ipaPath: "\(serveDir)/\(slug)/app.ipa")
            print("Imported IPA: \(info.bundleID) v\(info.version)")
        } catch {
            appState.buildStatus = .failure(error: "Import failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Helpers

    /// True when a build is currently in progress.
    private var isBuildInProgress: Bool {
        if case .building = appState.buildStatus { return true }
        return false
    }

    /// Displays the last build result: time ago, and success/failure badge.
    private func lastBuildInfoView(_ result: BuildResult) -> some View {
        HStack(spacing: 4) {
            Image(systemName: result.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundColor(result.success ? .green : .red)
                .font(.caption)
            Text(result.success ? "Build succeeded" : "Build failed")
                .font(.caption)
            Spacer()
            Text(result.endTime, style: .relative)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }

    /// Displays the last install record: device IP and time ago.
    private func lastInstallInfoView(_ install: InstallRecord) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "arrow.down.circle.fill")
                .foregroundColor(.blue)
                .font(.caption)
            Text("Installed from \(install.sourceIP)")
                .font(.caption)
            Spacer()
            Text(install.timestamp, style: .relative)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - Project Row View

/// A single row in the projects list showing name and truncated path.
struct ProjectRowView: View {
    let project: ProjectConfig
    let isSelected: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(project.name)
                    .font(.subheadline)
                    .fontWeight(isSelected ? .semibold : .regular)
                Text(project.projectPath)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer()
            if isSelected {
                Image(systemName: "checkmark")
                    .font(.caption)
                    .foregroundColor(.accentColor)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}
