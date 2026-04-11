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

    /// Most-recent install timestamp keyed by project name. Used to render
    /// "Last installed N hours ago" under each project row (TKT-017).
    /// We use install records as a proxy for "last activity" since the build
    /// history endpoint is still a stub until TKT-008 ships.
    @State private var lastInstallByProjectName: [String: Date] = [:]

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Loading projects...")
                } else if let error {
                    ContentUnavailableView {
                        Label("Couldn't load projects", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(error)
                    } actions: {
                        Button("Retry") {
                            Task { await loadProjects() }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } else if projects.isEmpty {
                    ContentUnavailableView {
                        Label("No Projects", systemImage: "folder.badge.questionmark")
                    } description: {
                        Text("Add projects on your Mac to see them here.")
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
                                if let lastInstall = lastInstallByProjectName[project.name] {
                                    Text("Last installed \(lastInstall, format: .relative(presentation: .named))")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    .navigationDestination(for: ProjectConfig.self) { project in
                        ProjectDetailView(buildManager: connectionManager.buildManager, project: project)
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
        error = nil
        do {
            projects = try await client.listProjects()
            // Best-effort: also fetch recent installs to populate the per-project
            // "last installed" timestamps. Don't fail the whole load if this fails.
            if let installs = try? await client.getInstalls() {
                var byName: [String: Date] = [:]
                for record in installs {
                    if let existing = byName[record.projectName], existing > record.timestamp {
                        continue
                    }
                    byName[record.projectName] = record.timestamp
                }
                lastInstallByProjectName = byName
            }
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }
}

/// Detail view for a single project with build trigger and live progress.
/// Uses the shared BuildManager so build state is consistent with the Build tab.
struct ProjectDetailView: View {
    @EnvironmentObject var connectionManager: ConnectionManager
    @ObservedObject var buildManager: BuildManager
    let project: ProjectConfig

    /// Timestamp captured when the build starts, drives the elapsed timer.
    @State private var buildStartedAt: Date?

    /// Whether this project is the one currently building.
    private var isThisProjectBuilding: Bool {
        buildManager.isBuilding
            && buildManager.buildingProjectID == project.id
    }

    /// The build status for this project (only when it's the active build).
    private var projectStatus: BuildStatusInfo? {
        guard buildManager.buildingProjectID == project.id else { return nil }
        return buildManager.buildStatus
    }

    /// Constructs the OTA install page URL from the server base URL and project slug.
    private var installURL: URL? {
        guard let base = connectionManager.apiClient?.baseURL else { return nil }
        return base.appendingPathComponent(project.urlSlug)
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
            }

            Section("Path") {
                Text(project.projectPath)
                    .font(.system(.caption, design: .monospaced))
            }

            // MARK: - Build Action
            Section {
                Button {
                    buildManager.triggerBuild(projectID: project.id)
                } label: {
                    HStack {
                        if isThisProjectBuilding {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(buildButtonLabel)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(buildManager.isBuilding)

                if isThisProjectBuilding {
                    Button(role: .destructive) {
                        buildManager.cancelBuild()
                    } label: {
                        Label("Cancel Build", systemImage: "xmark.circle")
                            .frame(maxWidth: .infinity)
                    }
                }
            }

            // MARK: - Build Progress
            if let status = projectStatus {
                Section("Build Status") {
                    switch status.state {
                    case "building":
                        // Prominent progress with elapsed timer
                        HStack(spacing: 12) {
                            ProgressView()
                            if let startedAt = buildStartedAt {
                                TimelineView(.periodic(from: startedAt, by: 1.0)) { context in
                                    let elapsed = Int(context.date.timeIntervalSince(startedAt))
                                    Text("Building... \(elapsed)s")
                                        .font(.subheadline)
                                        .fontWeight(.medium)
                                }
                            } else {
                                Text("Building...")
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                            }
                        }

                        if let message = status.message {
                            Text(message)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                    case "success":
                        // Green success banner with install link
                        Label("Build Succeeded", systemImage: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .font(.headline)

                        if let url = installURL {
                            Link(destination: url) {
                                Label("Open Install Page", systemImage: "arrow.down.circle.fill")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.green)
                        }

                    case "failure":
                        // Red error banner with details
                        Label("Build Failed", systemImage: "xmark.circle.fill")
                            .foregroundColor(.red)
                            .font(.headline)

                        if let message = status.message {
                            Text(message)
                                .font(.caption)
                                .foregroundColor(.red)
                        }

                    default:
                        HStack(spacing: 8) {
                            Circle()
                                .fill(statusColor(status.state))
                                .frame(width: 10, height: 10)
                            Text(status.state.capitalized)
                                .font(.subheadline)
                        }
                    }

                    // "View Build Log" navigates to the Build tab
                    Button {
                        connectionManager.selectedTab = 1
                    } label: {
                        Label("View Build Log", systemImage: "text.alignleft")
                    }
                }
            }

            if let error = buildManager.error {
                Section {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                }
            }
        }
        .navigationTitle(project.name)
        .onChange(of: buildManager.isBuilding) { _, newValue in
            // Capture/clear the build start time for the elapsed timer.
            if newValue && buildManager.buildingProjectID == project.id {
                buildStartedAt = Date()
            } else if !newValue {
                // Keep buildStartedAt around after build finishes so success/failure
                // UI stays visible; only clear when a new build starts.
            }
        }
    }

    private var buildButtonLabel: String {
        if isThisProjectBuilding {
            return "Building..."
        }
        if buildManager.isBuilding {
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
}
