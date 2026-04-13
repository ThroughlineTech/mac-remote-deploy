@testable import RemoteDeploy
import Foundation

/// Records process invocations for verifying ExpoBuildEngine phase sequencing.
/// Each call to `run(command:...)` records the command and arguments, then
/// returns immediately (or throws if configured). TKT-048.
final class MockProcessRunner: ProcessRunning, @unchecked Sendable {

    // MARK: - Recorded Invocations

    struct Invocation: Equatable, Sendable {
        let command: String
        let arguments: [String]
        let workingDirectory: String?
    }

    private let lock = NSLock()
    private var _invocations: [Invocation] = []

    /// All process invocations recorded so far, in order.
    var invocations: [Invocation] {
        lock.withLock { _invocations }
    }

    // MARK: - Cancellation

    private var _isCancelled = false

    var isCancelled: Bool {
        lock.withLock { _isCancelled }
    }

    func cancel() {
        lock.withLock { _isCancelled = true }
    }

    func reset() {
        lock.withLock { _isCancelled = false }
    }

    // MARK: - Stubbed Behavior

    /// If set, `run(command:...)` throws this error for the command name that matches the key.
    /// For example: `errorsByCommand["npm"] = SomeError()` makes `npm install` fail.
    var errorsByCommand: [String: Error] = [:]

    /// If set, every `run` call throws this error regardless of command.
    var globalError: Error?

    // MARK: - ProcessRunning

    func run(
        command: String,
        arguments: [String] = [],
        workingDirectory: String? = nil,
        environment: [String: String]? = nil,
        onOutput: @escaping @Sendable (String) -> Void
    ) async throws {
        lock.withLock {
            _invocations.append(Invocation(command: command, arguments: arguments, workingDirectory: workingDirectory))
        }

        if let error = globalError {
            throw error
        }
        if let error = errorsByCommand[command] {
            throw error
        }

        // Emit a synthetic log line so tests can verify streaming works.
        onOutput("[\(command)] ok")
    }
}
