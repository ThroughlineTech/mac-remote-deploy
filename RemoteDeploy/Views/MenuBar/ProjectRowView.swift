// A single row in the menu bar's projects list. Extracted out of
// MenuBarView.swift in TKT-024 as part of the TKT-012 cleanup so
// MenuBarView fits under its 100-line ceiling.
import SwiftUI
import RemoteDeployShared

/// A single row in the projects list showing name and truncated path.
struct ProjectRowView: View {
    let project: ProjectConfig
    let isSelected: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(project.name)
                    .font(.subheadline)
                    .fontWeight(isSelected ? .semibold : .regular)
                Text(project.projectPath)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer()
            if isSelected {
                Image(systemName: "checkmark")
                    .font(.caption)
                    .foregroundColor(.accentColor)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}
