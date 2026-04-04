// Displays the history of IPA downloads from the Mac server.
import SwiftUI
import RemoteDeployShared

/// Shows recent IPA install records.
struct InstallHistoryView: View {
    @EnvironmentObject var connectionManager: ConnectionManager

    @State private var installs: [InstallRecord] = []
    @State private var isLoading = true

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Loading...")
                } else if installs.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "arrow.down.circle")
                            .font(.largeTitle)
                            .foregroundColor(.secondary)
                        Text("No Installs Yet")
                            .font(.headline)
                        Text("Install history will appear here after devices download IPAs.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding()
                } else {
                    List(installs) { record in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(record.projectName)
                                .font(.headline)
                            HStack {
                                Label(record.sourceIP, systemImage: "network")
                                Spacer()
                                Text(record.timestamp.formatted(date: .abbreviated, time: .shortened))
                            }
                            .font(.caption)
                            .foregroundColor(.secondary)

                            Text(record.userAgent)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            .navigationTitle("Installs")
            .refreshable {
                await loadInstalls()
            }
        }
        .task {
            await loadInstalls()
        }
    }

    private func loadInstalls() async {
        guard let client = connectionManager.apiClient else { return }
        isLoading = true
        do {
            installs = try await client.getInstalls()
        } catch {
            // Silently handle — the list just stays empty
        }
        isLoading = false
    }
}
