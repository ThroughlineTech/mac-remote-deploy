// Verifies AppDelegate's register/launch ordering guards from TKT-019.
// Covers:
//   1. register() → applicationDidFinishLaunching() — startup runs exactly once
//   2. applicationDidFinishLaunching() → register() — startup runs exactly once
//   3. applicationDidFinishLaunching() alone with no register() — startup does NOT run
//
// Tests drive through the public register/applicationDidFinishLaunching surface
// and observe behavior via the `performStartupOverrideForTests` test seam, which
// replaces the real startup body (Tailscale CLI, settings I/O, server bind) with
// a counter closure.
@testable import RemoteDeploy
import XCTest
import Foundation

@MainActor
final class AppDelegateStartupTests: XCTestCase {

    private var delegate: AppDelegate!
    private var appState: AppState!
    private var serviceContainer: ServiceContainer!
    private var buildManager: BuildManager!
    private var startupCallCount: Int!

    override func setUp() async throws {
        try await super.setUp()
        delegate = AppDelegate()
        appState = AppState()
        serviceContainer = ServiceContainer()
        buildManager = BuildManager()
        startupCallCount = 0

        // Test seam: increments on each performStartup invocation. The real
        // performStartup body is skipped, so no I/O or network calls fire.
        delegate.performStartupOverrideForTests = { [weak self] in
            self?.startupCallCount += 1
        }
    }

    override func tearDown() async throws {
        delegate = nil
        appState = nil
        serviceContainer = nil
        buildManager = nil
        startupCallCount = nil
        try await super.tearDown()
    }

    /// Drains any pending main-queue work scheduled via DispatchQueue.main.async +
    /// Task { @MainActor in }. AppDelegate dispatches startup via both; this helper
    /// spins the run loop briefly so those continuations run before assertions.
    private func drainMainQueue() async {
        // Must outlast the AppDelegate's 150ms asyncAfter delay (TKT-021
        // fallback) plus a margin for the subsequent Task hop. 60 * 5ms = 300ms.
        for _ in 0..<60 {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 5_000_000) // 5 ms
        }
    }

    // MARK: - Case A: register → launch

    func test_registerThenLaunch_runsStartupExactlyOnce() async {
        // register() is called first. It dispatches startup (NSApp != nil in
        // the XCTest environment).
        delegate.register(
            appState: appState,
            serviceContainer: serviceContainer,
            buildManager: buildManager
        )

        // Then the OS fires applicationDidFinishLaunching. Its dispatch path
        // also tries to kick off startup, but the didPerformStartup guard must
        // collapse the second call into a no-op.
        delegate.applicationDidFinishLaunching(Notification(name: Notification.Name("test")))

        await drainMainQueue()

        XCTAssertTrue(delegate.didPerformStartup)
        XCTAssertEqual(startupCallCount, 1, "Startup must run exactly once when register precedes launch")
    }

    // MARK: - Case B: launch → register

    func test_launchThenRegister_runsStartupExactlyOnce() async {
        // applicationDidFinishLaunching fires first. Because didRegister is
        // still false, its dispatch path should skip scheduling startup.
        delegate.applicationDidFinishLaunching(Notification(name: Notification.Name("test")))

        await drainMainQueue()
        XCTAssertFalse(delegate.didPerformStartup, "Startup must not run before register() provides state objects")
        XCTAssertEqual(startupCallCount, 0)

        // Now register() is called. It sees that launch has already happened
        // (NSApp != nil) and dispatches startup.
        delegate.register(
            appState: appState,
            serviceContainer: serviceContainer,
            buildManager: buildManager
        )

        await drainMainQueue()

        XCTAssertTrue(delegate.didPerformStartup)
        XCTAssertEqual(startupCallCount, 1, "Startup must run exactly once when launch precedes register")
    }

    // MARK: - Case C: launch only, no register

    func test_launchWithoutRegister_doesNotRunStartup() async {
        // No register() call. applicationDidFinishLaunching's dispatch path
        // checks `if didRegister, !didPerformStartup` — should short-circuit.
        delegate.applicationDidFinishLaunching(Notification(name: Notification.Name("test")))

        await drainMainQueue()

        XCTAssertFalse(delegate.didPerformStartup, "Startup must not run when register() is never called")
        XCTAssertEqual(startupCallCount, 0)
    }

    // MARK: - Register is idempotent

    func test_registerCalledTwice_stillRunsStartupOnlyOnce() async {
        delegate.register(
            appState: appState,
            serviceContainer: serviceContainer,
            buildManager: buildManager
        )
        delegate.register(
            appState: appState,
            serviceContainer: serviceContainer,
            buildManager: buildManager
        )

        await drainMainQueue()

        XCTAssertEqual(startupCallCount, 1, "Repeated register() calls must not re-run startup")
    }
}
