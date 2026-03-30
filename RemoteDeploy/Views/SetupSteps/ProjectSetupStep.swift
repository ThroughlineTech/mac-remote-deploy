import SwiftUI
import Foundation

// MARK: - Project Setup Step

/// Step 3 of the setup wizard: allows the user to select an Xcode project via
/// file picker or drag-and-drop, auto-detects available schemes, and collects
/// bundle ID and team ID.
struct ProjectSetupStep: View {
    @ObservedObject var appState: AppState
    @EnvironmentObject var serviceContainer: ServiceContainer

    /// The project path selected by the user.
    @State private var projectPath: String = ""
    /// Human-readable project name.
    @State private var projectName: String = ""
    /// Detected Xcode schemes available in the project.
    @State private var detectedSchemes: [String] = []
    /// The scheme the user selected from the detected list.
    @State private var selectedScheme: String = ""
    /// iOS bundle identifier.
    @State private var bundleID: String = ""
    /// Apple Developer Team ID.
    @State private var teamID: String = ""
    /// Whether scheme detection is running.
    @State private var isDetectingSchemes = false
    /// Whether a file is being dragged over the drop zone.
    @State private var isDragTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Project")
                .font(.title2.bold())

            Text("Select an Xcode project or workspace. RemoteDeploy will build it, export an IPA, and serve it for OTA installation.")
                .font(.body)
                .foregroundColor(.secondary)

            Divider()

            // --- Drag-and-drop zone / file picker ---
            dropZone

            // --- Project details form (shown after a path is selected) ---
            if !projectPath.isEmpty {
                projectDetailsForm
            }

            Spacer()
        }
        .onDisappear {
            // Save the project when the user navigates away from this step
            saveProject()
        }
    }

    // MARK: - Drop Zone

    /// A rounded rectangle that accepts dragged .xcodeproj / .xcworkspace bundles
    /// or presents an NSOpenPanel on click.
    private var dropZone: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(
                    isDragTargeted ? Color.accentColor : Color.gray.opacity(0.4),
                    style: StrokeStyle(lineWidth: 2, dash: [6])
                )
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(isDragTargeted ? Color.accentColor.opacity(0.05) : Color.clear)
                )
                .frame(height: 80)

            if projectPath.isEmpty {
                VStack(spacing: 4) {
                    Image(systemName: "folder.badge.plus")
                        .font(.title2)
                        .foregroundColor(.secondary)
                    Text("Drag Xcode project here or click to browse")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            } else {
                HStack {
                    Image(systemName: "folder.fill")
                        .foregroundColor(.accentColor)
                    Text(projectPath)
                        .font(.subheadline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Change") {
                        browseForProject()
                    }
                    .font(.caption)
                }
                .padding(.horizontal, 12)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isDragTargeted) { providers in
            handleDrop(providers)
        }
        .onTapGesture {
            if projectPath.isEmpty {
                browseForProject()
            }
        }
    }

    // MARK: - Project Details Form

    /// Form fields for project name, scheme selection, bundle ID, and team ID.
    private var projectDetailsForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Project name
            TextField("Project Name:", text: $projectName)
                .textFieldStyle(.roundedBorder)

            // Scheme picker -- populated by auto-detection
            HStack {
                if isDetectingSchemes {
                    ProgressView().controlSize(.small)
                    Text("Detecting schemes...")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                } else if detectedSchemes.isEmpty {
                    Text("No schemes detected")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Button("Retry") {
                        detectSchemes()
                    }
                    .font(.caption)
                } else {
                    Picker("Scheme:", selection: $selectedScheme) {
                        ForEach(detectedSchemes, id: \.self) { scheme in
                            Text(scheme).tag(scheme)
                        }
                    }
                }
            }

            // Bundle ID
            TextField("Bundle ID:", text: $bundleID)
                .textFieldStyle(.roundedBorder)

            // Team ID
            TextField("Team ID:", text: $teamID)
                .textFieldStyle(.roundedBorder)
        }
    }

    // MARK: - Actions

    /// Opens an NSOpenPanel to select an .xcodeproj or .xcworkspace.
    private func browseForProject() {
        let panel = NSOpenPanel()
        panel.title = "Select Xcode Project or Workspace"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false

        if panel.runModal() == .OK, let url = panel.url {
            applySelectedPath(url)
        }
    }

    /// Handles a file drop on the drop zone.
    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: "public.file-url") { item, _ in
            if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                DispatchQueue.main.async {
                    applySelectedPath(url)
                }
            }
        }
        return true
    }

    /// Sets the project path from the selected URL and kicks off scheme detection.
    private func applySelectedPath(_ url: URL) {
        projectPath = url.path
        // Derive a default name from the directory/file name
        let name = url.deletingPathExtension().lastPathComponent
        if projectName.isEmpty {
            projectName = name
        }
        detectSchemes()
    }

    /// Runs scheme detection via BuildEngineProtocol.detectSchemes.
    /// Uses the injected build engine from serviceContainer.
    private func detectSchemes() {
        isDetectingSchemes = true
        detectedSchemes = []

        Task {
            do {
                let schemes = try await serviceContainer.buildEngine.detectSchemes(at: projectPath)
                await MainActor.run {
                    detectedSchemes = schemes
                    if let first = schemes.first, selectedScheme.isEmpty {
                        selectedScheme = first
                    }
                    isDetectingSchemes = false
                }
            } catch {
                await MainActor.run {
                    isDetectingSchemes = false
                }
                print("Scheme detection failed: \(error.localizedDescription)")
            }
        }
    }

    /// Saves the configured project to the project store and appState.
    /// Called automatically when the user navigates forward from this step.
    func saveProject() {
        guard !projectName.isEmpty, !projectPath.isEmpty else { return }

        var project = ProjectConfig(name: projectName, projectPath: projectPath)
        project.scheme = selectedScheme
        project.bundleID = bundleID
        project.teamID = teamID

        do {
            try serviceContainer.projectStore.save(project: project)
        } catch {
            print("Failed to save project: \(error.localizedDescription)")
        }

        // Add to appState if not already present
        if !appState.projects.contains(where: { $0.id == project.id }) {
            appState.projects.append(project)
        }
        if appState.selectedProjectID == nil {
            appState.selectedProjectID = project.id
        }
    }
}
