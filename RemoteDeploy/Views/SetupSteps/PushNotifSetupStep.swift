import SwiftUI
import Foundation

// MARK: - Push Notification Setup Step

/// Step 4 of the setup wizard: optional push notification configuration.
/// Three expandable sections for Prowl, Pushover, and ntfy. Each section
/// has config fields, brief setup instructions, and a "Send Test" button.
/// The "Skip" action is prominently available via the parent navigation.
struct PushNotifSetupStep: View {
    @ObservedObject var appState: AppState

    @State private var config = PushNotificationConfig()

    /// Tracks which provider section is currently expanded.
    @State private var expandedProvider: PushProvider?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Push Notifications")
                .font(.title2.bold())

            Text("Optionally receive push notifications on your phone when builds complete. You can configure this later in Settings.")
                .font(.body)
                .foregroundColor(.secondary)

            // Prominent skip hint
            Label("This step is optional -- use Skip below if you don't need push notifications.", systemImage: "info.circle")
                .font(.subheadline)
                .foregroundColor(.secondary)

            Divider()

            ScrollView {
                VStack(spacing: 12) {
                    // --- Prowl ---
                    providerDisclosure(
                        type: .prowl,
                        name: "Prowl",
                        description: "Push notifications for iOS via the Prowl app.",
                        enabled: $config.prowlEnabled
                    ) {
                        TextField("API Key:", text: $config.prowlAPIKey)
                            .textFieldStyle(.roundedBorder)
                    }

                    // --- Pushover ---
                    providerDisclosure(
                        type: .pushover,
                        name: "Pushover",
                        description: "Cross-platform push via the Pushover service.",
                        enabled: $config.pushoverEnabled
                    ) {
                        TextField("App Token:", text: $config.pushoverAppToken)
                            .textFieldStyle(.roundedBorder)
                        TextField("User Key:", text: $config.pushoverUserKey)
                            .textFieldStyle(.roundedBorder)
                    }

                    // --- ntfy ---
                    providerDisclosure(
                        type: .ntfy,
                        name: "ntfy",
                        description: "Open-source push notifications via ntfy.sh or self-hosted.",
                        enabled: $config.ntfyEnabled
                    ) {
                        TextField("Server URL:", text: $config.ntfyServerURL)
                            .textFieldStyle(.roundedBorder)
                        TextField("Topic:", text: $config.ntfyTopic)
                            .textFieldStyle(.roundedBorder)
                    }
                }
            }
        }
    }

    // MARK: - Provider Disclosure Group

    /// An expandable section for a single push provider with enable toggle,
    /// config fields, and test button.
    private func providerDisclosure<Content: View>(
        type: PushProvider,
        name: String,
        description: String,
        enabled: Binding<Bool>,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                // Header: toggle + name + expand/collapse
                HStack {
                    Toggle(isOn: enabled) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(name).font(.headline)
                            Text(description)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    Spacer()

                    // Expand/collapse chevron
                    Button {
                        withAnimation {
                            expandedProvider = expandedProvider == type ? nil : type
                        }
                    } label: {
                        Image(systemName: expandedProvider == type ? "chevron.up" : "chevron.down")
                    }
                    .buttonStyle(.borderless)
                }

                // Expanded content: config fields + test button
                if expandedProvider == type {
                    content()

                    HStack {
                        // Send test notification button
                        Button("Send Test") {
                            // Wired to PushNotifying.sendTest() by the coordinator
                        }
                        .disabled(!enabled.wrappedValue)

                        Spacer()

                        // Setup instructions link
                        Button {
                            // Could open an inline help popover or external URL
                        } label: {
                            Label("Setup Instructions", systemImage: "questionmark.circle")
                                .font(.caption)
                        }
                        .buttonStyle(.borderless)
                    }
                    .padding(.top, 4)
                }
            }
            .padding(.vertical, 4)
        }
    }
}
