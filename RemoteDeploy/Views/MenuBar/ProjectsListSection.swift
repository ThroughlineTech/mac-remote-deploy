// Projects section of the menu bar popover: list of configured projects
// and "Add Project..." button. Extracted from MenuBarView in TKT-012.
//
// TKT-056 (Phase 3): the project list, selection, and delete all flow through
// the MenuBarClient (the menu bar's own API client). AppState is used only for
// the cross-window navigation flag that tells the Settings window which tab to
// open -- pure UI routing, not backend data.
import SwiftUI
import RemoteDeployShared

struct ProjectsListSection: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var menuBarClient: MenuBarClient

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if menuBarClient.projects.isEmpty {
                Text("No projects configured")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.vertical, 2)
            } else {
                ForEach(menuBarClient.projects) { project in
                    ProjectRowView(
                        project: project,
                        isSelected: project.id == menuBarClient.selectedProjectID
                    )
                    .onTapGesture {
                        menuBarClient.selectedProjectID = project.id
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

    /// Removes a project via the API. The client refreshes its project list on
    /// success, which re-renders this section.
    private func removeProject(_ project: ProjectConfig) {
        Task { await menuBarClient.deleteProject(project.id) }
    }
}
