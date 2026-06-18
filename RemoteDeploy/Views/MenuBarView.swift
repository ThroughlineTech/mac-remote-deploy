// The primary menu bar popover. Composes five sections defined under
// RemoteDeploy/Views/MenuBar/: header, server status, projects, build
// controls, utilities. TKT-012 decomposed the original 450-line monolith;
// TKT-024 finished the decomposition (split header → ServerStatusSection
// and extracted ProjectRowView into its own file) to hit the 5-subview,
// <100-line bar.
import SwiftUI
import Foundation
import RemoteDeployShared

/// The primary menu bar dropdown displayed when the user clicks the status item.
/// Provides a consolidated view of server status, project list, build controls,
/// and navigation to settings/setup. Actual UI lives in the five MenuBar/ subviews.
struct MenuBarView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var menuBarClient: MenuBarClient
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MenuBarHeaderSection()
            ServerStatusSection()
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
            // TKT-033: activate + order front so the setup assistant
            // window appears above other apps at launch.
            NSApp.activate()
            openWindow(id: "setup-assistant")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                NSApp.windows.first { $0.title == "Setup Assistant" }?.orderFrontRegardless()
            }
        }
        .task {
            // TKT-030 / TKT-060 (Phase 6): force an immediate client refresh each
            // time the popover appears so status/projects are never stale from the
            // poll gap. The server owns the Tailscale CLI; the menu bar just reads
            // its status endpoint via the client.
            menuBarClient.refreshNow()
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
}
