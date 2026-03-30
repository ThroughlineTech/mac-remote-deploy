import SwiftUI
import Foundation

// MARK: - Build Log View

/// Scrollable, color-coded build log output. Displayed as a sheet or standalone window.
/// Auto-scrolls to the bottom as new output arrives. Provides "Clear" and "Copy" buttons.
struct BuildLogView: View {
    @ObservedObject var appState: AppState

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
                NSPasteboard.general.setString(appState.buildLog, forType: .string)
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .disabled(appState.buildLog.isEmpty)

            // Clear the log contents
            Button {
                appState.buildLog = ""
            } label: {
                Label("Clear", systemImage: "trash")
            }
            .disabled(appState.buildLog.isEmpty)
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
                    // Split the log into lines and render each with color coding
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
            // Auto-scroll to bottom whenever the log text changes
            .onChange(of: appState.buildLog) { _ in
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

    /// Splits the full log string into individual lines.
    private var logLines: [String] {
        appState.buildLog.components(separatedBy: .newlines)
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
