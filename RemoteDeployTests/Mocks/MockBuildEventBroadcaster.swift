// Test double for BuildEventBroadcasting. Records every call into public
// arrays so tests can assert on the sequence and payload of broadcasts.
// TKT-027.
@testable import RemoteDeploy
import Foundation
import RemoteDeployShared

final class MockBuildEventBroadcaster: BuildEventBroadcasting, @unchecked Sendable {

    /// Ordered log lines passed to `broadcastBuildLog`.
    private(set) var buildLogCalls: [String] = []

    /// Ordered build status values passed to `broadcastBuildStatus`.
    private(set) var buildStatusCalls: [BuildStatus] = []

    /// Ordered install events passed to `broadcastInstall`.
    private(set) var installCalls: [(slug: String, sourceIP: String)] = []

    /// Lock protecting the mutable arrays. Broadcasts can arrive from
    /// multiple threads in integration-style tests.
    private let lock = NSLock()

    func broadcastBuildLog(_ line: String) {
        lock.lock(); defer { lock.unlock() }
        buildLogCalls.append(line)
    }

    func broadcastBuildStatus(_ status: BuildStatus) {
        lock.lock(); defer { lock.unlock() }
        buildStatusCalls.append(status)
    }

    func broadcastInstall(slug: String, sourceIP: String) {
        lock.lock(); defer { lock.unlock() }
        installCalls.append((slug: slug, sourceIP: sourceIP))
    }

    /// Test helper to snapshot the current call counts without holding the lock.
    func snapshot() -> (buildLog: Int, buildStatus: Int, install: Int) {
        lock.lock(); defer { lock.unlock() }
        return (buildLogCalls.count, buildStatusCalls.count, installCalls.count)
    }
}
