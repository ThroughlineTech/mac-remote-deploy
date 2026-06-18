// Thread-safe holder for live, non-persisted runtime status the API status
// endpoint reports but settings.json does not store. TKT-055 (Phase 2): lets
// ServerStatusProvider read `tailscaleConnected` without snapshotting AppState,
// which is what the deleted AppStateBridge used to do.
//
// AppState keeps its own `@Published tailscaleConnected` for the menu bar icon;
// AppDelegate's Tailscale poll is the single writer that updates both.
import Foundation
import os

final class RuntimeStatusStore: @unchecked Sendable {

    private let locked = OSAllocatedUnfairLock<Bool>(initialState: false)

    /// Whether Tailscale is currently connected. Thread-safe; read from the NIO
    /// event loop by the status provider, written by the Tailscale poll.
    var tailscaleConnected: Bool {
        get { locked.withLock { $0 } }
        set { locked.withLock { $0 = newValue } }
    }
}
