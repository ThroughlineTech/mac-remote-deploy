// Owns the macOS build orchestration pulled out of MenuBarView.performBuild()
// per TKT-006. This mirrors the iOS companion's BuildManager pattern but runs
// xcodebuild directly via the injected BuildEngineProtocol instead of hitting
// an API client.
import Foundation
import SwiftUI
import os
import RemoteDeployShared

/// Central build state manager for the macOS host. Owns the in-progress build
/// status, the accumulated build log, the last completed build result, and the
/// orchestration logic that runs xcodebuild + starts the server + fires
/// notifications and push alerts. Views observe this via @EnvironmentObject so
/// build state is consistent across the menu bar, build log window, and any
/// future views that care about build progress.
@MainActor
final class BuildManager: ObservableObject {

    // MARK: - Published State

    /// Current build status: idle, building, success, or failure.
    @Published var buildStatus: BuildStatus = .idle

    /// Accumulated log lines from the current/most-recent build. New-line delimited.
    @Published var buildLog: String = ""

    /// The most recent completed build result, if any.
    @Published var lastBuildResult: BuildResult?

    /// Convenience flag for views that only care whether a build is in progress.
    var isBuilding: Bool {
        if case .building = buildStatus { return true }
        return false
    }

    // MARK: - Dependencies (set by RemoteDeployApp at launch)

    /// The build engine used to archive + export IPAs.
    private var buildEngine: (any BuildEngineProtocol)?

    /// The deploy server that will serve the resulting IPA after a successful build.
    private var deployServer: (any DeployServerProtocol)?

    /// macOS desktop notification manager.
    private var notificationManager: NotificationManager?

    /// Push notification callback invoked after build success/failure.
    /// Takes title, message, priority, and an optional install URL.
    var sendPushNotification: ((String, String, PushPriority, String?) async -> Void)?

    /// IPA importer for the "Import IPA..." menu action.
    var ipaImporter: IPAImporter?

    // MARK: - Setup

    /// Wires in the dependencies this manager needs. Called once at app launch.
    func configure(
        buildEngine: any BuildEngineProtocol,
        deployServer: any DeployServerProtocol,
        notificationManager: NotificationManager,
        ipaImporter: IPAImporter
    ) {
        self.buildEngine = buildEngine
        self.deployServer = deployServer
        self.notificationManager = notificationManager
        self.ipaImporter = ipaImporter
    }

    // MARK: - Build Orchestration

    /// Runs the full build pipeline for a project: archive → export → copy → start server
    /// → notify. Verbatim copy of the logic previously inline in `MenuBarView.performBuild()`.
    ///
    /// - Parameters:
    ///   - project: The project to build (with `buildConfiguration` already applied).
    ///   - serverURL: The current base server URL, used to construct the install URL for notifications.
    ///   - serverPort: The HTTPS port the server should bind to if it needs to be started.
    ///   - certPath: TLS certificate path for server startup.
    ///   - keyPath: TLS private key path for server startup.
    ///   - serverRunning: Whether the server is already running (so we don't try to start it twice).
    ///   - onServerStarted: Callback invoked on the main actor when the server successfully starts.
    func triggerBuild(
        project: ProjectConfig,
        serverURL: String,
        serverPort: Int,
        certPath: String,
        keyPath: String,
        serverRunning: Bool,
        onServerStarted: @escaping () -> Void
    ) {
        guard let buildEngine, let deployServer, let notificationManager else {
            Logger.build.error("BuildManager.triggerBuild called before configure()")
            return
        }

        Task { @MainActor in
            buildStatus = .building(progress: "Starting build...")
            buildLog = ""

            // Get the log stream BEFORE starting the build so the continuation is ready.
            let logStream = buildEngine.buildLogStream

            // Consume build log stream in a background task.
            let logTask = Task { @MainActor in
                for await line in logStream {
                    buildLog += line + "\n"
                }
            }

            notificationManager.notifyBuildStarted(projectName: project.name)

            let startTime = Date()
            let installURL = serverURL + "/" + project.urlSlug + "/"

            do {
                let ipaPath = try await buildEngine.build(project: project)
                let endTime = Date()
                logTask.cancel()
                buildStatus = .success(ipaPath: ipaPath)
                lastBuildResult = BuildResult(
                    id: UUID(),
                    projectID: project.id,
                    success: true,
                    ipaPath: ipaPath,
                    errorSummary: nil,
                    buildLog: buildLog,
                    startTime: startTime,
                    endTime: endTime,
                    version: nil,
                    buildNumber: nil
                )

                // Register project with deploy server and start server if needed.
                deployServer.registerProject(project)
                deployServer.setBaseURL(serverURL)
                if !serverRunning, !certPath.isEmpty, !keyPath.isEmpty {
                    do {
                        try await deployServer.start(
                            port: serverPort,
                            certPath: certPath,
                            keyPath: keyPath
                        )
                        onServerStarted()
                    } catch {
                        Logger.server.error("Server failed to start after build: \(error.localizedDescription, privacy: .public)")
                    }
                }

                // Post success notification (local).
                notificationManager.notifyBuildSuccess(
                    projectName: project.name,
                    installURL: installURL
                )

                // Push notifications via the injected callback.
                await sendPushNotification?(
                    "Build Succeeded",
                    "\(project.name) is ready to install",
                    .normal,
                    installURL
                )
            } catch {
                let endTime = Date()
                logTask.cancel()
                buildStatus = .failure(error: error.localizedDescription)
                lastBuildResult = BuildResult(
                    id: UUID(),
                    projectID: project.id,
                    success: false,
                    ipaPath: nil,
                    errorSummary: error.localizedDescription,
                    buildLog: buildLog,
                    startTime: startTime,
                    endTime: endTime,
                    version: nil,
                    buildNumber: nil
                )

                notificationManager.notifyBuildFailure(
                    projectName: project.name,
                    error: error.localizedDescription
                )

                await sendPushNotification?(
                    "Build Failed",
                    "\(project.name): \(error.localizedDescription)",
                    .high,
                    nil
                )
            }
        }
    }

    /// Updates build status to reflect a successfully imported IPA file.
    /// Used by the "Import IPA..." menu action which bypasses the archive/export pipeline.
    func markImportSucceeded(ipaPath: String) {
        buildStatus = .success(ipaPath: ipaPath)
    }

    /// Updates build status to reflect a failed IPA import.
    func markImportFailed(reason: String) {
        buildStatus = .failure(error: "Import failed: \(reason)")
    }

    /// Clears the accumulated build log. Used by the build-log window's Clear button.
    func clearLog() {
        buildLog = ""
    }
}
