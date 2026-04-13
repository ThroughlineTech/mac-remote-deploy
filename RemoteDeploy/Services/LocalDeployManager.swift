// Handles post-build local deployment for macOS projects. Gracefully quits
// the running target app, copies the new .app bundle from the archive to the
// target directory, and relaunches it. Supports self-deploy (RemoteDeploy
// updating itself) via a trampoline process. TKT-053.
import Foundation
import AppKit
import os

/// Errors specific to the local deploy pipeline.
enum LocalDeployError: LocalizedError {
    /// The .app bundle was not found inside the archive's Products/Applications directory.
    case appBundleNotFound(String)
    /// FileManager failed to copy or replace the .app bundle.
    case copyFailed(String)
    /// The target app refused to quit within the timeout.
    case terminationTimeout(String)

    var errorDescription: String? {
        switch self {
        case .appBundleNotFound(let detail):
            return "App bundle not found: \(detail)"
        case .copyFailed(let detail):
            return "Copy failed: \(detail)"
        case .terminationTimeout(let detail):
            return "Termination timeout: \(detail)"
        }
    }
}

/// Deploys a freshly built macOS .app bundle to a local directory, replacing
/// any existing copy and relaunching the app. Not annotated @MainActor because
/// deploy does file I/O and Process work; MainActor dispatch is used inline
/// only for the self-deploy NSApp.terminate call.
final class LocalDeployManager: LocalDeployManagerProtocol {

    /// Deploys a macOS .app from an xcarchive to a target directory.
    ///
    /// - Parameters:
    ///   - appName: The name of the app (e.g. "MyApp"). The .app bundle is
    ///     expected at `<archivePath>/Products/Applications/<appName>.app`.
    ///   - archivePath: Absolute path to the `.xcarchive` bundle.
    ///   - targetDir: Destination directory (e.g. "/Applications").
    ///   - port: Optional port to wait on for release before copying.
    func deploy(
        appName: String,
        fromArchive archivePath: String,
        toDirectory targetDir: String,
        port: Int?
    ) async throws {
        let fm = FileManager.default
        let appsDir = "\(archivePath)/Products/Applications"
        let sourcePath = "\(appsDir)/\(appName).app"

        // Verify the .app bundle exists in the archive.
        guard fm.fileExists(atPath: sourcePath) else {
            // Fall back to scanning the directory for any .app bundle.
            let contents = (try? fm.contentsOfDirectory(atPath: appsDir)) ?? []
            if let found = contents.first(where: { $0.hasSuffix(".app") }) {
                let fallbackSource = "\(appsDir)/\(found)"
                let fallbackName = (found as NSString).deletingPathExtension
                try await deployApp(
                    name: fallbackName,
                    sourcePath: fallbackSource,
                    targetDir: targetDir,
                    port: port
                )
                return
            }
            throw LocalDeployError.appBundleNotFound(
                "No .app bundle found in \(appsDir)"
            )
        }

        try await deployApp(
            name: appName,
            sourcePath: sourcePath,
            targetDir: targetDir,
            port: port
        )
    }

    // MARK: - Private

    /// Core deploy logic: quit running app, wait for port, copy, relaunch.
    private func deployApp(
        name: String,
        sourcePath: String,
        targetDir: String,
        port: Int?
    ) async throws {
        let fm = FileManager.default
        let targetPath = "\(targetDir)/\(name).app"

        // Ensure target directory exists.
        try fm.createDirectory(atPath: targetDir, withIntermediateDirectories: true)

        // Find and quit any running instance of the target app.
        let runningApps = findRunningApp(named: name)
        if let app = runningApps {
            Logger.build.info("LocalDeploy: terminating running \(name, privacy: .public)")
            app.terminate()

            // Poll for termination up to 5 seconds.
            let deadline = Date().addingTimeInterval(5.0)
            while !app.isTerminated, Date() < deadline {
                try await Task.sleep(for: .milliseconds(500))
            }

            // Force-terminate if still running.
            if !app.isTerminated {
                Logger.build.warning("LocalDeploy: force-terminating \(name, privacy: .public)")
                app.forceTerminate()
                try await Task.sleep(for: .milliseconds(500))
            }
        }

        // If a port was specified, wait for it to become free.
        if let port {
            let deadline = Date().addingTimeInterval(5.0)
            while isPortInUse(port), Date() < deadline {
                try await Task.sleep(for: .milliseconds(500))
            }
        }

        // Detect self-deploy: if the target path matches this app's bundle.
        let isSelfDeploy = targetPath == Bundle.main.bundlePath

        // Copy the .app bundle to the target directory.
        if fm.fileExists(atPath: targetPath) {
            // Use replaceItemAt for atomic replacement.
            do {
                let targetURL = URL(fileURLWithPath: targetPath)
                let sourceURL = URL(fileURLWithPath: sourcePath)
                _ = try fm.replaceItemAt(targetURL, withItemAt: sourceURL)
            } catch {
                throw LocalDeployError.copyFailed(
                    "Failed to replace \(targetPath): \(error.localizedDescription)"
                )
            }
        } else {
            do {
                try fm.copyItem(atPath: sourcePath, toPath: targetPath)
            } catch {
                throw LocalDeployError.copyFailed(
                    "Failed to copy to \(targetPath): \(error.localizedDescription)"
                )
            }
        }

        Logger.build.info("LocalDeploy: copied \(name, privacy: .public).app to \(targetDir, privacy: .public)")

        // Launch the deployed app.
        if isSelfDeploy {
            // Trampoline pattern: spawn a shell process that waits for our
            // PID to die, then opens the new app.
            let pid = ProcessInfo.processInfo.processIdentifier
            let script = "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; sleep 0.5; open '\(targetPath)'"
            let trampoline = Process()
            trampoline.executableURL = URL(fileURLWithPath: "/bin/sh")
            trampoline.arguments = ["-c", script]
            try trampoline.run()

            Logger.build.info("LocalDeploy: self-deploy trampoline spawned, terminating")

            // Terminate on the main actor.
            await MainActor.run {
                NSApplication.shared.terminate(nil)
            }
            return
        }

        // Normal case: open the newly deployed app.
        let appURL = URL(fileURLWithPath: targetPath)
        let config = NSWorkspace.OpenConfiguration()
        try await NSWorkspace.shared.openApplication(at: appURL, configuration: config)
        Logger.build.info("LocalDeploy: launched \(name, privacy: .public)")
    }

    /// Finds a running application by its localized name.
    private func findRunningApp(named name: String) -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first { app in
            app.localizedName == name
        }
    }

    /// Checks whether a TCP port is currently in use by attempting to bind.
    private func isPortInUse(_ port: Int) -> Bool {
        let socketFD = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else { return false }
        defer { Darwin.close(socketFD) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr.s_addr = INADDR_ANY

        var reuse: Int32 = 1
        setsockopt(socketFD, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.bind(socketFD, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        return result != 0
    }
}
