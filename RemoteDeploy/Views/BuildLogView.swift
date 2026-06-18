import SwiftUI
import Foundation

// MARK: - Build Log View

/// Scrollable, color-coded build log output. Displayed as a sheet or standalone window.
/// Auto-scrolls to the bottom as new output arrives. Provides "Clear" and "Copy" buttons.
///
/// TKT-056 (Phase 3): the log streams live over the WebSocket via the
/// MenuBarClient, the same channel the web and iOS clients consume -- instead of
/// reading BuildManager's in-process accumulated log.
struct BuildLogView: View {
    @EnvironmentObject var menuBarClient: MenuBarClient

    /// Anchor ID for programmatic scrolling to the bottom of the log.
    private let bottomAnchorID = "log-bottom"

    var body: some View {
        VStack(spacing: 0) {
            // --- Toolbar ---
            logToolbar

            Divider()

            // --- Log Content ---
            logContent
        }
        .frame(minWidth: 600, minHeight: 400)
    }

    // MARK: - Toolbar

    /// Top bar with title, clear button, and copy button.
    private var logToolbar: some View {
        HStack {
            Text("Build Log")
                .font(.headline)

            Spacer()

            // Copy entire log to clipboard
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(logLines.joined(separator: "\n"), forType: .string)
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .disabled(logLines.isEmpty)

            // Clear the log contents
            Button {
                menuBarClient.webSocket.clearLog()
            } label: {
                Label("Clear", systemImage: "trash")
            }
            .disabled(logLines.isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Log Content

    /// Scrollable text area that renders each log line with basic color coding.
    /// Errors appear in red, warnings in orange, and normal output in the default color.
    private var logContent: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    // Render each streamed log line with color coding
                    ForEach(Array(logLines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(colorForLine(line))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 1)
                    }

                    // Invisible anchor at the bottom for auto-scroll
                    Color.clear
                        .frame(height: 1)
                        .id(bottomAnchorID)
                }
                .padding(.vertical, 8)
            }
            .background(Color(nsColor: .textBackgroundColor))
            // Auto-scroll to bottom whenever a new line arrives
            .onChange(of: logLines.count) {
                withAnimation {
                    proxy.scrollTo(bottomAnchorID, anchor: .bottom)
                }
            }
            .onAppear {
                proxy.scrollTo(bottomAnchorID, anchor: .bottom)
            }
        }
    }

    // MARK: - Helpers

    /// The live log lines streamed over the WebSocket.
    private var logLines: [String] {
        menuBarClient.buildLogLines
    }

    /// Returns a color based on the content of a log line.
    /// Lines containing "error" are red, "warning" are orange, others are default.
    private func colorForLine(_ line: String) -> Color {
        let lower = line.lowercased()
        if lower.contains("error:") || lower.contains("fatal") {
            return .red
        } else if lower.contains("warning:") {
            return .orange
        } else if lower.contains("build succeeded") || lower.contains("** build succeeded **") {
            return .green
        } else {
            return .primary
        }
    }
}
