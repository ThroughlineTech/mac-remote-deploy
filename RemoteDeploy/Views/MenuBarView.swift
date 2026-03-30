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
    @ObservedObject var appState: AppState

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
                    .buttonStyle(.borderless)
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
                }
            }

            // Add project button
            Button {
                appState.showSettings = true
            } label: {
                Label("Add Project...", systemImage: "plus")
                    .font(.subheadline)
            }
            .buttonStyle(.borderless)
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
                // Build action handled by the app coordinator
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
            Button {
                appState.showBuildLog = true
            } label: {
                Label("View Build Log", systemImage: "doc.text")
                    .font(.subheadline)
            }
            .buttonStyle(.borderless)
            .disabled(appState.buildLog.isEmpty)
        }
    }

    // MARK: - Utility Section

    /// Import, setup, settings, and quit buttons.
    private var utilitySection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                // Import IPA via NSOpenPanel
            } label: {
                Label("Import IPA...", systemImage: "square.and.arrow.down")
                    .font(.subheadline)
            }
            .buttonStyle(.borderless)

            Button {
                appState.showSetupAssistant = true
            } label: {
                Label("Setup Guide", systemImage: "questionmark.circle")
                    .font(.subheadline)
            }
            .buttonStyle(.borderless)

            Button {
                appState.showSettings = true
            } label: {
                Label("Settings...", systemImage: "gear")
                    .font(.subheadline)
            }
            .buttonStyle(.borderless)

            Divider().padding(.vertical, 2)

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Label("Quit", systemImage: "power")
                    .font(.subheadline)
            }
            .buttonStyle(.borderless)
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
