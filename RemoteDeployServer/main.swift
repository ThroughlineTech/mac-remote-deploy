// Headless entry point for the RemoteDeployServer process. TKT-060 (Phase 6).
//
// A plain AppKit executable (no SwiftUI `App`, no `@main` -- this file's top-level
// code IS the entry point). LSUIElement=true in Info.plist keeps it out of the
// Dock and menu bar; `.accessory` activation policy is belt-and-suspenders. The
// AppKit run loop drives the Tailscale poll timer and the NIO event loop, so a
// headless executable still needs `NSApplication.run()`.
//
// `NSApplication.delegate` is a weak reference; `app.run()` never returns, so the
// local `delegate` stays retained for the process lifetime. The setup runs on the
// process's main thread at launch, so it is safe to assume main-actor isolation.
import AppKit

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = ServerLifecycle()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
