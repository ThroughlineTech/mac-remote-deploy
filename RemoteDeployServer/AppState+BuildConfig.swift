// TKT-060 (Phase 6): server-only conformance.
//
// AppState is dual-compiled into the menu bar (UI state) and the headless server
// (the build config holder). `BuildConfigProviding` is a server protocol, so its
// conformance lives here, in the server target only -- the menu bar's copy of
// AppState carries no server dependency.
//
// AppState already publishes every member the protocol requires (serverURL,
// serverPort, certPath, keyPath, serverRunning), so the conformance is empty: the
// server's BuildCoordinator reads server/TLS config straight off the AppState it
// holds as a plain config object (no SwiftUI involved). TKT-054 (Phase 1).
import Foundation

extension AppState: BuildConfigProviding {}
