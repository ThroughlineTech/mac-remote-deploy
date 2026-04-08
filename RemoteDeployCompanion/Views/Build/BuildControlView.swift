// Build control view with status polling for real-time build progress.
// Uses the shared BuildManager so state is consistent with ProjectDetailView.
import SwiftUI
import RemoteDeployShared

/// Main build control interface with project picker and live status.
struct BuildControlView: View {
    @EnvironmentObject var connectionManager: ConnectionManager

    @State private var projects: [ProjectConfig] = []
    @State private var selectedProjectID: UUID?
    @State private var isLoadingProjects = true
    @State private var error: String?

    /// Timestamp captured when the build first transitions to building.
    /// Used to drive the elapsed-seconds display via TimelineView (TKT-017).
    @State private var buildStartedAt: Date?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Project picker and build button
                VStack(spacing: 12) {
                    if isLoadingProjects {
                        ProgressView("Loading projects...")
                            .padding(.vertical, 8)
                    } else if let error {
                        ContentUnavailableView {
                            Label("Couldn't load projects", systemImage: "exclamationmark.triangle")
                        } description: {
                            Text(error)
                        } actions: {
                            Button("Retry") {
                                Task { await loadProjects() }
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        .frame(maxHeight: 220)
                    } else if projects.isEmpty {
                        ContentUnavailableView {
                            Label("No Projects", systemImage: "folder.badge.questionmark")
                        } description: {
                            Text("Add projects on your Mac to see them here.")
                        }
                        .frame(maxHeight: 220)
                    } else {
                        Picker("Project", selection: $selectedProjectID) {
                            Text("Select Project").tag(nil as UUID?)
                            ForEach(projects) { project in
                                Text(project.name).tag(project.id as UUID?)
                            }
                        }
                        .pickerStyle(.menu)
                    }

                    HStack {
                        Button {
                            guard let id = selectedProjectID else { return }
                            connectionManager.buildManager.triggerBuild(projectID: id)
                        } label: {
                            Label("Build & Deploy", systemImage: "hammer.fill")
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(selectedProjectID == nil || connectionManager.buildManager.isBuilding)

                        if connectionManager.buildManager.isBuilding {
                            Button {
                                connectionManager.buildManager.cancelBuild()
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.red)
                            }
                            .buttonStyle(.bordered)
                        }
                    }

                    // Build status display
                    if let status = connectionManager.buildManager.buildStatus {
                        HStack(spacing: 8) {
                            if status.state == "building" {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Circle()
                                    .fill(statusColor(status.state))
                                    .frame(width: 10, height: 10)
                            }
                            // While building, show "Building... 12s" using a TimelineView
                            // that updates once per second from the captured start time.
                            if status.state == "building", let startedAt = buildStartedAt {
                                TimelineView(.periodic(from: startedAt, by: 1.0)) { context in
                                    let elapsed = Int(context.date.timeIntervalSince(startedAt))
                                    Text("Building... \(elapsed)s")
                                        .font(.subheadline)
                                        .fontWeight(.medium)
                                }
                            } else {
                                Text(statusLabel(status.state))
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                            }
                            if let message = status.message, status.state != "success" || status.state == "failure" {
                                Text(message)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        .padding(.vertical, 4)
                    }

                    if let error = connectionManager.buildManager.error {
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                }
                .padding()

                Divider()

                // Build log area
                BuildLogStreamView()
                    .environmentObject(connectionManager)
            }
            .navigationTitle("Build")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        connectionManager.webSocketClient.clearLog()
                    } label: {
                        Image(systemName: "trash")
                    }
                }
            }
        }
        .task {
            await loadProjects()
        }
        .onChange(of: connectionManager.buildManager.isBuilding) { _, newValue in
            // Capture/clear the build start time so the elapsed timer is accurate
            // from the moment the build kicks off.
            buildStartedAt = newValue ? Date() : nil
        }
    }

    private func loadProjects() async {
        guard let client = connectionManager.apiClient else {
            isLoadingProjects = false
            return
        }
        isLoadingProjects = true
        error = nil
        do {
            projects = try await client.listProjects()
            if selectedProjectID == nil, let first = projects.first {
                selectedProjectID = first.id
            }
        } catch {
            self.error = error.localizedDescription
        }
        isLoadingProjects = false
    }

    private func statusColor(_ state: String) -> Color {
        switch state {
        case "building": .orange
        case "success": .green
        case "failure": .red
        default: .gray
        }
    }

    private func statusLabel(_ state: String) -> String {
        switch state {
        case "building": "Building..."
        case "success": "Build Succeeded"
        case "failure": "Build Failed"
        case "idle": "Idle"
        default: state.capitalized
        }
    }
}

/// Displays the live build log from WebSocket.
struct BuildLogStreamView: View {
    @EnvironmentObject var connectionManager: ConnectionManager

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(connectionManager.webSocketClient.buildLogLines.enumerated()), id: \.offset) { index, line in
                        Text(line)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundColor(logLineColor(line))
                            .id(index)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }
            .background(Color(.systemGroupedBackground))
            .onChange(of: connectionManager.webSocketClient.buildLogLines.count) {
                if let last = connectionManager.webSocketClient.buildLogLines.indices.last {
                    withAnimation {
                        proxy.scrollTo(last, anchor: .bottom)
                    }
                }
            }
        }
    }

    private func logLineColor(_ line: String) -> Color {
        if line.contains("error:") { return .red }
        if line.contains("warning:") { return .yellow }
        return .primary
    }
}
