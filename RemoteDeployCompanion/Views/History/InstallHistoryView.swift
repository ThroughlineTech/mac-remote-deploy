// Displays the history of IPA downloads from the Mac server.
import SwiftUI
import RemoteDeployShared

/// Shows recent IPA install records.
struct InstallHistoryView: View {
    @EnvironmentObject var connectionManager: ConnectionManager

    @State private var installs: [InstallRecord] = []
    @State private var isLoading = true
    @State private var error: String?
    @State private var showClearAllConfirmation = false

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
                    List {
                        ForEach(installs) { record in
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
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    Task { await deleteInstall(record) }
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Installs")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if !installs.isEmpty {
                        Button(role: .destructive) {
                            showClearAllConfirmation = true
                        } label: {
                            Label("Clear All", systemImage: "trash")
                        }
                    }
                }
            }
            .confirmationDialog(
                "Clear All Installs",
                isPresented: $showClearAllConfirmation,
                titleVisibility: .visible
            ) {
                Button("Clear All", role: .destructive) {
                    Task { await clearAllInstalls() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will permanently remove all install records.")
            }
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

    /// Deletes a single install record from the server and removes it from the local list.
    private func deleteInstall(_ record: InstallRecord) async {
        guard let client = connectionManager.apiClient else { return }
        do {
            try await client.deleteInstall(id: record.id)
            withAnimation {
                installs.removeAll { $0.id == record.id }
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Deletes all install records from the server and clears the local list.
    private func clearAllInstalls() async {
        guard let client = connectionManager.apiClient else { return }
        do {
            try await client.deleteAllInstalls()
            withAnimation {
                installs.removeAll()
            }
        } catch {
            self.error = error.localizedDescription
        }
    }
}
