import SwiftUI
import os

/// Form view for adding or editing a project configuration.
/// Used both in the settings window and the setup assistant.
struct ProjectFormView: View {
    // TKT-060 (Phase 6): scheme detection goes through the server's
    // /filesystem/schemes endpoint instead of the in-process build engine.
    @EnvironmentObject var menuBarClient: MenuBarClient
    @Binding var project: ProjectConfig
    var onSave: (ProjectConfig) -> Void
    var onCancel: () -> Void
    /// Optional delete handler. When provided, a Delete button is shown.
    var onDelete: ((ProjectConfig) -> Void)?

    @State private var showDeleteConfirm = false

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
                    .onChange(of: project.scheme) {
                        // Re-detect bundle ID and team ID when scheme changes
                        detectBuildSettings()
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
                    .help("iOS bundle identifier (e.g., com.example.myapp)")

                TextField("Team ID", text: $project.teamID)
                    .textFieldStyle(.roundedBorder)
                    .help("Apple Developer Team ID (e.g., ABCDE12345)")

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

                Picker("Platform", selection: $project.platform) {
                    Text("iOS").tag("iOS")
                    Text("macOS").tag("macOS")
                }

                // TKT-053: local auto-deploy toggle for macOS projects.
                if project.platform == "macOS" {
                    Toggle("Auto-deploy locally after build", isOn: $project.localDeploy)
                        .help("Automatically quit, replace, and relaunch the app on this Mac after a successful build")

                    if project.localDeploy {
                        TextField("Deploy path (default: /Applications)", text: Binding(
                            get: { project.localDeployPath ?? "" },
                            set: { project.localDeployPath = $0.isEmpty ? nil : $0 }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .help("Directory to deploy the .app to. Leave empty for /Applications/")
                    }
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
                if onDelete != nil {
                    Button("Delete", role: .destructive) {
                        showDeleteConfirm = true
                    }
                    .foregroundColor(.red)
                }
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
        .confirmationDialog("Delete \"\(project.name)\"?", isPresented: $showDeleteConfirm) {
            Button("Delete", role: .destructive) {
                onDelete?(project)
            }
        } message: {
            Text("This will remove the project from RemoteDeploy. Your source code is not affected.")
        }
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
                let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
                project.urlSlug = project.name.lowercased()
                    .replacingOccurrences(of: " ", with: "-")
                    .unicodeScalars.filter { allowed.contains($0) }
                    .map { String($0) }.joined()
            }
            detectSchemes()
        }
    }

    /// Detects available schemes via the server's /filesystem/schemes endpoint
    /// (which runs `xcodebuild -list -project <path>`). The endpoint expects the
    /// `.xcodeproj` path, so resolve it from the chosen directory first. TKT-060.
    private func detectSchemes() {
        guard !project.projectPath.isEmpty else { return }
        isDetectingSchemes = true
        detectionError = nil
        let xcodeprojPath = Self.resolveXcodeprojPath(project.projectPath)

        Task {
            guard let schemes = await menuBarClient.detectSchemes(projectPath: xcodeprojPath) else {
                detectionError = "Failed to detect schemes: \(menuBarClient.lastError ?? "unknown error")"
                isDetectingSchemes = false
                return
            }
            detectedSchemes = schemes
            if let first = schemes.first, project.scheme.isEmpty {
                project.scheme = first
            }
            isDetectingSchemes = false
            // Auto-detect bundle ID and team ID
            detectBuildSettings()
        }
    }

    /// Resolves a directory project path to the `.xcodeproj` it contains so the
    /// scheme-detection endpoint gets the path it expects. Returns the input
    /// unchanged if it is already a `.xcodeproj` or no project is found.
    static func resolveXcodeprojPath(_ path: String) -> String {
        if path.hasSuffix(".xcodeproj") { return path }
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
        if let proj = contents.first(where: { $0.hasSuffix(".xcodeproj") }) {
            return "\(path)/\(proj)"
        }
        return path
    }

    /// Auto-detects Bundle ID, Team ID, and platform by running xcodebuild -showBuildSettings.
    /// Always updates bundle ID to match the selected scheme. Only fills team ID if empty.
    private func detectBuildSettings() {
        guard !project.projectPath.isEmpty, !project.scheme.isEmpty else { return }

        Task {
            do {
                let output = try await runShowBuildSettings()
                await MainActor.run {
                    if let detected = parseSetting("PRODUCT_BUNDLE_IDENTIFIER", from: output) {
                        project.bundleID = detected
                    }
                    if let detected = parseSetting("DEVELOPMENT_TEAM", from: output),
                       project.teamID.isEmpty {
                        project.teamID = detected
                    }
                    // Auto-detect platform from SDK
                    if let sdk = parseSetting("SDK_NAME", from: output) {
                        if sdk.hasPrefix("macos") {
                            project.platform = "macOS"
                        } else {
                            project.platform = "iOS"
                        }
                    }
                }
            } catch {
                Logger.build.error("Build settings detection failed: \(error.localizedDescription, privacy: .public)")
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
