import SwiftUI
import Foundation
import os

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

    /// Validation errors per field; nil = valid. Computed inline as the user types.
    @State private var bundleIDError: String?
    @State private var teamIDError: String?
    @State private var pathError: String?

    /// Validates a bundle ID against the reverse-DNS pattern (e.g. com.example.app).
    /// Returns nil if valid, an error message otherwise.
    private func validateBundleID(_ value: String) -> String? {
        if value.isEmpty { return nil } // empty = no error yet, just incomplete
        let pattern = #"^[A-Za-z][A-Za-z0-9-]*(\.[A-Za-z][A-Za-z0-9-]*)+$"#
        if value.range(of: pattern, options: .regularExpression) == nil {
            return "Must be reverse-DNS format (e.g. com.example.app)"
        }
        return nil
    }

    /// Validates an Apple Developer Team ID — exactly 10 alphanumeric characters.
    private func validateTeamID(_ value: String) -> String? {
        if value.isEmpty { return nil }
        if value.count != 10 {
            return "Team ID must be exactly 10 characters"
        }
        if value.range(of: #"^[A-Z0-9]+$"#, options: .regularExpression) == nil {
            return "Team ID must be uppercase alphanumeric"
        }
        return nil
    }

    /// Validates that the project path exists on disk.
    private func validatePath(_ value: String) -> String? {
        if value.isEmpty { return nil }
        if !FileManager.default.fileExists(atPath: value) {
            return "Path does not exist"
        }
        return nil
    }

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
                    .onChange(of: selectedScheme) {
                        // Re-detect build settings when scheme changes
                        bundleID = ""
                        teamID = ""
                        detectBuildSettings()
                    }
                }
            }

            // Bundle ID
            TextField("Bundle ID:", text: $bundleID)
                .textFieldStyle(.roundedBorder)
                .onChange(of: bundleID) { _, newValue in
                    bundleIDError = validateBundleID(newValue)
                }
            if let bundleIDError {
                Text(bundleIDError)
                    .font(.caption)
                    .foregroundColor(.red)
            }

            // Team ID
            TextField("Team ID:", text: $teamID)
                .textFieldStyle(.roundedBorder)
                .onChange(of: teamID) { _, newValue in
                    teamIDError = validateTeamID(newValue)
                }
            if let teamIDError {
                Text(teamIDError)
                    .font(.caption)
                    .foregroundColor(.red)
            }

            if let pathError {
                Text(pathError)
                    .font(.caption)
                    .foregroundColor(.red)
            }
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

    /// Sets the project path from the selected URL and kicks off scheme + build settings detection.
    private func applySelectedPath(_ url: URL) {
        projectPath = url.path
        pathError = validatePath(projectPath)
        // Derive a default name from the directory/file name
        let name = url.deletingPathExtension().lastPathComponent
        if projectName.isEmpty {
            projectName = name
        }
        detectSchemes()
    }

    /// Auto-detects Bundle ID and Team ID from the Xcode project's build settings.
    /// Runs `xcodebuild -showBuildSettings` and parses PRODUCT_BUNDLE_IDENTIFIER and DEVELOPMENT_TEAM.
    private func detectBuildSettings() {
        guard !projectPath.isEmpty, !selectedScheme.isEmpty else { return }

        Task {
            do {
                let output = try await runXcodeBuildShowSettings()
                await MainActor.run {
                    if let detectedBundleID = parseSetting("PRODUCT_BUNDLE_IDENTIFIER", from: output), bundleID.isEmpty {
                        bundleID = detectedBundleID
                    }
                    if let detectedTeamID = parseSetting("DEVELOPMENT_TEAM", from: output), teamID.isEmpty {
                        teamID = detectedTeamID
                    }
                }
            } catch {
                Logger.build.error("Build settings detection failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Runs xcodebuild -showBuildSettings for the selected project and scheme.
    /// - Returns: The raw stdout output as a string.
    private func runXcodeBuildShowSettings() async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")

        var args = ["xcodebuild", "-showBuildSettings", "-scheme", selectedScheme]

        // Determine if this is a project or workspace
        let fm = FileManager.default
        let xcworkspaces = try? fm.contentsOfDirectory(atPath: projectPath).filter { $0.hasSuffix(".xcworkspace") }
        let xcprojects = try? fm.contentsOfDirectory(atPath: projectPath).filter { $0.hasSuffix(".xcodeproj") }

        if let workspace = xcworkspaces?.first {
            args += ["-workspace", "\(projectPath)/\(workspace)"]
        } else if let project = xcprojects?.first {
            args += ["-project", "\(projectPath)/\(project)"]
        } else if projectPath.hasSuffix(".xcodeproj") || projectPath.hasSuffix(".xcworkspace") {
            let flag = projectPath.hasSuffix(".xcworkspace") ? "-workspace" : "-project"
            args += [flag, projectPath]
        }

        process.arguments = args

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Parses a single build setting value from xcodebuild -showBuildSettings output.
    /// - Parameters:
    ///   - key: The setting name (e.g., "PRODUCT_BUNDLE_IDENTIFIER").
    ///   - output: The raw xcodebuild output.
    /// - Returns: The setting value, or nil if not found.
    private func parseSetting(_ key: String, from output: String) -> String? {
        for line in output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("\(key) = ") {
                let value = trimmed.replacingOccurrences(of: "\(key) = ", with: "")
                // Skip template values like $(PRODUCT_BUNDLE_IDENTIFIER)
                if !value.isEmpty, !value.contains("$(") {
                    return value
                }
            }
        }
        return nil
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
                    // Auto-detect bundle ID and team ID now that we have a scheme
                    detectBuildSettings()
                }
            } catch {
                await MainActor.run {
                    isDetectingSchemes = false
                }
                Logger.build.error("Scheme detection failed: \(error.localizedDescription, privacy: .public)")
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
            Logger.storage.error("Failed to save project: \(error.localizedDescription, privacy: .public)")
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
