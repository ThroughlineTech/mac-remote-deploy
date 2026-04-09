// Projects section of the menu bar popover: list of configured projects
// and "Add Project..." button. Extracted from MenuBarView in TKT-012.
import SwiftUI

struct ProjectsListSection: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var serviceContainer: ServiceContainer

    var body: some View {
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

            Button {
                appState.selectedSettingsTab = "projects"
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                NSApp.activate()
            } label: {
                Label("Add Project...", systemImage: "plus")
                    .font(.subheadline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, 2)
        }
    }

    /// Removes a project from the store, app state, and deploy server.
    private func removeProject(_ project: RemoteDeployShared.ProjectConfig) {
        try? serviceContainer.projectStore.delete(projectID: project.id)
        appState.projects.removeAll { $0.id == project.id }
        serviceContainer.deployServer.unregisterProject(slug: project.urlSlug)
        if appState.selectedProjectID == project.id {
            appState.selectedProjectID = appState.projects.first?.id
        }
        NotificationCenter.default.post(name: .saveSettingsRequested, object: nil)
    }
}
