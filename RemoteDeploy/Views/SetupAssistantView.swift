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
    /// Dismissal action provided by the presenting view.
    var onDismiss: () -> Void

    /// Tracks the currently displayed step.
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
        .frame(width: 560, height: 480)
    }

    // MARK: - Step Indicator

    /// Horizontal row of numbered circles and labels showing progress through the wizard.
    private var stepIndicator: some View {
        HStack(spacing: 0) {
            ForEach(SetupStep.allCases, id: \.rawValue) { step in
                HStack(spacing: 4) {
                    // Numbered circle -- filled when current or past
                    ZStack {
                        Circle()
                            .fill(step.rawValue <= currentStep.rawValue ? Color.accentColor : Color.gray.opacity(0.3))
                            .frame(width: 24, height: 24)
                        Text("\(step.rawValue + 1)")
                            .font(.caption2.bold())
                            .foregroundColor(.white)
                    }

                    Text(step.title)
                        .font(.caption)
                        .foregroundColor(step == currentStep ? .primary : .secondary)
                }

                // Connecting line between steps
                if step != SetupStep.allCases.last {
                    Rectangle()
                        .fill(step.rawValue < currentStep.rawValue ? Color.accentColor : Color.gray.opacity(0.3))
                        .frame(height: 2)
                }
            }
        }
    }

    // MARK: - Step Content

    /// Routes to the appropriate sub-view for the current step.
    @ViewBuilder
    private var stepContent: some View {
        switch currentStep {
        case .tailscale:
            TailscaleSetupStep(appState: appState)
        case .certificate:
            CertificateSetupStep(appState: appState)
        case .project:
            ProjectSetupStep(appState: appState)
        case .pushNotifications:
            PushNotifSetupStep(appState: appState)
        case .complete:
            SetupCompleteStep(appState: appState)
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
                    onDismiss()
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
    private func goForward() {
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
