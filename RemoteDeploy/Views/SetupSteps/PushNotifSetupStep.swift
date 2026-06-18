import SwiftUI
import Foundation

// MARK: - Push Notification Setup Step

/// Step 4 of the setup wizard: optional push notification configuration.
/// Three expandable sections for Prowl, Pushover, and ntfy. Each section
/// has config fields, brief setup instructions, and a "Send Test" button.
/// The "Skip" action is prominently available via the parent navigation.
struct PushNotifSetupStep: View {
    @ObservedObject var appState: AppState
    // TKT-060 (Phase 6): no server object needed -- test notifications are sent
    // by locally-constructed notifier clients, and the active push config is
    // persisted to the server via the settings API when leaving this step.

    @State private var config = PushNotificationConfig()
    /// Error message from a failed test notification.
    @State private var testError: String?
    /// Whether a test notification is in progress.
    @State private var isSendingTest = false

    /// Tracks which provider section is currently expanded.
    @State private var expandedProvider: PushProvider?
    /// Tracks which provider's help popover is shown.
    @State private var showingHelpFor: PushProvider?

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

            // Display test error if any
            if let testError {
                Text(testError)
                    .font(.caption)
                    .foregroundColor(.red)
            }
        }
        .onAppear {
            // Load config from appState on appear
            config = appState.pushNotificationConfig
        }
        .onChange(of: config.prowlEnabled) { syncConfigToAppState() }
        .onChange(of: config.prowlAPIKey) { syncConfigToAppState() }
        .onChange(of: config.pushoverEnabled) { syncConfigToAppState() }
        .onChange(of: config.pushoverAppToken) { syncConfigToAppState() }
        .onChange(of: config.pushoverUserKey) { syncConfigToAppState() }
        .onChange(of: config.ntfyEnabled) { syncConfigToAppState() }
        .onChange(of: config.ntfyServerURL) { syncConfigToAppState() }
        .onChange(of: config.ntfyTopic) { syncConfigToAppState() }
    }

    /// Syncs the local config state back to appState.
    private func syncConfigToAppState() {
        appState.pushNotificationConfig = config
    }

    /// Sends a test notification for the given provider type.
    private func sendTestNotification(for providerType: PushProvider) {
        isSendingTest = true
        testError = nil

        Task {
            do {
                // Find the matching notifier and send test
                switch providerType {
                case .prowl:
                    let notifier = ProwlNotifier(apiKey: config.prowlAPIKey)
                    try await notifier.sendTest()
                case .pushover:
                    let notifier = PushoverNotifier(appToken: config.pushoverAppToken, userKey: config.pushoverUserKey)
                    try await notifier.sendTest()
                case .ntfy:
                    let notifier = NtfyNotifier(serverURL: config.ntfyServerURL, topic: config.ntfyTopic)
                    try await notifier.sendTest()
                }
            } catch {
                testError = "Test failed: \(error.localizedDescription)"
            }
            isSendingTest = false
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
                            sendTestNotification(for: type)
                        }
                        .disabled(!enabled.wrappedValue || isSendingTest)

                        Spacer()

                        // Setup instructions popover
                        Button {
                            showingHelpFor = type
                        } label: {
                            Label("Setup Instructions", systemImage: "questionmark.circle")
                                .font(.caption)
                        }
                        .buttonStyle(.borderless)
                        .popover(isPresented: Binding(
                            get: { showingHelpFor == type },
                            set: { if !$0 { showingHelpFor = nil } }
                        )) {
                            PushNotifHelpPopover(provider: type)
                        }
                    }
                    .padding(.top, 4)
                }
            }
            .padding(.vertical, 4)
        }
    }
}
