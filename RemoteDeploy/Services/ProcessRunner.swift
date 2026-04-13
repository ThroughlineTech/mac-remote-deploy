// Reusable process execution utility for streaming stdout/stderr via AsyncStream.
// Extracted from XcodeBuildEngine patterns so both XcodeBuildEngine and
// ExpoBuildEngine can run shell commands with real-time log output. TKT-048.
import Foundation
import os

/// Errors thrown by `ProcessRunner`.
enum ProcessRunnerError: LocalizedError {
    /// The process exited with a non-zero status.
    case nonZeroExit(executable: String, exitCode: Int32, lastStderr: String?)
    /// The process was cancelled before completion.
    case cancelled

    var errorDescription: String? {
        switch self {
        case .nonZeroExit(let exec, let code, let stderr):
            if let stderr, !stderr.isEmpty {
                return "\(exec) failed (exit \(code)): \(stderr)"
            }
            return "\(exec) failed (exit \(code))"
        case .cancelled:
            return "Process was cancelled."
        }
    }
}

/// Runs shell processes with real-time log streaming. Thread-safe.
///
/// Each instance tracks a single running process so callers can cancel it.
/// Create one per build phase or reuse across sequential phases.
final class ProcessRunner: @unchecked Sendable {

    /// The currently running process, protected by lock.
    private let lockedProcess = OSAllocatedUnfairLock<Process?>(initialState: nil)

    /// Ring buffer of recent stderr lines for failure messages.
    private let lockedRecentStderr = OSAllocatedUnfairLock<[String]>(initialState: [])
    private static let stderrRingCapacity = 8

    /// Cancellation flag — prevents new processes from starting after cancel.
    private let lockedIsCancelled = OSAllocatedUnfairLock<Bool>(initialState: false)

    /// Whether this runner has been cancelled.
    var isCancelled: Bool {
        lockedIsCancelled.withLock { $0 }
    }

    /// Marks this runner as cancelled and terminates any running process.
    func cancel() {
        lockedIsCancelled.withLock { $0 = true }
        let process = lockedProcess.withLock { $0 }
        if let process, process.isRunning {
            process.terminate()
        }
    }

    /// Resets the cancellation flag so the runner can be reused for a new build.
    func reset() {
        lockedIsCancelled.withLock { $0 = false }
    }

    /// Runs a process and streams output to the provided callback.
    ///
    /// - Parameters:
    ///   - executablePath: Absolute path to the executable (e.g. `/usr/bin/env`).
    ///   - arguments: Arguments to pass to the executable.
    ///   - workingDirectory: Working directory for the process.
    ///   - environment: Optional environment variables (inherits current if nil).
    ///   - onOutput: Callback for each stdout/stderr line. Called from background threads.
    /// - Throws: `ProcessRunnerError.nonZeroExit` on failure,
    ///   `ProcessRunnerError.cancelled` if cancelled.
    func run(
        executablePath: String,
        arguments: [String],
        workingDirectory: String? = nil,
        environment: [String: String]? = nil,
        onOutput: @escaping @Sendable (String) -> Void
    ) async throws {
        guard !isCancelled else { throw ProcessRunnerError.cancelled }

        lockedRecentStderr.withLock { $0.removeAll(keepingCapacity: true) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        if let wd = workingDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: wd)
        }
        if let env = environment {
            process.environment = env
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        lockedProcess.withLock { $0 = process }

        // Stream stdout
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            for line in text.components(separatedBy: .newlines) where !line.isEmpty {
                onOutput(line)
            }
        }

        // Stream stderr and capture ring buffer
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            for line in text.components(separatedBy: .newlines) where !line.isEmpty {
                self?.appendStderr(line)
                onOutput("[stderr] \(line)")
            }
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { [weak self] proc in
                // Drain remaining pipe data
                let stdoutTail = stdoutPipe.fileHandleForReading.availableData
                if !stdoutTail.isEmpty, let text = String(data: stdoutTail, encoding: .utf8) {
                    for line in text.components(separatedBy: .newlines) where !line.isEmpty {
                        onOutput(line)
                    }
                }
                let stderrTail = stderrPipe.fileHandleForReading.availableData
                if !stderrTail.isEmpty, let text = String(data: stderrTail, encoding: .utf8) {
                    for line in text.components(separatedBy: .newlines) where !line.isEmpty {
                        self?.appendStderr(line)
                        onOutput("[stderr] \(line)")
                    }
                }

                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                self?.lockedProcess.withLock { $0 = nil }

                let cancelled = self?.isCancelled ?? false
                if cancelled || proc.terminationReason == .uncaughtSignal {
                    continuation.resume(throwing: ProcessRunnerError.cancelled)
                } else if proc.terminationStatus != 0 {
                    let lastStderr = self?.lastMeaningfulStderr()
                    let execName = proc.executableURL?.lastPathComponent ?? "process"
                    continuation.resume(throwing: ProcessRunnerError.nonZeroExit(
                        executable: execName,
                        exitCode: proc.terminationStatus,
                        lastStderr: lastStderr
                    ))
                } else {
                    continuation.resume()
                }
            }

            do {
                try process.run()
            } catch {
                self.lockedProcess.withLock { $0 = nil }
                continuation.resume(throwing: error)
            }
        }
    }

    /// Convenience for running a command via `/usr/bin/env` (finds executable in PATH).
    func run(
        command: String,
        arguments: [String] = [],
        workingDirectory: String? = nil,
        environment: [String: String]? = nil,
        onOutput: @escaping @Sendable (String) -> Void
    ) async throws {
        try await run(
            executablePath: "/usr/bin/env",
            arguments: [command] + arguments,
            workingDirectory: workingDirectory,
            environment: environment,
            onOutput: onOutput
        )
    }

    // MARK: - Private

    private func appendStderr(_ line: String) {
        lockedRecentStderr.withLock { lines in
            lines.append(line)
            if lines.count > Self.stderrRingCapacity {
                lines.removeFirst(lines.count - Self.stderrRingCapacity)
            }
        }
    }

    private func lastMeaningfulStderr() -> String? {
        let recent = lockedRecentStderr.withLock { $0 }
        return recent.last { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }
}
