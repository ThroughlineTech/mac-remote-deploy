// Verifies the headless server's startup runs exactly once. TKT-060 (Phase 6)
// successor to AppDelegateStartupTests: the old fused AppDelegate used a SwiftUI
// register/launch handshake (TKT-019); ServerLifecycle owns its objects and runs
// startup straight from applicationDidFinishLaunching, so the only invariant left
// to guard is "performStartup runs once."
//
// Both cases drive through the public surface and observe via the
// `performStartupOverrideForTests` seam, which replaces the real startup body
// (Tailscale CLI, settings I/O, NIO bind) with a counter.
@testable import RemoteDeployServer
import XCTest
import Foundation

@MainActor
final class ServerLifecycleTests: XCTestCase {

    /// Spins the run loop briefly so the Task dispatched from
    /// applicationDidFinishLaunching runs before assertions.
    private func drainMainQueue() async {
        for _ in 0..<40 {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 5_000_000) // 5 ms
        }
    }

    func test_performStartup_runsOverrideExactlyOnce() async {
        let lifecycle = ServerLifecycle()
        var count = 0
        lifecycle.performStartupOverrideForTests = { count += 1 }

        await lifecycle.performStartup()
        // The didPerformStartup guard must collapse a second call into a no-op.
        await lifecycle.performStartup()

        XCTAssertTrue(lifecycle.didPerformStartup)
        XCTAssertEqual(count, 1, "Startup must run exactly once")
    }

    func test_applicationDidFinishLaunching_triggersStartupOnce() async {
        let lifecycle = ServerLifecycle()
        var count = 0
        lifecycle.performStartupOverrideForTests = { count += 1 }

        lifecycle.applicationDidFinishLaunching(Notification(name: Notification.Name("test")))
        await drainMainQueue()

        XCTAssertTrue(lifecycle.didPerformStartup)
        XCTAssertEqual(count, 1, "applicationDidFinishLaunching must run startup exactly once")
    }
}
