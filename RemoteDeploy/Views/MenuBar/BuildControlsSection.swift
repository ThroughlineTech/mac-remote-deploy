// Build controls section of the menu bar popover: project picker, build
// configuration picker, Build & Deploy button, last build/install info,
// and View Build Log link. Extracted from MenuBarView in TKT-012.
import SwiftUI
import RemoteDeployShared

struct BuildControlsSection: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var serviceContainer: ServiceContainer
    @EnvironmentObject var buildManager: BuildManager
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if appState.projects.count > 1 {
                Picker("Project:", selection: $appState.selectedProjectID) {
                    ForEach(appState.projects) { project in
                        Text(project.name).tag(project.id as UUID?)
                    }
                }
                .pickerStyle(.menu)
                .font(.subheadline)
            }

            Picker("Configuration:", selection: $appState.buildConfiguration) {
                Text("Debug").tag("Debug")
                Text("Release").tag("Release")
            }
            .pickerStyle(.segmented)
            .font(.subheadline)

            Button {
                performBuild()
            } label: {
                HStack {
                    if buildManager.isBuilding {
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
            .disabled(appState.selectedProject == nil || buildManager.isBuilding)

            if let result = buildManager.lastBuildResult {
                lastBuildInfoView(result)
            }

            if let install = appState.lastInstall {
                lastInstallInfoView(install)
            }

            Button(action: { openWindow(id: "build-log") }) {
                Label("View Build Log", systemImage: "doc.text")
                    .font(.subheadline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        // TKT-025: Keep the project picker's selection in sync with the
        // current projects list. If `selectedProjectID` holds a UUID that
        // no longer matches any project (project deleted, state loaded
        // out of sync, view re-rendered during a startup settle window),
        // normalize it to the first available project. Without this,
        // SwiftUI logs:
        //   Picker: the selection "Optional(...)" is invalid and does
        //   not have an associated tag, this will give undefined results.
        .onChange(of: appState.projects) { _, newProjects in
            if let id = appState.selectedProjectID,
               !newProjects.contains(where: { $0.id == id }) {
                appState.selectedProjectID = newProjects.first?.id
            } else if appState.selectedProjectID == nil, let first = newProjects.first {
                appState.selectedProjectID = first.id
            }
        }
    }

    /// Kicks off a build for the currently selected project via BuildManager.
    func performBuild() {
        guard let project = appState.selectedProject else { return }
        var buildProject = project
        buildProject.buildConfiguration = appState.buildConfiguration

        buildManager.triggerBuild(
            project: buildProject,
            serverURL: appState.serverURL,
            serverPort: appState.serverPort,
            certPath: appState.certPath,
            keyPath: appState.keyPath,
            serverRunning: appState.serverRunning,
            onServerStarted: { [appState] in
                appState.serverRunning = true
            }
        )
    }

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
