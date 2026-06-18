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

            SettingsLink {
                Label("Add Project...", systemImage: "plus")
                    .font(.subheadline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .simultaneousGesture(TapGesture().onEnded {
                appState.selectedSettingsTab = "projects"
                NSApp.activate()
            })
            .padding(.top, 2)
        }
    }

    /// Removes a project. TKT-055: write only the store; the .projectsDidChange
    /// observer refreshes appState.projects, re-syncs the deploy-server slug
    /// registry, and normalizes the selection.
    private func removeProject(_ project: RemoteDeployShared.ProjectConfig) {
        try? serviceContainer.projectStore.delete(projectID: project.id)
    }
}
