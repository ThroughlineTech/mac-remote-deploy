// Utility buttons at the bottom of the menu bar popover: Import IPA,
// Setup Assistant, Settings, Quit. Extracted from MenuBarView in TKT-012.
import SwiftUI
import os

struct UtilitiesSection: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var serviceContainer: ServiceContainer
    @EnvironmentObject var buildManager: BuildManager
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(action: importIPA) {
                Label("Import IPA...", systemImage: "square.and.arrow.down")
                    .font(.subheadline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(action: openSetupAssistant) {
                Label("Setup Assistant", systemImage: "questionmark.circle")
                    .font(.subheadline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            SettingsLink {
                Label("Settings...", systemImage: "gear")
                    .font(.subheadline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .simultaneousGesture(TapGesture().onEnded {
                NSApp.activate()
                // TKT-033: force the settings window to front after it opens.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    NSApp.windows.first { $0.title == "Settings" || $0.identifier?.rawValue == "settings" }?
                        .orderFrontRegardless()
                }
            })

            Divider().padding(.vertical, 2)

            Button(action: { NSApplication.shared.terminate(nil) }) {
                Label("Quit", systemImage: "power")
                    .font(.subheadline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    /// Opens the Setup Assistant window and brings it to the front (TKT-033).
    /// Activates the app first, then forces the window above all others on the
    /// next runloop tick so it appears even when another app is in the foreground.
    private func openSetupAssistant() {
        NSApp.activate()
        openWindow(id: "setup-assistant")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            NSApp.windows.first { $0.title == "Setup Assistant" }?.orderFrontRegardless()
        }
    }

    /// Opens a file picker to import a pre-built .ipa file.
    /// Deferred to the next runloop turn so the MenuBarExtra popover can
    /// dismiss cleanly before the modal file picker appears (TKT-031).
    private func importIPA() {
        DispatchQueue.main.async { [self] in
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.init(filenameExtension: "ipa")!]
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.message = "Select an .ipa file to serve"

            guard panel.runModal() == .OK, let url = panel.url else { return }

            let slug = appState.selectedProject?.urlSlug ?? "imported"
            let serveDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                .appendingPathComponent("RemoteDeploy/serve").path

            do {
                let info = try serviceContainer.ipaImporter.importIPA(from: url, to: slug, serveDirectory: serveDir)
                buildManager.markImportSucceeded(ipaPath: "\(serveDir)/\(slug)/app.ipa")
                Logger.build.info("Imported IPA: \(info.bundleID, privacy: .public) v\(info.version, privacy: .public)")
            } catch {
                buildManager.markImportFailed(reason: error.localizedDescription)
            }
        }
    }
}
