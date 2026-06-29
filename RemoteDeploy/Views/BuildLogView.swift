import SwiftUI
import Foundation
import RemoteDeployShared

// MARK: - Build Log View

/// Scrollable, color-coded build log output. Displayed as a sheet or standalone window.
/// Auto-scrolls to the bottom as new output arrives. Provides "Clear" and "Copy" buttons.
///
/// TKT-056 (Phase 3): the log streams live over the WebSocket via the
/// MenuBarClient, the same channel the web and iOS clients consume -- instead of
/// reading BuildManager's in-process accumulated log.
///
/// TKT-074: the live log content observes the WebSocket directly (see
/// `BuildLogContent`) so a streamed log line re-renders only this window, not
/// every view bound to MenuBarClient. Line coloring is memoized
/// (`BuildLogClassifierCache`) so a re-render no longer recolors the whole buffer.
struct BuildLogView: View {
    @EnvironmentObject var menuBarClient: MenuBarClient

    var body: some View {
        BuildLogContent(webSocket: menuBarClient.webSocket)
    }
}

// MARK: - Build Log Content

/// The toolbar + scrollable log body. Observes the WebSocket directly so live
/// `buildlog` frames re-render this window alone; `MenuBarClient` no longer fans
/// every WebSocket change out to the whole menu bar UI (TKT-074).
private struct BuildLogContent: View {
    @EnvironmentObject var menuBarClient: MenuBarClient
    @ObservedObject var webSocket: WebSocketClient

    /// Memoizes per-line classification across renders so the idle SwiftUI render
    /// loop -- and each streamed line -- no longer reclassifies the whole buffer.
    /// Held in `@State` (not `@StateObject`): the view re-renders from the
    /// WebSocket above, and this is a plain read-through cache SwiftUI need not
    /// observe.
    @State private var classifier = BuildLogClassifierCache()

    /// Anchor ID for programmatic scrolling to the bottom of the log.
    private let bottomAnchorID = "log-bottom"

    var body: some View {
        let lines = menuBarClient.buildLogLines
        let entries = classifier.classify(lines)

        VStack(spacing: 0) {
            logToolbar(lines: lines)

            Divider()

            logContent(entries: entries, lineCount: lines.count)
        }
        .frame(minWidth: 600, minHeight: 400)
    }

    // MARK: - Toolbar

    /// Top bar with title, clear button, and copy button.
    private func logToolbar(lines: [String]) -> some View {
        HStack {
            Text("Build Log")
                .font(.headline)

            Spacer()

            // Copy entire log to clipboard
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .disabled(lines.isEmpty)

            // Clear the log contents
            Button {
                webSocket.clearLog()
            } label: {
                Label("Clear", systemImage: "trash")
            }
            .disabled(lines.isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Log Content

    /// Scrollable text area that renders each log line with its precomputed color.
    /// Errors appear in red, warnings in orange, successes in green, and normal
    /// output in the default color.
    private func logContent(entries: [BuildLogClassifierCache.Entry], lineCount: Int) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    // Render each streamed log line; color is read from the memoized
                    // classification, not recomputed per render (TKT-074).
                    ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                        Text(entry.text)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(Self.color(for: entry.kind))
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
            .onChange(of: lineCount) {
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

    /// Maps a line's semantic kind to its display color.
    private static func color(for kind: BuildLogLineKind) -> Color {
        switch kind {
        case .error: return .red
        case .warning: return .orange
        case .success: return .green
        case .normal: return .primary
        }
    }
}
