# Phase 6 - Physical process split (agent handoff for Stage C/D/E)

## How to use this doc

This is a self-contained handoff so a fresh agent can implement the rest of
Phase 6 (TKT-060). Read this whole file, then `docs/backend-decoupling-plan.md`
Phase 6 + the `## macOS constraint` section, then `tickets/TKT-060.md`. The
foundational work (Stages A + B) is already merged to `main`; this doc covers
Stages C (target split), D (packaging), and E (the human ship gate). Each stage
ends with a gate; do not advance past a red gate.

Build: `xcodebuild build -project RemoteDeploy.xcodeproj -scheme RemoteDeploy -destination 'platform=macOS'`
Test:  `xcodebuild test  -project RemoteDeploy.xcodeproj -scheme RemoteDeploy -destination 'platform=macOS'`
Toolchain: `export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer` (Xcode 27 beta).
Project is XcodeGen-managed: edit `project.yml`, never the `.xcodeproj`; run
`xcodegen generate` after any target/source change. `Resources/pwa/**` is a
bundled folder reference. ASCII only. Keep files under ~300 lines.

## Status going in (what Stages A + B already did, on main)

- Stage A (commit `2c0709a`): added the server endpoints the split needs, with
  tests in `RemoteDeployTests/API/Phase6EndpointsTests.swift`:
  - `POST /api/v1/pair/pending` -> `PairingRouteHandler.mintPending` (mint a
    one-time pairing token for another device).
  - `POST/GET /api/v1/tailscale/cert` -> `TailscaleRouteHandler` over the
    `CertProvisioning` seam (`TailscaleCertProvisioner`): runs `tailscale cert`
    in the background, persists cert/key paths via `SettingsStore`, poll for
    state. Fire-and-forget + poll (matches the build pattern; the router is
    synchronous and must not block the event loop).
  - `POST /api/v1/projects/:id/ipa` -> `IPAUploadRouteHandler` (raw IPA bytes in
    the body, `?filename=`; stages to a temp dir, hands off to `IPAImporter`).
  - Shared types in `Packages/RemoteDeployShared/.../API/APITypes.swift`:
    `PendingPairingResponse`, `CertProvisioningState`, `IPAUploadResponse`;
    `APIClient` methods `mintPairingToken`, `provisionCertificate`,
    `certificateStatus`, `uploadIPA`.
- Stage B (commit `ea3c125`): every menu bar view now drives setup/pairing/IPA
  through `MenuBarClient` (the loopback API client). VERIFIED FACT that makes
  the split tractable: the only server-side `ServiceContainer` reference left in
  any view is `serviceContainer.notificationManager` (in
  `Views/MenuBar/UtilitiesSection.swift`, 4 uses). No view uses `buildManager`.
  `MenuBarClient` gained: `browseFilesystem`, `detectSchemes`,
  `mintPairingToken`, `provisionCertificate`, `certificateStatus`, `uploadIPA`.

Re-confirm before starting C: `grep -rn "serviceContainer\." RemoteDeploy/Views`
should show ONLY `notificationManager`.

## Goal + gate (Phase 6)

Run the backend (NIO server + BuildCoordinator + stores + Tailscale poll +
Bonjour + settings + push) as a separate headless LaunchAgent process; the menu
bar becomes a pure client process. Done when the server keeps serving + building
for web/iOS clients with the menu bar quit, and the menu bar reconnects on
relaunch (Stage E, needs the real Mac + Tailscale).

Both processes still run as per-user LaunchAgents in the Aqua login session (the
macOS constraint - no pre-login daemon). The payoff is lifecycle decoupling, not
headless/background operation.

---

## Stage C - the two-target split

> ### IMPLEMENTATION STATUS (2026-06-18) - STAGE C COMPLETE + GATE GREEN
>
> Stage C is implemented AND the C.6 gate passes (verified once
> `/Volumes/Mac Storage` was remounted):
> - `xcodebuild build -scheme RemoteDeployServer` -> BUILD SUCCEEDED.
> - `xcodebuild build -scheme RemoteDeploy` (menu bar) -> BUILD SUCCEEDED.
> - `xcodebuild test -scheme RemoteDeployServer` -> 422 unit + 21 integration
>   tests, 0 failures (incl. new ServerLifecycleTests; Phase6EndpointsTests now
>   hosted on RemoteDeployServer).
> Build-fallout fix applied on resume: `EnvironmentChecker.swift` is now
> dual-compiled into the menu bar target (ProjectSetupStep shows Expo env
> warnings; it is a dependency-free local introspection enum).
> Committed on branch `tkt-060-stage-c` (Stage C = commit c134e78).
>
> **Stage D (packaging) is also DONE** (commit on the same branch): new
> `LaunchAgent/com.remotedeploy.server.plist` (headless backend) +
> `com.remotedeploy.app.plist` repurposed as the menu bar client agent;
> `build-release.sh` builds both products (`--product all|server|menubar`);
> `deploy.sh` installs both apps + both agents (server first); `ship-deploy.sh`
> allowlist includes `^RemoteDeployServer/`. Validated with `bash -n` + `plutil
> -lint` + `ship-deploy --dry-run`; the full notarized release was NOT run here
> (outward-facing + quota - it runs at deploy time).
>
> **Only Stage E remains - the hardware ship gate, operator-run** (this branch is
> not merged to main yet; merge after Stage E passes):
> 1. `./deploy.sh` (fast) or `./deploy.sh --release` to install both products.
> 2. Confirm both agents are up:
>    `launchctl print gui/$(id -u)/com.remotedeploy.server` and
>    `.../com.remotedeploy.app`; server log `/tmp/remotedeploy.server.log`.
> 3. Quit the menu bar (Cmd-Q). Confirm the web PWA / iOS companion can still
>    list projects and run a build (server keeps serving).
> 4. Relaunch the menu bar; confirm it reconnects (reads the loopback token) and
>    shows live state. Re-run the Phase 5 flows (create project / edit settings /
>    pair) to confirm no regression across the split.
>
> **What was implemented (new/changed/deleted files)**
> - NEW server target dir `RemoteDeployServer/`: `main.swift` (top-level
>   `MainActor.assumeIsolated { NSApplication + ServerLifecycle; app.run() }`,
>   `.accessory` policy), `ServerLifecycle.swift` (the moved AppDelegate startup),
>   `ServiceContainer.swift` (moved verbatim out of RemoteDeployApp.swift),
>   `ServerNotifications.swift` (`.projectsDidChange` + `.settingsDidChange`),
>   `AppState+BuildConfig.swift` (server-only `BuildConfigProviding` conformance),
>   `Info.plist` (LSUIElement, `com.remotedeploy.server`), entitlements (network
>   server/client + user-selected files).
> - NEW `RemoteDeploy/Services/LoopbackTokenStore.swift` (dual-compiled): canonical
>   device name + atomic 0600 read/write of
>   `~/Library/Application Support/RemoteDeploy/loopback_token`.
> - NEW `RemoteDeploy/MenuBarAppDelegate.swift`: requests notification permission,
>   reads/applies the loopback token (re-applies on rotation), and MIRRORS
>   `MenuBarClient.status`/`projects` into `AppState` on a 1.5s diff-guarded loop
>   (one-time settings fetch for push config; best-effort first-run setup open).
> - REWRITTEN `RemoteDeploy/RemoteDeployApp.swift`: slim `@main`; only `AppState` +
>   `MenuBarClient`; `@NSApplicationDelegateAdaptor(MenuBarAppDelegate.self)`; owns
>   only `.openSetupAssistant`.
> - DELETED `RemoteDeploy/AppDelegate.swift` (logic split into ServerLifecycle +
>   MenuBarAppDelegate). DELETED `RemoteDeployTests/AppDelegateStartupTests.swift`,
>   replaced by `RemoteDeployTests/ServerLifecycleTests.swift` (run-once guard).
> - EDITED views to drop `ServiceContainer`: `MenuBarView` (popover refresh now
>   `menuBarClient.refreshNow()`), `SettingsView` (Restart button re-applies
>   settings via the client; dropped the serviceContainer pass to Projects tab),
>   `UtilitiesSection` (uses `NotificationManager.shared`). `AppState.swift` lost
>   its `BuildConfigProviding` conformance (moved server-side).
> - `project.yml`: narrowed `RemoteDeploy` (client; explicit source list; dropped
>   NIO deps), added `RemoteDeployServer` target + scheme, repointed both test
>   targets' host to `RemoteDeployServer`. 63 test files repointed
>   `@testable import RemoteDeploy` -> `RemoteDeployServer` (whole-word sed).
>
> **Decisions / deviations from the original blueprint below**
> - TEST HOST: existing test targets are hosted on `RemoteDeployServer` (NOT a new
>   `RemoteDeployClientTests` target). `ProjectSetupValidators.swift` is
>   DUAL-COMPILED into the server (listed explicitly in its `sources`) so
>   `ProjectSetupValidatorsTests` + `ExpoProjectFixtureTests` compile under the
>   server host without dragging in `Views/**`.
> - `QRCodeGenerator` is compiled into BOTH targets (the C.5 sketch's exclusion was
>   WRONG: `BonjourAdvertiser` and `ServerLifecycle.checkTailscaleStatus` use
>   `QRCodeGenerator.localIPAddress()`). The server's `Services/**` excludes ONLY
>   `MenuBarClient.swift`.
> - MIRROR over repoint: the wizard/pairing/SetupComplete views still read
>   `AppState` server-sourced fields; rather than repoint ~12 untestable views, the
>   menu bar mirrors client state into AppState. Watch for mirror timing in Stage E.
> - `reconcileHTTPS()` was made restart-on-config-diff (was start-only) so a
>   port/cert-path change made via the menu bar's API PUT rebinds HTTPS live across
>   the process boundary (replacing the old in-process `.restartServerRequested`).
>   LIMITATION: a cert REPLACED at the SAME path still needs a manual relaunch.
>
> ---

### C.1 File categorization

Data models + the API client/contract already live in the shared package
(`Packages/RemoteDeployShared`): `APIClient`, `WebSocketClient`, `APIEndpoint`,
`APITypes`, and the models `ProjectConfig`, `SettingsData`, `PushNotificationConfig`,
`BuildResult`, `InstallRecord`, `PairedDevice`, plus `RemoteDeployError`. Both
targets depend on the package, so these need no bucketing.
`RemoteDeploy/Models/{ProjectConfig,SettingsData,PushNotificationConfig,BuildResult,InstallRecord}.swift`
are one-line `@_exported import` shims - harmless in both targets.

MENU BAR target (`RemoteDeploy`, the existing app) - client only:
- `RemoteDeployApp.swift` (REWRITE - see C.3), all of `Views/**` (21 files),
  `Models/AppState.swift`, `Services/MenuBarClient.swift`.
- Local helpers it needs: `Services/NotificationManager.swift`,
  `Services/QRCodeGenerator.swift`, `Services/ProwlNotifier.swift`,
  `Services/PushoverNotifier.swift`, `Services/NtfyNotifier.swift`,
  `Protocols/PushNotifying.swift`, `Logging.swift`.
  (Push notifier CLIENTS are used by `PushNotifSetupStep` "Send Test"; they make
  outbound HTTP - fine in the client process.)
- Must NOT include: `NIODeployServer*`, `HTTPHandler`, `NIOResponseGenerator`,
  `API/**`, `Managers/BuildManager`, `Services/BuildCoordinator`, the engines,
  stores, providers, Bonjour, Tailscale CLI, cert provider, `IPAImporter`,
  `AppDelegate.swift`.

SERVER target (`RemoteDeployServer`, NEW, headless LSUIElement):
- `API/**` (router, routes incl. the 3 Phase-6 handlers, factory, auth),
  `Managers/BuildManager.swift`, `Protocols/**` (all), and `Services/**` server
  side: `NIODeployServer.swift`, `NIODeployServer+BuildEventBroadcasting.swift`,
  `HTTPHandler.swift`, `NIOResponseGenerator.swift`, `BuildCoordinator.swift`,
  `BuildEngineRouter.swift`, `XcodeBuildEngine.swift`, `ExpoBuildEngine.swift`,
  `CLITailscaleProvider.swift`, `TailscaleCertificateProvider.swift`,
  `TailscaleCertProvisioner.swift`, `IPAImporter.swift`, `InstallPageGenerator.swift`,
  `ManifestGenerator.swift`, `JSONBuildHistoryStore.swift`,
  `JSONPairedDeviceStore.swift`, `UserDefaultsProjectStore.swift`,
  `SettingsStore.swift`, `RuntimeStatusStore.swift`, `ServerInstallTracker.swift`,
  `LocalDeployManager.swift`, `ProcessRunner.swift`, `EnvironmentChecker.swift`,
  `BonjourAdvertiser.swift`.
- A NEW headless entry point (see C.2).
- Also needs (compile into BOTH targets): `Logging.swift`,
  `Services/NotificationManager.swift` (BuildManager posts desktop
  notifications), `Models/AppState.swift` (reused as the server's config holder -
  see C.2). NOTE: AppState is `@MainActor ObservableObject` but can be used
  without SwiftUI.
- Does NOT need `Views/**`, `RemoteDeployApp.swift`, `MenuBarClient.swift`,
  `QRCodeGenerator.swift`, the push notifier clients (it has its own via
  `ServiceContainer.configurePushNotifiers`). It CAN include them harmlessly,
  but excluding keeps the boundary clean. It MUST NOT include the menu bar
  `@main` (two `@main` = error).

Files compiled into BOTH targets via duplicate `sources` entries (they are
AppKit-bound, so cannot move into the cross-platform package): `Logging.swift`,
`Services/NotificationManager.swift`, `Models/AppState.swift`. (Push notifier
clients + `PushNotifying` are needed by both; either duplicate them or accept
the server already owning them and only list them in the menu bar target.)

### C.2 Headless server entry point + lifecycle

Create `RemoteDeployServer/main.swift` (new dir for the new target's own files).
Move the server-owning logic out of `RemoteDeploy/AppDelegate.swift` into a
`ServerLifecycle` (or a headless `NSApplicationDelegate`). It must replicate, in
order, `AppDelegate.performStartup()` MINUS the UI/menu-bar bits:

- Build a server-side `ServiceContainer` (the existing one is fine; it has no
  UI deps) + an `AppState` instance used purely as the config holder
  (serverPort/hostname/certPath/keyPath) that `BuildCoordinator` and
  `startServer` read.
- `buildManager.configure(...)`, construct `BuildCoordinator`.
- `loadSettings()` / `applySettingsFromStore()`, `refreshProjectsFromStore()`,
  `configurePushNotifiers(...)`, `checkTailscaleStatus()`.
- `prepareServer()` (API router + :8080 listener), `startServer()` (HTTPS),
  `startStatusPolling()`, Bonjour.
- The reconcilers `handleProjectsDidChange` / `handleSettingsDidChange` /
  `handleRestartServerRequested` (these fire from in-process `SettingsStore` /
  `projectStore` writes, which now happen in THIS process because all writes
  route through the server's API).
- `applicationWillTerminate`: stop NIO + Bonjour (TKT-050 port release).
- Mint the loopback token (see C.4).

A headless macOS executable needs a run loop for the timers/NIO; an
`NSApplication` + `LSUIElement` app delegate with no windows/menu bar works. Keep
it `@MainActor` like the current AppDelegate.

The current `AppDelegate.swift` references `appState`, `buildManager`,
`menuBarClient` (UI objects). In the server, there is no `menuBarClient` and no
UI; AppState becomes a plain config object. Strip the menu-bar-client wiring
(`configureMenuBarClient` becomes "mint + write loopback token", C.4).

### C.3 Menu bar @main rewrite (RemoteDeployApp.swift)

The menu bar no longer starts a server. Rewrite so it:
- Drops the server-owning `ServiceContainer` (NIODeployServer, stores, engines,
  coordinator, Bonjour, Tailscale, cert, ipaImporter, settings/runtime stores).
  Keep only what views need: `AppState`, `MenuBarClient`, and a
  `NotificationManager` (for `UtilitiesSection`). Simplest: a tiny
  `MenuBarServices` object holding just `notificationManager`, or inject
  `NotificationManager` directly. (`UtilitiesSection` is the only view using it.)
- At startup: read the loopback token (C.4) and call
  `menuBarClient.configure(baseURL: http://127.0.0.1:8080, token:)`. If the
  token file is absent (server not up yet), retry on a short timer.
- Keep the menu bar `@NSApplicationDelegateAdaptor` only if still needed for
  app activation; it must NOT do server startup.
- Drop the `.startServerRequested` / `.saveSettingsRequested` /
  `.restartServerRequested` posting paths that targeted the in-process server
  (the wizard's `onStartServer` is now a no-op or triggers a status refresh - the
  server auto-starts HTTPS when certs are configured via reconcileHTTPS).

### C.4 Cross-process loopback token handoff

Today `AppDelegate.configureMenuBarClient()` mints a token, writes its hash to
`paired_devices.json` (read by the server's auth on every request), and hands the
raw token to the in-process `MenuBarClient`. Across processes:
- SERVER at startup: mint the token, write the hash to `paired_devices.json`
  (unchanged), AND write the RAW token to
  `~/Library/Application Support/RemoteDeploy/loopback_token` with 0600 perms.
  Replace any prior "Menu bar (local)" device record so exactly one is valid.
- MENU BAR at startup: read that file; configure `MenuBarClient` with it. Poll
  if absent. This avoids needing the server's token hashing in the menu bar
  (`JSONPairedDeviceStore` is server-only).
Security note: the raw token on disk (0600, user-owned, app support) is
equivalent in blast radius to the existing hash-in-json; acceptable for loopback.
Consider Phase 7 for hardening.

### C.5 project.yml

Add a `RemoteDeployServer` target and keep `RemoteDeploy` as the client. Sketch:

```yaml
  RemoteDeployServer:
    type: application
    platform: macOS
    deploymentTarget: { macOS: "14.0" }
    sources:
      - path: RemoteDeployServer            # new: main.swift + ServerLifecycle
      - path: RemoteDeploy/API
      - path: RemoteDeploy/Managers
      - path: RemoteDeploy/Protocols
      - path: RemoteDeploy/Models            # AppState + @_exported shims
      - path: RemoteDeploy/Logging.swift
      - path: RemoteDeploy/Services
        excludes: ["MenuBarClient.swift", "QRCodeGenerator.swift"]
      # Resources/pwa is served by the server:
      - path: RemoteDeploy/Resources/pwa
        buildPhase: resources
        type: folder
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.remotedeploy.server
        INFOPLIST_FILE: RemoteDeployServer/Info.plist      # LSUIElement=true
        CODE_SIGN_ENTITLEMENTS: RemoteDeployServer/RemoteDeployServer.entitlements
        DEVELOPMENT_TEAM: RDJQ523WP4
        PRODUCT_NAME: RemoteDeployServer
    dependencies: [ RemoteDeployShared, NIO, NIOHTTP1, NIOFoundationCompat, NIOWebSocket, NIOSSL ]
```

Then the menu bar `RemoteDeploy` target's `sources` must be narrowed to the
client file set (C.1) and EXCLUDE `AppDelegate.swift`, `API/**`,
`Managers/**`, the server `Services/**`, server `Protocols/**`. Easiest: list the
client files explicitly rather than the whole `RemoteDeploy` dir. The menu bar
drops the NIO/NIOSSL package deps (keeps `RemoteDeployShared`).

Add a `RemoteDeployServer` scheme (test target stays on `RemoteDeploy` scheme
which builds the server-side code today; verify the `RemoteDeployTests` /
`RemoteDeployIntegrationTests` targets depend on `RemoteDeployServer` after the
move, since they `@testable import RemoteDeploy` server code - they will need to
import `RemoteDeployServer` instead, OR keep the server code testable by making
the tests depend on the server target). THIS IS THE BIGGEST TEST-WIRING RISK:
~445 existing tests `@testable import RemoteDeploy` and exercise server code.
After the move, repoint them to `@testable import RemoteDeployServer` and make
the test targets depend on it. Plan for a sweep of the test target imports.

Server Info.plist: `LSUIElement=true`, bundle id `com.remotedeploy.server`.
Server entitlements: `com.apple.security.network.server` + `.network.client` +
`com.apple.security.files.user-selected.read-write` (same as today's app). Verify
codesign + login-keychain access work from the agent (same Aqua session, so it
inherits the login keychain; sanity-check `tailscale cert` + xcodebuild signing).

### C.6 Stage C gate
- `xcodegen generate` then BOTH targets build:
  `xcodebuild build -scheme RemoteDeploy ...` and `-scheme RemoteDeployServer ...`.
- Full test suite green (repointed at the server target).
- Only the server binds :8080/:8443; the menu bar binds nothing.

---

## Stage D - packaging two products

- `LaunchAgent/com.remotedeploy.app.plist` currently points at
  `/Applications/RemoteDeploy.app/Contents/MacOS/RemoteDeploy` with
  `RunAtLoad`, `KeepAlive{SuccessfulExit:false}`, `ProcessType:Interactive`.
  Make it run the SERVER: `/Applications/RemoteDeployServer.app/...`. Add a
  second mechanism for the menu bar: a login item via `SMAppService` (macOS 13+)
  or a second LaunchAgent. Only the server binds ports.
- `scripts/build-release.sh`: `APP_NAME`/scheme are hardcoded `RemoteDeploy`
  (lines ~28, 66, 76) - parameterize to build + sign + notarize BOTH products.
- `deploy.sh`: hardcodes `APP_NAME`, `BUNDLE_ID=com.remotedeploy.app`,
  `PLIST_LABEL`, `PORT` - parameterize / loop over both products; install both to
  /Applications; install the server LaunchAgent + register the menu bar login item.
- `scripts/ship-deploy.sh`: extend the host-code allowlist if paths move under
  `RemoteDeployServer/`. `graceful-relaunch.sh` is generic (takes app name) - no
  change beyond which app names it is called with.

## Stage E - human ship gate (REQUIRES the real Mac + Tailscale)

The implementing agent CANNOT verify these; the operator runs them:
1. Quit the menu bar app entirely; confirm the server keeps serving + building
   for the web PWA / iOS companion (trigger a build from the web app; it runs and
   the log streams).
2. Relaunch the menu bar; confirm it reconnects (reads the loopback token) and
   shows live state.
3. Re-run the Phase 5 gate (create project / edit settings / pairing) end to end
   to confirm nothing regressed across the split.

## Gotchas

- Two `@main` types is a hard error; the server target must exclude
  `RemoteDeployApp.swift`.
- The API router (`APIRouter.handle`) is synchronous on the NIO event loop -
  keep new server work off the loop (cert provisioning already uses fire-and-
  forget + poll; follow that pattern).
- In-process `.settingsDidChange`/`.projectsDidChange` reconcilers must live in
  the SERVER process (that is where the store writes happen now, since all writes
  arrive via the server's API). The menu bar's old reconcilers are dead - drop them.
- `~445` tests import the host target's server code via `@testable import
  RemoteDeploy`; after moving server code to `RemoteDeployServer`, repoint imports
  and target dependencies, or the suite will not compile. Budget time for this.
- Watch the `applicationWillTerminate` server-stop (TKT-050) - it must move to the
  server target so `graceful-relaunch.sh` can still confirm port release.
