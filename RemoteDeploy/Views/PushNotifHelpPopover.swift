import SwiftUI

/// Identifies which push notification provider to show help for.
enum PushProvider: String, CaseIterable {
    case prowl
    case pushover
    case ntfy
}

/// A reusable popover view that shows setup instructions for a specific
/// push notification provider. Displayed when the user taps the "?" button
/// next to a provider in Settings or the setup assistant.
struct PushNotifHelpPopover: View {
    /// Which provider to show instructions for.
    let provider: PushProvider

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)

            Divider()

            ForEach(steps, id: \.self) { step in
                HStack(alignment: .top, spacing: 8) {
                    Text("\u{2022}")
                        .foregroundColor(.secondary)
                    Text(step)
                        .font(.callout)
                }
            }

            if let linkText = linkText, let url = linkURL {
                Divider()
                Link(linkText, destination: url)
                    .font(.callout)
            }
        }
        .padding()
        .frame(width: 320)
    }

    // MARK: - Content per provider

    private var title: String {
        switch provider {
        case .prowl: return "Prowl Setup"
        case .pushover: return "Pushover Setup"
        case .ntfy: return "ntfy Setup"
        }
    }

    /// Step-by-step instructions for configuring each provider.
    private var steps: [String] {
        switch provider {
        case .prowl:
            return [
                "Install the Prowl app on your iPhone from the App Store.",
                "Create an account at prowlapp.com if you haven't already.",
                "Go to prowlapp.com/api_settings to generate an API key.",
                "Copy the API key and paste it in the field above.",
                "Tap 'Send Test' to verify it works."
            ]
        case .pushover:
            return [
                "Install the Pushover app on your iPhone from the App Store.",
                "Create an account at pushover.net.",
                "Note your User Key from the Pushover dashboard.",
                "Create a new application at pushover.net/apps/build.",
                "Name it 'RemoteDeploy' and copy the App Token.",
                "Paste both the App Token and User Key above.",
                "Tap 'Send Test' to verify it works."
            ]
        case .ntfy:
            return [
                "Install the ntfy app on your iPhone from the App Store.",
                "Either use the public server (ntfy.sh) or set up your own.",
                "Choose a topic name (e.g., 'remotedeploy').",
                "Subscribe to that topic in the ntfy app on your phone.",
                "Enter the server URL and topic name above.",
                "Tap 'Send Test' to verify it works."
            ]
        }
    }

    private var linkText: String? {
        switch provider {
        case .prowl: return "Open Prowl API Settings"
        case .pushover: return "Open Pushover Dashboard"
        case .ntfy: return "Open ntfy Documentation"
        }
    }

    private var linkURL: URL? {
        switch provider {
        case .prowl: return URL(string: "https://www.prowlapp.com/api_settings.php")
        case .pushover: return URL(string: "https://pushover.net/apps/build")
        case .ntfy: return URL(string: "https://docs.ntfy.sh/")
        }
    }
}
