// Utility buttons at the bottom of the menu bar popover: Import IPA,
// Setup Assistant, Settings, Quit. Extracted from MenuBarView in TKT-012.
//
// TKT-056 (Phase 3): the selected project comes from the MenuBarClient. IPA
// import is a local file action with no API endpoint, so it stays in-process
// (ipaImporter writes to the local serve directory); success/failure is surfaced
// via a desktop notification rather than BuildManager's status.
import SwiftUI
import os

struct UtilitiesSection: View {
    @EnvironmentObject var serviceContainer: ServiceContainer
    @EnvironmentObject var menuBarClient: MenuBarClient
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

            let slug = menuBarClient.selectedProject?.urlSlug ?? "imported"
            let serveDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                .appendingPathComponent("RemoteDeploy/serve").path

            do {
                let info = try serviceContainer.ipaImporter.importIPA(from: url, to: slug, serveDirectory: serveDir)
                serviceContainer.notificationManager.postNotification(
                    title: "IPA Imported",
                    body: "\(info.bundleID) v\(info.version) is ready to serve at /\(slug)/",
                    identifier: "ipa-import-\(slug)"
                )
                Logger.build.info("Imported IPA: \(info.bundleID, privacy: .public) v\(info.version, privacy: .public)")
            } catch {
                serviceContainer.notificationManager.postNotification(
                    title: "IPA Import Failed",
                    body: error.localizedDescription,
                    identifier: "ipa-import-failed"
                )
            }
        }
    }
}
