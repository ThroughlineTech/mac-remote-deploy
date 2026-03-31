import SwiftUI

/// Form view for adding or editing a project configuration.
/// Used both in the settings window and the setup assistant.
struct ProjectFormView: View {
    @EnvironmentObject var serviceContainer: ServiceContainer
    @Binding var project: ProjectConfig
    var onSave: (ProjectConfig) -> Void
    var onCancel: () -> Void

    /// Schemes detected from the Xcode project, populated when the user picks a project path.
    @State private var detectedSchemes: [String] = []
    /// Whether we're currently detecting schemes from the project.
    @State private var isDetectingSchemes = false
    /// Error message if scheme detection fails.
    @State private var detectionError: String?

    var body: some View {
        Form {
            // MARK: - Project Location
            Section("Project") {
                HStack {
                    TextField("Project Path", text: $project.projectPath)
                        .textFieldStyle(.roundedBorder)
                    Button("Browse...") {
                        browseForProject()
                    }
                }
                .help("Path to the directory containing .xcodeproj or .xcworkspace")

                TextField("Project Name", text: $project.name)
                    .textFieldStyle(.roundedBorder)
                    .help("Display name for this project in the menu bar")
            }

            // MARK: - Build Settings
            Section("Build Settings") {
                if detectedSchemes.isEmpty {
                    HStack {
                        TextField("Scheme", text: $project.scheme)
                            .textFieldStyle(.roundedBorder)
                        Button("Detect") {
                            detectSchemes()
                        }
                        .disabled(project.projectPath.isEmpty || isDetectingSchemes)
                    }
                } else {
                    Picker("Scheme", selection: $project.scheme) {
                        ForEach(detectedSchemes, id: \.self) { scheme in
                            Text(scheme).tag(scheme)
                        }
                    }
                }

                if isDetectingSchemes {
                    HStack {
                        ProgressView()
                            .scaleEffect(0.5)
                        Text("Detecting schemes...")
                            .foregroundColor(.secondary)
                    }
                }

                if let error = detectionError {
                    Text(error)
                        .foregroundColor(.red)
                        .font(.caption)
                }

                TextField("Bundle ID", text: $project.bundleID)
                    .textFieldStyle(.roundedBorder)
                    .help("iOS bundle identifier (e.g., net.rejog.voicememo)")

                TextField("Team ID", text: $project.teamID)
                    .textFieldStyle(.roundedBorder)
                    .help("Apple Developer Team ID (e.g., RDJQ523WP4)")

                TextField("Provisioning Profile (optional)", text: Binding(
                    get: { project.provisioningProfile ?? "" },
                    set: { project.provisioningProfile = $0.isEmpty ? nil : $0 }
                ))
                .textFieldStyle(.roundedBorder)
                .help("Leave empty for automatic signing")

                Picker("Configuration", selection: $project.buildConfiguration) {
                    Text("Debug").tag("Debug")
                    Text("Release").tag("Release")
                }

                Picker("Export Method", selection: $project.exportMethod) {
                    Text("Ad Hoc").tag("ad-hoc")
                    Text("Development").tag("development")
                }
            }

            // MARK: - Server Settings
            Section("Server") {
                TextField("URL Slug", text: $project.urlSlug)
                    .textFieldStyle(.roundedBorder)
                    .help("URL path for this project (e.g., 'rejog' serves at /rejog/)")
            }

            // MARK: - Actions
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    onSave(project)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(project.name.isEmpty || project.scheme.isEmpty || project.bundleID.isEmpty)
            }
        }
        .padding()
        .frame(minWidth: 450)
    }

    // MARK: - Actions

    /// Opens a file dialog for the user to select an Xcode project directory.
    private func browseForProject() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.folder]
        panel.message = "Select a folder containing an Xcode project or workspace"

        if panel.runModal() == .OK, let url = panel.url {
            project.projectPath = url.path
            if project.name.isEmpty {
                project.name = url.lastPathComponent
                project.urlSlug = project.name.lowercased().replacingOccurrences(of: " ", with: "-")
            }
            detectSchemes()
        }
    }

    /// Runs xcodebuild -list to detect available schemes in the project.
    private func detectSchemes() {
        guard !project.projectPath.isEmpty else { return }
        isDetectingSchemes = true
        detectionError = nil

        Task {
            do {
                let schemes = try await serviceContainer.buildEngine.detectSchemes(at: project.projectPath)
                await MainActor.run {
                    detectedSchemes = schemes
                    if let first = schemes.first, project.scheme.isEmpty {
                        project.scheme = first
                    }
                    isDetectingSchemes = false
                    // Auto-detect bundle ID and team ID
                    detectBuildSettings()
                }
            } catch {
                await MainActor.run {
                    detectionError = "Failed to detect schemes: \(error.localizedDescription)"
                    isDetectingSchemes = false
                }
            }
        }
    }

    /// Auto-detects Bundle ID and Team ID by running xcodebuild -showBuildSettings.
    /// Only fills in empty fields — won't overwrite user-entered values.
    private func detectBuildSettings() {
        guard !project.projectPath.isEmpty, !project.scheme.isEmpty else { return }

        Task {
            do {
                let output = try await runShowBuildSettings()
                await MainActor.run {
                    if let detected = parseSetting("PRODUCT_BUNDLE_IDENTIFIER", from: output),
                       project.bundleID.isEmpty {
                        project.bundleID = detected
                    }
                    if let detected = parseSetting("DEVELOPMENT_TEAM", from: output),
                       project.teamID.isEmpty {
                        project.teamID = detected
                    }
                }
            } catch {
                print("Build settings detection failed: \(error.localizedDescription)")
            }
        }
    }

    /// Runs xcodebuild -showBuildSettings and returns the raw output.
    private func runShowBuildSettings() async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")

        var args = ["xcodebuild", "-showBuildSettings", "-scheme", project.scheme]

        let fm = FileManager.default
        let path = project.projectPath
        let xcworkspaces = (try? fm.contentsOfDirectory(atPath: path))?.filter { $0.hasSuffix(".xcworkspace") } ?? []
        let xcprojects = (try? fm.contentsOfDirectory(atPath: path))?.filter { $0.hasSuffix(".xcodeproj") } ?? []

        if let workspace = xcworkspaces.first {
            args += ["-workspace", "\(path)/\(workspace)"]
        } else if let xcproj = xcprojects.first {
            args += ["-project", "\(path)/\(xcproj)"]
        } else if path.hasSuffix(".xcodeproj") || path.hasSuffix(".xcworkspace") {
            args += [path.hasSuffix(".xcworkspace") ? "-workspace" : "-project", path]
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

    /// Parses a build setting value from xcodebuild -showBuildSettings output.
    private func parseSetting(_ key: String, from output: String) -> String? {
        for line in output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("\(key) = ") {
                let value = trimmed.replacingOccurrences(of: "\(key) = ", with: "")
                if !value.isEmpty, !value.contains("$(") {
                    return value
                }
            }
        }
        return nil
    }
}
