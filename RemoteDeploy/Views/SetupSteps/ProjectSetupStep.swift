import SwiftUI
import Foundation
import os
import RemoteDeployShared

// MARK: - Project Setup Step

/// Step 3 of the setup wizard: allows the user to select an Xcode project via
/// file picker or drag-and-drop, auto-detects available schemes, and collects
/// bundle ID and team ID. Supports both native Xcode and Expo (React Native)
/// projects via a project type picker. TKT-048.
struct ProjectSetupStep: View {
    @ObservedObject var appState: AppState
    // TKT-060 (Phase 6): scheme detection + project save go through the server
    // over the API instead of the in-process build engine / project store.
    @EnvironmentObject var menuBarClient: MenuBarClient

    /// The selected project type — Xcode or Expo. TKT-048.
    @State private var projectType: ProjectType = .xcode
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

    /// Expo app directory within a monorepo (e.g. "app"). TKT-048.
    @State private var expoAppDirectory: String = ""
    /// Environment warnings for Expo builds. TKT-048.
    @State private var environmentWarnings: [String] = []

    /// Validation errors per field; nil = valid. Computed inline as the user types.
    /// Validators live in `ProjectSetupValidators` so tests can cover them directly.
    @State private var bundleIDError: String?
    @State private var teamIDError: String?
    @State private var pathError: String?
    /// TKT-014: scheme is required — unlike the other fields, empty is an error.
    @State private var schemeError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Project")
                .font(.title2.bold())

            Text("Select an Xcode project or workspace. RemoteDeploy will build it, export an IPA, and serve it for OTA installation.")
                .font(.body)
                .foregroundColor(.secondary)

            Divider()

            // --- Project type picker (Xcode / Expo) --- TKT-048
            Picker("Project Type:", selection: $projectType) {
                Text("Xcode Project").tag(ProjectType.xcode)
                Text("Expo (React Native)").tag(ProjectType.expo)
            }
            .pickerStyle(.segmented)
            .onChange(of: projectType) {
                // Reset state when switching types
                detectedSchemes = []
                selectedScheme = ""
                if projectType == .expo {
                    environmentWarnings = EnvironmentChecker.expoEnvironmentWarnings()
                } else {
                    environmentWarnings = []
                }
            }

            // --- Environment warnings for Expo --- TKT-048
            if projectType == .expo {
                ForEach(environmentWarnings, id: \.self) { warning in
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                            .font(.caption)
                        Text(warning)
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                }
            }

            // --- Drag-and-drop zone / file picker ---
            dropZone

            // --- Expo app directory (for monorepos) --- TKT-048
            if projectType == .expo && !projectPath.isEmpty {
                TextField("App Directory (for monorepos, e.g. \"app\"):", text: $expoAppDirectory)
                    .textFieldStyle(.roundedBorder)
                    .help("Relative path from the project root to the Expo app directory. Leave empty if app.json is at the project root.")
            }

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
                    Text(projectType == .expo
                         ? "Drag project root directory here or click to browse"
                         : "Drag Xcode project here or click to browse")
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
                        // Re-detect build settings when scheme changes.
                        // Expo projects get bundle ID from app.json, not
                        // xcodebuild -showBuildSettings — skip the reset
                        // so auto-detected values are preserved. TKT-049.
                        schemeError = ProjectSetupValidators.validateScheme(selectedScheme)
                        if projectType != .expo {
                            bundleID = ""
                            teamID = ""
                            detectBuildSettings()
                        }
                    }
                }
            }
            // TKT-014: Inline error when no scheme is selected.
            if let schemeError {
                Text(schemeError)
                    .font(.caption)
                    .foregroundColor(.red)
            }

            // Bundle ID
            TextField("Bundle ID:", text: $bundleID)
                .textFieldStyle(.roundedBorder)
                .onChange(of: bundleID) { _, newValue in
                    bundleIDError = ProjectSetupValidators.validateBundleID(newValue)
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
                    teamIDError = ProjectSetupValidators.validateTeamID(newValue)
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

    /// Opens an NSOpenPanel to select a project path.
    /// For Xcode projects, selects .xcodeproj/.xcworkspace or directory.
    /// For Expo projects, selects the root directory. TKT-048.
    private func browseForProject() {
        let panel = NSOpenPanel()
        panel.title = projectType == .expo
            ? "Select Expo Project Root Directory"
            : "Select Xcode Project or Workspace"
        panel.canChooseFiles = projectType != .expo
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
        pathError = ProjectSetupValidators.validatePath(projectPath)
        // Derive a default name from the directory/file name
        let name = url.deletingPathExtension().lastPathComponent
        if projectName.isEmpty {
            projectName = name
        }

        // TKT-048: auto-detect Expo app directory and bundle ID from app.json
        if projectType == .expo {
            autoDetectExpoApp()
        }

        detectSchemes()
    }

    /// Scans the selected directory for app.json to auto-populate Expo fields. TKT-048.
    private func autoDetectExpoApp() {
        let fm = FileManager.default
        let rootAppJson = (projectPath as NSString).appendingPathComponent("app.json")

        var appJsonPath: String?

        if fm.fileExists(atPath: rootAppJson) {
            appJsonPath = rootAppJson
            expoAppDirectory = ""
        } else {
            // Check immediate subdirectories
            let subdirs = (try? fm.contentsOfDirectory(atPath: projectPath)) ?? []
            for sub in subdirs {
                let candidate = (projectPath as NSString).appendingPathComponent(sub)
                let candidateAppJson = (candidate as NSString).appendingPathComponent("app.json")
                if fm.fileExists(atPath: candidateAppJson) {
                    appJsonPath = candidateAppJson
                    expoAppDirectory = sub
                    break
                }
            }
        }

        // Parse bundle ID from app.json
        if let path = appJsonPath,
           let data = fm.contents(atPath: path),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let expo = json["expo"] as? [String: Any],
           let ios = expo["ios"] as? [String: Any],
           let detectedBundleID = ios["bundleIdentifier"] as? String {
            bundleID = detectedBundleID
        }
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

    /// Detects schemes via the server's /filesystem/schemes endpoint (which runs
    /// `xcodebuild -list -project <path>`). The endpoint expects the `.xcodeproj`
    /// path, so resolve it from the chosen directory first. TKT-060 (Phase 6).
    private func detectSchemes() {
        isDetectingSchemes = true
        detectedSchemes = []
        let xcodeprojPath = ProjectFormView.resolveXcodeprojPath(projectPath)

        Task {
            guard let schemes = await menuBarClient.detectSchemes(projectPath: xcodeprojPath) else {
                isDetectingSchemes = false
                schemeError = ProjectSetupValidators.validateScheme(selectedScheme)
                Logger.build.error("Scheme detection failed: \(menuBarClient.lastError ?? "unknown", privacy: .public)")
                return
            }
            detectedSchemes = schemes
            // TKT-025: validate selectedScheme against the new list rather than
            // only resetting when empty, so a stale name doesn't produce an
            // invalid Picker selection when switching projects mid-setup.
            if !schemes.contains(selectedScheme) {
                selectedScheme = schemes.first ?? ""
            }
            isDetectingSchemes = false
            // TKT-014: refresh schemeError once detection completes so the inline
            // error appears if no schemes were found.
            schemeError = ProjectSetupValidators.validateScheme(selectedScheme)
            // Auto-detect bundle ID and team ID now that we have a scheme.
            detectBuildSettings()
        }
    }

    /// Saves the configured project to the server via the projects API.
    /// Called automatically when the user navigates forward from this step.
    /// TKT-060 (Phase 6): the server's store write posts `.projectsDidChange`
    /// and the menu bar's poll refreshes its project projection.
    func saveProject() {
        guard !projectName.isEmpty, !projectPath.isEmpty else { return }
        // TKT-014: block save when no scheme has been selected. Mirrors the
        // pattern used by bundleID/teamID fields — inline error + no-advance.
        schemeError = ProjectSetupValidators.validateScheme(selectedScheme)
        guard schemeError == nil else { return }

        var project = ProjectConfig(name: projectName, projectPath: projectPath)
        project.projectType = projectType
        project.expoAppDirectory = projectType == .expo && !expoAppDirectory.isEmpty ? expoAppDirectory : nil
        project.scheme = selectedScheme
        project.bundleID = bundleID
        project.teamID = teamID

        Task {
            await menuBarClient.createProject(project)
        }
    }
}
