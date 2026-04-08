// Displays the history of IPA downloads from the Mac server.
import SwiftUI
import RemoteDeployShared

/// Shows recent IPA install records.
struct InstallHistoryView: View {
    @EnvironmentObject var connectionManager: ConnectionManager

    @State private var installs: [InstallRecord] = []
    @State private var isLoading = true
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Loading...")
                } else if let error {
                    ContentUnavailableView {
                        Label("Couldn't load installs", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(error)
                    } actions: {
                        Button("Retry") {
                            Task { await loadInstalls() }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } else if installs.isEmpty {
                    ContentUnavailableView {
                        Label("No Installs Yet", systemImage: "arrow.down.circle")
                    } description: {
                        Text("Install history will appear here after devices download IPAs.")
                    }
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
        error = nil
        do {
            installs = try await client.getInstalls()
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }
}
