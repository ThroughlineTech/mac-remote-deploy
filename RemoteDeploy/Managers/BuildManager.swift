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

    /// Persistent store for completed build records. TKT-008.
    private var buildHistoryStore: (any BuildHistoryStoring)?

    /// Optional sink for live build events (log lines + status transitions).
    /// Set via `configure(...)` to the server's `BuildEventBroadcasting`
    /// adapter so subscribed WebSocket clients on the companion see
    /// xcodebuild output in real time. Nil in tests that don't care.
    /// TKT-027.
    private var buildEventBroadcaster: (any BuildEventBroadcasting)?

    /// Local deploy manager for macOS post-build deployment. TKT-053.
    private var localDeployManager: (any LocalDeployManagerProtocol)?

    // MARK: - Setup

    /// Wires in the dependencies this manager needs. Called once at app launch.
    func configure(
        buildEngine: any BuildEngineProtocol,
        deployServer: any DeployServerProtocol,
        notificationManager: NotificationManager,
        ipaImporter: IPAImporter,
        buildHistoryStore: any BuildHistoryStoring,
        buildEventBroadcaster: (any BuildEventBroadcasting)? = nil,
        localDeployManager: (any LocalDeployManagerProtocol)? = nil
    ) {
        self.buildEngine = buildEngine
        self.deployServer = deployServer
        self.notificationManager = notificationManager
        self.ipaImporter = ipaImporter
        self.buildHistoryStore = buildHistoryStore
        self.buildEventBroadcaster = buildEventBroadcaster
        self.localDeployManager = localDeployManager
    }

    // MARK: - Status helper

    /// Assigns a new build status and fans it out to the event broadcaster
    /// in one place, so every transition automatically broadcasts. Use
    /// this in preference to writing `buildStatus = ...` directly.
    /// TKT-027.
    private func setBuildStatus(_ new: BuildStatus) {
        buildStatus = new
        buildEventBroadcaster?.broadcastBuildStatus(new)
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
            setBuildStatus(.building(progress: "Starting build..."))
            buildLog = ""

            // TKT-048: pre-select the engine so the log stream comes from
            // the right engine (Expo vs Xcode) before the build starts.
            if let router = buildEngine as? BuildEngineRouter {
                router.prepareForBuild(project)
            }

            // Get the log stream BEFORE starting the build so the continuation is ready.
            let logStream = buildEngine.buildLogStream

            // Capture the broadcaster locally so the inner Task closure
            // doesn't have to hop back through `self` for every line.
            // TKT-027: fans each xcodebuild line out to WebSocket
            // subscribers as it arrives.
            let broadcaster = buildEventBroadcaster

            // Consume build log stream in a background task.
            let logTask = Task { @MainActor in
                for await line in logStream {
                    buildLog += line + "\n"
                    broadcaster?.broadcastBuildLog(line)
                }
            }

            notificationManager.notifyBuildStarted(projectName: project.name)

            let startTime = Date()
            let installURL = serverURL + "/" + project.urlSlug + "/"

            do {
                let ipaPath = try await buildEngine.build(project: project)
                let endTime = Date()
                logTask.cancel()
                setBuildStatus(.success(ipaPath: ipaPath))
                let result = BuildResult(
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
                lastBuildResult = result
                buildHistoryStore?.append(result)

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

                // TKT-053: local deploy for macOS projects. Runs after a
                // successful build and before notifications so the
                // notification text can reflect the deploy outcome.
                var didLocalDeploy = false
                let deployTargetDir = project.localDeployPath ?? "/Applications"

                if project.platform.lowercased() == "macos",
                   project.localDeploy,
                   let localDeployManager {
                    let archiveName = project.name.replacingOccurrences(of: " ", with: "_")
                    let archivePath = "/tmp/RemoteDeploy/\(archiveName).xcarchive"
                    do {
                        try await localDeployManager.deploy(
                            appName: project.scheme,
                            fromArchive: archivePath,
                            toDirectory: deployTargetDir,
                            port: nil
                        )
                        didLocalDeploy = true
                        Logger.build.info("Local deploy succeeded for \(project.name, privacy: .public)")
                    } catch {
                        Logger.build.error("Local deploy failed for \(project.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
                        buildLog += "[LocalDeploy] \(error.localizedDescription)\n"
                    }
                }

                // Post success notification (local).
                if didLocalDeploy {
                    notificationManager.notifyBuildSuccess(
                        projectName: project.name,
                        installURL: "deployed to \(deployTargetDir)"
                    )
                } else {
                    notificationManager.notifyBuildSuccess(
                        projectName: project.name,
                        installURL: installURL
                    )
                }

                // Push notifications via the injected callback.
                if didLocalDeploy {
                    await sendPushNotification?(
                        "Build Deployed",
                        "\(project.name) deployed to \(deployTargetDir)",
                        .normal,
                        installURL
                    )
                } else {
                    await sendPushNotification?(
                        "Build Succeeded",
                        "\(project.name) is ready to install",
                        .normal,
                        installURL
                    )
                }
            } catch {
                let endTime = Date()
                logTask.cancel()
                setBuildStatus(.failure(error: error.localizedDescription))
                let result = BuildResult(
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
                lastBuildResult = result
                buildHistoryStore?.append(result)

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
        setBuildStatus(.success(ipaPath: ipaPath))
    }

    /// Updates build status to reflect a failed IPA import.
    func markImportFailed(reason: String) {
        setBuildStatus(.failure(error: "Import failed: \(reason)"))
    }

    /// Clears the accumulated build log. Used by the build-log window's Clear button.
    func clearLog() {
        buildLog = ""
    }
}
