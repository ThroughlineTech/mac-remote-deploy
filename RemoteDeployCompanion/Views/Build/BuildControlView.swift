// Build control view with status polling for real-time build progress.
// Uses the shared BuildManager so state is consistent with ProjectDetailView.
import SwiftUI
import RemoteDeployShared

/// Main build control interface with project picker and live status.
struct BuildControlView: View {
    @EnvironmentObject var connectionManager: ConnectionManager
    @EnvironmentObject var buildManager: BuildManager
    @EnvironmentObject var webSocketClient: WebSocketClient

    @State private var projects: [ProjectConfig] = []
    @State private var selectedProjectID: UUID?
    @State private var isLoadingProjects = true
    @State private var error: String?

    /// Timestamp captured when the build first transitions to building.
    /// Used to drive the elapsed-seconds display via TimelineView (TKT-017).
    @State private var buildStartedAt: Date?

    /// Whether the build log disclosure is expanded. Collapsed by default and
    /// re-collapsed when a new build starts (TKT-046).
    @State private var isLogExpanded = false

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
                            buildManager.triggerBuild(projectID: id)
                        } label: {
                            Label("Build & Deploy", systemImage: "hammer.fill")
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(selectedProjectID == nil || buildManager.isBuilding)

                        if buildManager.isBuilding {
                            Button {
                                buildManager.cancelBuild()
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.red)
                            }
                            .buttonStyle(.bordered)
                        }
                    }

                    // Build status display
                    if let status = buildManager.buildStatus {
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

                    if let error = buildManager.error {
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                }
                .padding()

                Divider()

                // Build log header — always rendered, acts as the toggle for
                // the log body below. TKT-047 replaced the previous
                // DisclosureGroup because its collapsed content still
                // participated in layout and hit-testing on iOS, which caused
                // an invisible ScrollView to swallow taps over the tab bar.
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isLogExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: isLogExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Image(systemName: "doc.text.magnifyingglass")
                        Text("Build Log")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        if !webSocketClient.buildLogLines.isEmpty {
                            Text("(\(webSocketClient.buildLogLines.count) lines)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal)
                .padding(.vertical, 10)
                .accessibilityIdentifier("BuildLogToggle")

                // TKT-047: explicit conditional render. When collapsed, the
                // log view is NOT in the view tree at all (not just hidden),
                // so it cannot claim vertical space nor hit-test over the
                // tab bar. When expanded, the log is the only greedy child
                // and legitimately fills the remaining space.
                if isLogExpanded {
                    BuildLogStreamView()
                        .frame(maxHeight: .infinity)
                } else {
                    Spacer(minLength: 0)
                }
            }
            .navigationTitle("Build")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        webSocketClient.clearLog()
                    } label: {
                        Image(systemName: "trash")
                    }
                }
            }
        }
        .task {
            await loadProjects()
        }
        .onChange(of: buildManager.isBuilding) { _, newValue in
            // Capture/clear the build start time so the elapsed timer is accurate
            // from the moment the build kicks off.
            buildStartedAt = newValue ? Date() : nil
            // TKT-046: collapse the log at the start of each new build so the
            // primary action stays dominant. User can re-expand with one tap.
            if newValue {
                isLogExpanded = false
            }
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
    @EnvironmentObject var webSocketClient: WebSocketClient
    @EnvironmentObject var buildManager: BuildManager

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(webSocketClient.buildLogLines.enumerated()), id: \.offset) { index, line in
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
            .onChange(of: webSocketClient.buildLogLines.count) {
                // TKT-046: only auto-scroll while the build is active. Once
                // BuildManager flips isBuilding to false (via WebSocket
                // terminal frame or REST poll fallback), trailing log lines
                // no longer yank the viewport, so the user can review in
                // peace.
                guard buildManager.isBuilding else { return }
                if let last = webSocketClient.buildLogLines.indices.last {
                    withAnimation {
                        proxy.scrollTo(last, anchor: .bottom)
                    }
                }
            }
            .onChange(of: buildManager.isBuilding) { _, newValue in
                // TKT-046: when a new build starts, snap to the tail of the
                // log so the first streaming line is visible. Satisfies
                // "Starting a new build re-enables auto-scroll for that
                // build".
                guard newValue, let last = webSocketClient.buildLogLines.indices.last else { return }
                withAnimation {
                    proxy.scrollTo(last, anchor: .bottom)
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
