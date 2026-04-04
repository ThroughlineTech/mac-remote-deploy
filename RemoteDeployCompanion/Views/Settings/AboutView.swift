// About page for the RemoteDeploy Companion app.
// Shows app info, links to GitHub, Throughline Tech, and the deep dive article.
import SwiftUI

/// About page with app info and company branding.
struct AboutView: View {
    private let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    private let buildNumber = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"

    var body: some View {
        List {
            // App header
            Section {
                VStack(spacing: 16) {
                    Image("AboutIcon")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 100, height: 100)
                        .clipShape(RoundedRectangle(cornerRadius: 22))
                        .shadow(color: .black.opacity(0.15), radius: 8, y: 4)

                    VStack(spacing: 4) {
                        Text("RemoteDeploy")
                            .font(.title2)
                            .fontWeight(.bold)
                        Text("Companion")
                            .font(.title3)
                            .foregroundColor(.secondary)
                        Text("Version \(appVersion) (\(buildNumber))")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .listRowBackground(Color.clear)
            }

            // Description
            Section {
                Text("Build, sign, and deploy iOS apps to your devices from anywhere. RemoteDeploy runs on your Mac and this companion app gives you full remote control from your phone.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            // Links
            Section("Links") {
                Link(destination: URL(string: "https://github.com/danrichardson/mac-remote-deploy")!) {
                    HStack {
                        Image(systemName: "chevron.left.forwardslash.chevron.right")
                            .frame(width: 28)
                            .foregroundColor(.primary)
                        VStack(alignment: .leading) {
                            Text("GitHub")
                                .foregroundColor(.primary)
                            Text("Source code & documentation")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Image(systemName: "arrow.up.right.square")
                            .foregroundColor(.secondary)
                    }
                }

                Link(destination: URL(string: "https://www.throughlinetech.net/deep-dives/remotedeploy")!) {
                    HStack {
                        Image(systemName: "doc.text.magnifyingglass")
                            .frame(width: 28)
                            .foregroundColor(.primary)
                        VStack(alignment: .leading) {
                            Text("Deep Dive")
                                .foregroundColor(.primary)
                            Text("How RemoteDeploy was built")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Image(systemName: "arrow.up.right.square")
                            .foregroundColor(.secondary)
                    }
                }
            }

            // Company
            Section("Made by") {
                Link(destination: URL(string: "https://www.throughlinetech.net")!) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Throughline Tech, LLC")
                                .font(.headline)
                                .foregroundColor(.primary)
                            Text("throughlinetech.net")
                                .font(.caption)
                                .foregroundColor(.accentColor)
                        }
                        Spacer()
                        Image(systemName: "arrow.up.right.square")
                            .foregroundColor(.secondary)
                    }
                }
            }

            // Tech credits
            Section("Built with") {
                VStack(alignment: .leading, spacing: 8) {
                    creditRow("SwiftUI & SwiftNIO", detail: "Apple frameworks")
                    creditRow("Tailscale", detail: "Secure networking")
                    creditRow("Let's Encrypt", detail: "TLS certificates")
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }
        }
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func creditRow(_ name: String, detail: String) -> some View {
        HStack {
            Text(name)
                .fontWeight(.medium)
                .foregroundColor(.primary)
            Spacer()
            Text(detail)
        }
    }
}
