// Displays the list of configured projects on the Mac server.
// Allows selecting a project and viewing its details.
import SwiftUI
import RemoteDeployShared

/// List of all projects configured on the Mac.
struct ProjectListView: View {
    @EnvironmentObject var connectionManager: ConnectionManager

    @State private var projects: [ProjectConfig] = []
    @State private var isLoading = true
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Loading projects...")
                } else if projects.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "folder.badge.questionmark")
                            .font(.largeTitle)
                            .foregroundColor(.secondary)
                        Text("No Projects")
                            .font(.headline)
                        Text("Add projects on your Mac to see them here.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                } else {
                    List(projects) { project in
                        NavigationLink(value: project) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(project.name)
                                    .font(.headline)
                                Text(project.bundleID)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                HStack {
                                    Label(project.buildConfiguration, systemImage: "hammer")
                                    Label(project.platform, systemImage: "desktopcomputer")
                                }
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    .navigationDestination(for: ProjectConfig.self) { project in
                        ProjectDetailView(project: project)
                            .environmentObject(connectionManager)
                    }
                }
            }
            .navigationTitle("Projects")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await loadProjects() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
            .refreshable {
                await loadProjects()
            }
        }
        .task {
            await loadProjects()
        }
    }

    private func loadProjects() async {
        guard let client = connectionManager.apiClient else { return }
        isLoading = true
        do {
            projects = try await client.listProjects()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }
}

/// Detail view for a single project with build trigger.
/// Uses the shared BuildManager so build state is consistent with the Build tab.
struct ProjectDetailView: View {
    @EnvironmentObject var connectionManager: ConnectionManager
    let project: ProjectConfig

    /// Observe the shared build manager
    @ObservedObject private var buildManager: BuildManager

    init(project: ProjectConfig) {
        self.project = project
        // This will be set properly via environmentObject, placeholder for init
        self._buildManager = ObservedObject(wrappedValue: BuildManager())
    }

    var body: some View {
        List {
            Section("Project Info") {
                LabeledContent("Name", value: project.name)
                LabeledContent("Bundle ID", value: project.bundleID)
                LabeledContent("Team ID", value: project.teamID)
                LabeledContent("Scheme", value: project.scheme)
                LabeledContent("Configuration", value: project.buildConfiguration)
                LabeledContent("Export Method", value: project.exportMethod)
                LabeledContent("Platform", value: project.platform)
                LabeledContent("URL Slug", value: project.urlSlug)
            }

            Section("Path") {
                Text(project.projectPath)
                    .font(.system(.caption, design: .monospaced))
            }

            Section {
                Button {
                    connectionManager.buildManager.triggerBuild(projectID: project.id)
                } label: {
                    HStack {
                        if connectionManager.buildManager.isBuilding && connectionManager.buildManager.buildingProjectID == project.id {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(buildButtonLabel)
                    }
                    .frame(maxWidth: .infinity)
                }
                .disabled(connectionManager.buildManager.isBuilding)

                if let status = connectionManager.buildManager.buildStatus,
                   connectionManager.buildManager.buildingProjectID == project.id {
                    HStack(spacing: 8) {
                        if status.state == "building" {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Circle()
                                .fill(statusColor(status.state))
                                .frame(width: 10, height: 10)
                        }
                        Text(statusLabel(status.state))
                            .font(.subheadline)
                            .fontWeight(.medium)
                        if let message = status.message, status.state == "failure" {
                            Text(message)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(2)
                        }
                    }
                }
            }
        }
        .navigationTitle(project.name)
    }

    private var buildButtonLabel: String {
        if connectionManager.buildManager.isBuilding && connectionManager.buildManager.buildingProjectID == project.id {
            return "Building..."
        }
        if connectionManager.buildManager.isBuilding {
            return "Build in Progress"
        }
        return "Build & Deploy"
    }

    private func statusColor(_ state: String) -> Color {
        switch state {
        case "building": .orange
        case "success": .green
        case "failure": .red
        default: .gray
        }
    }

    private func statusLabel(_ state: String) -> String {
        switch state {
        case "building": "Building..."
        case "success": "Build Succeeded"
        case "failure": "Build Failed"
        case "idle": "Idle"
        default: state.capitalized
        }
    }
}
