// Routes build requests to the appropriate engine based on project type.
// Conforms to BuildEngineProtocol so BuildManager doesn't need to know
// about multiple engine implementations. TKT-048.
import Foundation
import os

final class BuildEngineRouter: BuildEngineProtocol, @unchecked Sendable {

    // MARK: - Engines

    private let xcodeEngine: XcodeBuildEngine
    private let expoEngine: ExpoBuildEngine

    /// Tracks which engine is currently active (for status/cancel forwarding).
    private let lockedActiveEngine = OSAllocatedUnfairLock<(any BuildEngineProtocol)?>(initialState: nil)

    // MARK: - Init

    init(xcodeEngine: XcodeBuildEngine = XcodeBuildEngine(),
         expoEngine: ExpoBuildEngine = ExpoBuildEngine()) {
        self.xcodeEngine = xcodeEngine
        self.expoEngine = expoEngine
    }

    // MARK: - BuildEngineProtocol

    /// Dispatches the build to the appropriate engine based on project type.
    func build(project: ProjectConfig) async throws -> String {
        let engine = engine(for: project)
        lockedActiveEngine.withLock { $0 = engine }
        defer { lockedActiveEngine.withLock { $0 = nil } }
        return try await engine.build(project: project)
    }

    /// Cancels the active engine's build.
    func cancelBuild() async {
        let engine = lockedActiveEngine.withLock { $0 }
        await engine?.cancelBuild()
    }

    /// Returns the build log stream from the currently prepared engine.
    /// Callers should call `prepareForBuild(_:)` before accessing this
    /// to ensure the correct engine's stream is returned.
    var buildLogStream: AsyncStream<String> {
        let engine = lockedActiveEngine.withLock { $0 }
        return (engine ?? xcodeEngine).buildLogStream
    }

    /// Pre-selects the engine for an upcoming build so `buildLogStream`
    /// returns the correct engine's stream. Called by BuildManager before
    /// subscribing to the log stream. TKT-048.
    func prepareForBuild(_ project: ProjectConfig) {
        let selected = engine(for: project)
        lockedActiveEngine.withLock { $0 = selected }
    }

    /// Returns the active engine's current status.
    var status: BuildStatus {
        let engine = lockedActiveEngine.withLock { $0 }
        return engine?.status ?? .idle
    }

    /// Detects schemes — routes to the appropriate engine based on project type.
    /// For Expo projects, this needs to know the project type, but detectSchemes
    /// only receives a path. We check for app.json as a heuristic.
    func detectSchemes(at projectPath: String) async throws -> [String] {
        // Heuristic: if the path contains app.json, it's likely an Expo project.
        let fm = FileManager.default
        let appJsonDirect = (projectPath as NSString).appendingPathComponent("app.json")
        let hasAppJson = fm.fileExists(atPath: appJsonDirect)

        // Also check immediate subdirectories
        let hasAppJsonInSubdir = !hasAppJson && ((try? fm.contentsOfDirectory(atPath: projectPath)) ?? [])
            .contains { sub in
                fm.fileExists(atPath: (projectPath as NSString).appendingPathComponent(sub).appending("/app.json"))
            }

        if hasAppJson || hasAppJsonInSubdir {
            return try await expoEngine.detectSchemes(at: projectPath)
        }
        return try await xcodeEngine.detectSchemes(at: projectPath)
    }

    // MARK: - Engine Selection

    /// Returns the appropriate engine for a project's type.
    private func engine(for project: ProjectConfig) -> any BuildEngineProtocol {
        switch project.projectType {
        case .expo:
            return expoEngine
        case .xcode:
            return xcodeEngine
        }
    }

    // MARK: - Engine Access (for log stream setup before build)

    /// Provides access to a specific engine's log stream by project type.
    /// BuildManager should call this to get the log stream BEFORE build().
    func buildLogStream(for projectType: ProjectType) -> AsyncStream<String> {
        switch projectType {
        case .expo:
            return expoEngine.buildLogStream
        case .xcode:
            return xcodeEngine.buildLogStream
        }
    }
}
