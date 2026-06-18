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
    @EnvironmentObject var serviceContainer: ServiceContainer
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
            // TKT-030: trigger a fresh Tailscale status check each time the
            // popover appears so the indicator is never stale from the
            // 10-second poll gap. Posts a notification handled by AppDelegate,
            // keeping the view decoupled from the delegate. Runs post-layout
            // (not during body evaluation) to avoid TKT-021 layout recursion.
            NotificationCenter.default.post(name: .refreshTailscaleStatus, object: nil)
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
