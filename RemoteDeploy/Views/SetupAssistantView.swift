import SwiftUI
import Foundation

// MARK: - Setup Step Enum

/// The five sequential steps of the setup wizard.
/// Raw values provide stable ordering for the step indicator.
enum SetupStep: Int, CaseIterable {
    case tailscale = 0
    case certificate = 1
    case project = 2
    case pushNotifications = 3
    case complete = 4

    /// Human-readable label shown in the step indicator.
    var title: String {
        switch self {
        case .tailscale: return "Tailscale"
        case .certificate: return "Certificate"
        case .project: return "Project"
        case .pushNotifications: return "Notifications"
        case .complete: return "Done"
        }
    }
}

// MARK: - Setup Assistant View

/// A multi-step setup wizard presented as a sheet.
/// Contains a step indicator at the top, the current step's content in the middle,
/// and navigation buttons (Back / Next / Skip / Done) at the bottom.
struct SetupAssistantView: View {
    @ObservedObject var appState: AppState
    // TKT-060 (Phase 6): the wizard drives setup through the API client, not
    // in-process server objects.
    @EnvironmentObject var menuBarClient: MenuBarClient
    @Environment(\.dismiss) private var dismiss
    /// Dismissal action provided by the presenting view.
    var onDismiss: () -> Void
    /// Called when the wizard completes to save settings and start the server.
    var onStartServer: () -> Void

    /// Tracks the currently displayed step. Always starts at the first step so
    /// the user sees the full wizard from the beginning on every open.
    @State private var currentStep: SetupStep = .tailscale

    var body: some View {
        VStack(spacing: 0) {
            // --- Step Indicator ---
            stepIndicator
                .padding(.vertical, 16)
                .padding(.horizontal, 24)

            Divider()

            // --- Step Content Area ---
            stepContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(24)

            Divider()

            // --- Navigation Buttons ---
            navigationButtons
                .padding(16)
        }
        .frame(width: 700, height: 700)
        .onAppear {
            currentStep = .tailscale
        }
    }

    // MARK: - Step Indicator

    /// Horizontal row of numbered circles showing progress, with the current step name below.
    private var stepIndicator: some View {
        VStack(spacing: 6) {
            HStack(spacing: 0) {
                ForEach(SetupStep.allCases, id: \.rawValue) { step in
                    // Numbered circle — filled when current or past, clickable to navigate
                    Button {
                        withAnimation { currentStep = step }
                    } label: {
                        ZStack {
                            Circle()
                                .fill(step.rawValue <= currentStep.rawValue ? Color.accentColor : Color.gray.opacity(0.3))
                                .frame(width: 28, height: 28)
                            if step.rawValue < currentStep.rawValue {
                                Image(systemName: "checkmark")
                                    .font(.caption2.bold())
                                    .foregroundColor(.white)
                            } else {
                                Text("\(step.rawValue + 1)")
                                    .font(.caption.bold())
                                    .foregroundColor(.white)
                            }
                        }
                    }
                    .buttonStyle(.plain)

                    // Connecting line between steps
                    if step != SetupStep.allCases.last {
                        Rectangle()
                            .fill(step.rawValue < currentStep.rawValue ? Color.accentColor : Color.gray.opacity(0.3))
                            .frame(height: 2)
                            .frame(maxWidth: 40)
                    }
                }
            }

            Text("Step \(currentStep.rawValue + 1): \(currentStep.title)")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Step Content

    /// Routes to the appropriate sub-view for the current step.
    @ViewBuilder
    private var stepContent: some View {
        switch currentStep {
        case .tailscale:
            TailscaleSetupStep(appState: appState)
                .environmentObject(menuBarClient)
        case .certificate:
            CertificateSetupStep(appState: appState)
                .environmentObject(menuBarClient)
        case .project:
            ProjectSetupStep(appState: appState)
                .environmentObject(menuBarClient)
        case .pushNotifications:
            PushNotifSetupStep(appState: appState)
        case .complete:
            SetupCompleteStep(appState: appState, onStartServer: onStartServer)
        }
    }

    // MARK: - Navigation Buttons

    /// Back, Skip, Next, and Done buttons appropriate for the current step.
    private var navigationButtons: some View {
        HStack {
            // Back button (hidden on the first step)
            if currentStep != .tailscale {
                Button("Back") {
                    withAnimation {
                        goBack()
                    }
                }
            }

            Spacer()

            // Skip button for the optional push-notifications step
            if currentStep == .pushNotifications {
                Button("Skip") {
                    withAnimation {
                        goForward()
                    }
                }
            }

            // Next or Done button
            if currentStep == .complete {
                Button("Done") {
                    // Save settings and start the server before dismissing
                    onStartServer()
                    onDismiss()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            } else {
                Button("Next") {
                    withAnimation {
                        goForward()
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: - Navigation Helpers

    /// Advances to the next step, clamped to the last step.
    /// Saves data from the current step before advancing.
    private func goForward() {
        // Persist push notification config to the server when leaving that step.
        // The server reconfigures its push notifiers on the settings write. TKT-060.
        if currentStep == .pushNotifications {
            let config = appState.pushNotificationConfig
            Task { await menuBarClient.applySettings { $0.pushNotificationConfig = config } }
        }
        if let next = SetupStep(rawValue: currentStep.rawValue + 1) {
            currentStep = next
        }
    }

    /// Returns to the previous step, clamped to the first step.
    private func goBack() {
        if let prev = SetupStep(rawValue: currentStep.rawValue - 1) {
            currentStep = prev
        }
    }
}
