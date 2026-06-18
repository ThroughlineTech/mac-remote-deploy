// Build controls section of the menu bar popover: build configuration picker,
// Build & Deploy / Cancel button, last build/install info, and View Build Log
// link. Extracted from MenuBarView in TKT-012.
//
// TKT-056 (Phase 3): trigger/cancel and all build state flow through the
// MenuBarClient (the menu bar's own API client) -- the same endpoints the web
// and iOS clients use -- instead of BuildManager/BuildCoordinator in process.
import SwiftUI
import RemoteDeployShared

struct BuildControlsSection: View {
    @EnvironmentObject var menuBarClient: MenuBarClient
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Configuration:", selection: $menuBarClient.buildConfiguration) {
                Text("Debug").tag("Debug")
                Text("Release").tag("Release")
            }
            .pickerStyle(.segmented)
            .font(.subheadline)

            if menuBarClient.isBuilding {
                Button(role: .destructive) {
                    cancelBuild()
                } label: {
                    HStack {
                        ProgressView()
                            .controlSize(.small)
                            .padding(.trailing, 2)
                        Text("Cancel Build")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            } else {
                Button {
                    performBuild()
                } label: {
                    HStack {
                        Image(systemName: "hammer.fill")
                        Text("Build & Deploy")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(menuBarClient.selectedProject == nil)
            }

            if let result = menuBarClient.lastBuildResult {
                lastBuildInfoView(result)
            }

            if let install = menuBarClient.lastInstall {
                lastInstallInfoView(install)
            }

            Button(action: {
                // TKT-033: activate + order front so the build log
                // window appears above other apps in LSUIElement mode.
                NSApp.activate()
                openWindow(id: "build-log")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    NSApp.windows.first { $0.title == "Build Log" }?.orderFrontRegardless()
                }
            }) {
                Label("View Build Log", systemImage: "doc.text")
                    .font(.subheadline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    /// Kicks off a build for the currently selected project via the API -- the
    /// same path the web and iOS clients use.
    func performBuild() {
        guard let project = menuBarClient.selectedProject else { return }
        Task {
            await menuBarClient.triggerBuild(
                projectID: project.id,
                configuration: menuBarClient.buildConfiguration
            )
        }
    }

    /// Cancels the in-progress build via the API.
    func cancelBuild() {
        guard let project = menuBarClient.selectedProject else { return }
        Task { await menuBarClient.cancelBuild(projectID: project.id) }
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
