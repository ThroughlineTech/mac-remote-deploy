// The primary menu bar popover. Composes four sections defined under
// RemoteDeploy/Views/MenuBar/: header, projects, build controls, utilities.
// TKT-012 decomposed the original 450-line monolith into focused subviews.
import SwiftUI
import Foundation
import RemoteDeployShared

/// The primary menu bar dropdown displayed when the user clicks the status item.
/// Provides a consolidated view of server status, project list, build controls,
/// and navigation to settings/setup. Actual UI lives in the four MenuBar/ subviews.
struct MenuBarView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var serviceContainer: ServiceContainer
    @EnvironmentObject var buildManager: BuildManager
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MenuBarHeaderSection()
            Divider().padding(.vertical, 4)
            ProjectsListSection()
            Divider().padding(.vertical, 4)
            BuildControlsSection()
            Divider().padding(.vertical, 4)
            UtilitiesSection()
        }
        .padding(8)
        .frame(width: 300)
        .onReceive(NotificationCenter.default.publisher(for: .openSetupAssistant)) { _ in
            openWindow(id: "setup-assistant")
        }
        .onReceive(NotificationCenter.default.publisher(for: .apiBuildRequested)) { notification in
            handleAPIBuildRequest(notification)
        }
        // TKT-007: surface boundary errors as an alert so the user sees what failed.
        .alert(
            appState.currentError?.errorDescription ?? "Error",
            isPresented: Binding(
                get: { appState.currentError != nil },
                set: { if !$0 { appState.currentError = nil } }
            ),
            presenting: appState.currentError
        ) { _ in
            Button("Dismiss", role: .cancel) { appState.currentError = nil }
        } message: { err in
            VStack(alignment: .leading) {
                if let reason = err.failureReason {
                    Text(reason)
                }
                if let suggestion = err.recoverySuggestion {
                    Text(suggestion)
                }
            }
        }
    }

    /// Handles a build request from the companion app API.
    /// Selects the requested project and triggers the same build flow as the UI button.
    private func handleAPIBuildRequest(_ notification: Notification) {
        guard let projectID = notification.userInfo?["projectID"] as? UUID else { return }
        appState.selectedProjectID = projectID
        if let config = notification.userInfo?["configuration"] as? String, !config.isEmpty {
            appState.buildConfiguration = config
        }
        // Delegate to BuildControlsSection.performBuild via the build manager directly.
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
