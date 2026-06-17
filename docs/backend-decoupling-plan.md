# Backend Decoupling Plan (agent handoff)

## How to use this doc

This is a phased work plan written so a fresh agent can be handed a single phase
("work on Phase 3") and have everything it needs. Before starting any phase,
read these three sections: **Background**, **What is broken today**, and
**Project conventions**. Then read your assigned phase end to end. Phases are
ordered; each one lists what it **Depends on**. Do not start a phase whose
dependencies are unmet without flagging it.

Each phase is independently shippable and ends with a **human ship gate** - an
explicit thing a person clicks/runs to confirm the behavior. "Tests green" is
not "shipped."

---

## Background: the architecture as it exists today

RemoteDeploy is a macOS menu bar app that builds iOS/macOS apps with `xcodebuild`
and serves them over-the-air via an HTTPS server over Tailscale. It already has
**three frontends over one HTTP/WebSocket API**:

- The **menu bar app** (`RemoteDeploy/`, SwiftUI `MenuBarExtra`).
- The **iOS companion** (`RemoteDeployCompanion/`), a pure API client.
- A **web PWA** (`RemoteDeploy/Resources/pwa/`), served by the app's own server
  at `/app/`, also a pure API client.

The catch: the "backend" is not a self-contained service. It is fused into the
menu bar GUI process. Concretely:

- `RemoteDeployApp` (`RemoteDeploy/RemoteDeployApp.swift`) owns three SwiftUI
  `@StateObject`s: `AppState`, `BuildManager`, `ServiceContainer`. The menu bar
  UI reads/writes these **in process**.
- `ServiceContainer` also owns the `NIODeployServer` (SwiftNIO + NIOSSL). The
  server exposes REST routes under `/api/v1/` (`RemoteDeploy/API/`) plus a
  WebSocket at `/api/v1/ws` for live build log + status, and serves the PWA
  static files at `/app/` (`servePWAFile` in
  `RemoteDeploy/Services/NIOResponseGenerator.swift`).
- The API does not own state. It **bridges into the in-process objects** via
  `AppStateBridge` (`RemoteDeploy/RemoteDeployApp.swift`, bottom of file) and a
  set of adapter providers in `RemoteDeploy/Services/API/`.
- The router is assembled by `APIRouterFactory.make(deps:)`
  (`RemoteDeploy/API/APIRouterFactory.swift`) from a `Dependencies` bag that
  `AppDelegate.configureAPIRouter(...)` fills with real adapters.

**Request flow for a remote build today (the core problem):**

```
POST /api/v1/projects/:id/build
  -> BuildRouteHandler.triggerBuild
  -> NotificationBuildTrigger  (posts NotificationCenter .apiBuildRequested)
  -> MenuBarView.handleAPIBuildRequest   <-- lives on the popover VIEW
  -> reads appState (serverURL/cert/port) and calls BuildManager.triggerBuild(...)
```

`BuildManager` (`RemoteDeploy/Managers/BuildManager.swift`) is a `@MainActor`
`ObservableObject` that actually runs the build (archive -> export -> copy ->
start server -> notify) via an injected `BuildEngineProtocol`
(`RemoteDeploy/Protocols/BuildEngineProtocol.swift`, implemented by
`BuildEngineRouter` -> `XcodeBuildEngine` / `ExpoBuildEngine`). It is already
decoupled from the view's *rendering*, but it is reached only by the view's
NotificationCenter handler and is driven by values the view supplies.

The iOS companion shows the target shape: `RemoteDeployCompanion/Services/APIClient.swift`
is a complete async client covering every endpoint, and
`RemoteDeployCompanion/Services/WebSocketClient.swift` is a reconnect-with-backoff
WS client. The shared request/response types live in
`Packages/RemoteDeployShared/` (`API/APIEndpoint.swift`, `API/APITypes.swift`,
plus the `Models/`).

---

## What is broken today (verified at SHA 2d4c0fa)

These are the concrete defects this plan fixes. They are evidence, not guesses.

1. **Build execution lives in a view.** See the flow above. The
   `.apiBuildRequested` handler is on `MenuBarView`
   (`RemoteDeploy/Views/MenuBarView.swift`, the `.onReceive(...)` around line 42
   and `handleAPIBuildRequest`). SwiftUI keeps `MenuBarExtra` popover content
   alive only around when the popover has been opened, so remote builds depend on
   the GUI having been interacted with.
2. **Cancel is a no-op.** `NoopBuildCanceler.cancelCurrentBuild()` hard-returns
   `false` (`RemoteDeploy/Services/API/NoopBuildCanceler.swift`) and is still the
   wired implementation (`RemoteDeploy/AppDelegate.swift`, in the `Dependencies`
   build, `buildCanceler: NoopBuildCanceler()`). The engines fully implement
   `cancelBuild()` (`XcodeBuildEngine`, `ExpoBuildEngine`, `BuildEngineRouter`),
   so the capability exists - it is just not wired to the API. Web/iOS "Cancel"
   does nothing.
3. **Two sources of truth for state.** The menu bar holds an in-memory
   `appState.projects` array (mutated in `RemoteDeploy/Views/SettingsView.swift`)
   while the API writes the on-disk `projectStore` (`UserDefaultsProjectStore`).
   A project created via the API is not visible in the menu bar until relaunch.
   The API reads live status only through the `AppStateBridge` snapshot.
4. **The web client cannot authenticate itself.** The PWA Connect screen stores a
   pasted token but never calls `/api/v1/pair` (`RemoteDeploy/Resources/pwa/app.js`,
   `doConnect`), so it only works with an already-paired token; today only the
   iOS QR flow mints one. The token field is also not in a `<form>`, so **Enter
   does not submit** - you must click the Connect button.

---

## Project conventions an agent needs

- **Build:** `xcodebuild build -project RemoteDeploy.xcodeproj -scheme RemoteDeploy -destination 'platform=macOS'`
- **Test:** `xcodebuild test -project RemoteDeploy.xcodeproj -scheme RemoteDeploy -destination 'platform=macOS'`
  (host unit tests are in `RemoteDeployTests/`, integration/server tests in
  `RemoteDeployIntegrationTests/`). Run tests before presenting work.
- **Project is XcodeGen-managed.** `project.yml` is the source of truth for
  targets/files. After adding or moving files, run `xcodegen generate` (the
  `.xcodeproj` is regenerated; do not hand-edit it). New Swift files under
  `RemoteDeploy/` are picked up automatically except `Resources/pwa/**`, which is
  bundled as a folder resource.
- **Run the app locally for manual verification** (atomic relaunch on :8443):
  `scripts/graceful-relaunch.sh RemoteDeploy --port 8443 --no-relaunch; xcodegen generate && xcodebuild build -project RemoteDeploy.xcodeproj -scheme RemoteDeploy -destination 'platform=macOS' -configuration Debug -derivedDataPath /tmp/RemoteDeployPreview && open /tmp/RemoteDeployPreview/Build/Products/Debug/RemoteDeploy.app`
  The released app is also installed at `/Applications/RemoteDeploy.app` and kept
  alive by a LaunchAgent (`LaunchAgent/com.remotedeploy.app.plist`).
- **Mint a test bearer token without the iOS app** (needed to exercise web/API
  flows): write a `PairedDevice` record into
  `~/Library/Application Support/RemoteDeploy/paired_devices.json`. The store
  (`JSONPairedDeviceStore`) reads from disk on every auth check, so no restart is
  needed. The stored field is the SHA-256 hex of the raw token
  (`JSONPairedDeviceStore.hashToken`). Shape per record: `id` (UUID string),
  `name`, `tokenHash`, `pairedAt`/`lastSeen` (ISO-8601, no fractional seconds),
  `pushEndpoint` (nullable). Then call the API with
  `Authorization: Bearer <raw token>`. Local plain-HTTP base is
  `http://localhost:8080`; HTTPS over Tailscale is `https://<host>:8443`.
  Pairing over plain HTTP is blocked by design.
- **Tickets are the record.** This repo uses `tickets/TKT-NNN.md` via the ticket
  workflow (`/ticket-new`, `/ticket-investigate`, `/ticket-ship`). Open a ticket
  per phase. Commit style: `TKT-NNN: short description`. No AI-attribution
  trailers.
- **ASCII only** in code, comments, and docs (no em-dashes/curly quotes). Keep
  source files under ~300 lines; if a change pushes a file past that, factor
  first and flag it.

---

## macOS constraint (read before Phase 6)

`xcodebuild`, code signing, keychain access, and the iOS Simulator must run
inside the user's GUI login (Aqua) session. A pre-login `LaunchDaemon` will not
work. So even a "standalone backend" must run as a per-user **LaunchAgent** in
the logged-in session (which is already how the app is kept alive). The payoff
from splitting the process is decoupling the backend from the UI's lifecycle, not
headless/background operation. This is why Phase 6 is optional: Phases 1-3 already
deliver a UI-independent backend within one process.

## Target architecture

```
            +------------------------------------------+
            |  RemoteDeployCore (self-contained)       |
            |  - NIODeployServer (REST + WS + /app)    |
            |  - BuildCoordinator (owns build/cancel)  |
            |  - Stores: projects, settings, history,  |
            |    installs, paired devices  (truth)     |
            +------------------------------------------+
                 ^              ^               ^
                 | HTTP/WS      | HTTP/WS       | HTTP/WS
            +---------+   +-----------+   +-----------+
            | Menu bar|   |  Web PWA  |   |    iOS    |
            | (client)|   | (browser) |   | companion |
            +---------+   +-----------+   +-----------+
```

All three frontends are equal clients of the same endpoints. The stores and the
coordinator are the single source of truth.

---

## Phase 1 - Extract a headless BuildCoordinator

**Depends on:** nothing. This is the foundation.

**Goal:** build execution and cancellation no longer depend on any view. The
backend can build and cancel a build entirely on its own.

**What you are changing and why.** Today a remote build round-trips through
`MenuBarView.handleAPIBuildRequest`, and cancel is a stub. You will introduce a
`BuildCoordinator` that owns the build lifecycle and is callable directly by the
API, the menu bar button, and (later) any client. `BuildManager`'s orchestration
body (`triggerBuild(...)` in `RemoteDeploy/Managers/BuildManager.swift`) is the
logic to move/wrap - it already does archive -> export -> serve -> notify and
fans live log/status to WebSocket subscribers via `BuildEventBroadcasting`. The
coordinator must source `serverURL`/`certPath`/`keyPath`/`serverPort`/
`serverRunning` from settings/state itself rather than receiving them from the
view (today they are passed in as arguments).

**Relevant files**
- `RemoteDeploy/Managers/BuildManager.swift` - the orchestration to relocate into
  a view-independent coordinator (or keep `BuildManager` as a thin
  `ObservableObject` that forwards to the coordinator so existing `@EnvironmentObject`
  observers in the build-log window keep working).
- `RemoteDeploy/Services/API/NotificationBuildTrigger.swift` - replace with a
  `DirectBuildTrigger` (conforms to `BuildTriggering`) that calls the coordinator
  directly; delete the `.apiBuildRequested` mechanism.
- `RemoteDeploy/Services/API/NoopBuildCanceler.swift` - replace with a real
  `BuildCanceling` that calls the coordinator, which calls
  `buildEngine.cancelBuild()`.
- `RemoteDeploy/Services/API/AppStateBridgeBuildStatusProvider.swift` - repoint at
  the coordinator's status.
- `RemoteDeploy/AppDelegate.swift` - construct/own the coordinator (in
  `ServiceContainer`); in the `APIRouterFactory.Dependencies` build, pass the
  `DirectBuildTrigger` and real canceler instead of the notification/no-op pair.
- `RemoteDeploy/Views/MenuBarView.swift` and
  `RemoteDeploy/Views/MenuBar/BuildControlsSection.swift` - delete
  `handleAPIBuildRequest`; the menu bar build button calls the coordinator.
- `RemoteDeploy/RemoteDeployApp.swift` - remove the `.apiBuildRequested`
  Notification.Name once nothing posts it.

**Steps**
1. Create `BuildCoordinator` (a `@MainActor` service is fine; it does not need to
   be a SwiftUI `ObservableObject`). Move the orchestration from
   `BuildManager.triggerBuild`. Have it read server/cert config from the settings
   source. Keep emitting via `BuildEventBroadcasting` so WS streaming still works.
2. Add `triggerBuild(projectID:configuration:)` and `cancelBuild()` to the
   coordinator. Resolve the `ProjectConfig` from `projectStore` by ID.
3. Wire `DirectBuildTrigger` + the real canceler in `AppDelegate`'s dependency bag.
4. Repoint `BuildStatusProviding` at the coordinator.
5. Delete the NotificationCenter build path and the view handler; point the menu
   bar build button at the coordinator.

**Gotchas**
- `BuildManager` is `@MainActor`; keep the coordinator main-actor-bound or make
  the boundary explicit. The engines are `Sendable`.
- `BuildManager.triggerBuild` also starts the server post-build if it is not
  running and runs macOS local-deploy (TKT-053). Preserve both.
- Tests to keep green / extend: `RemoteDeployTests/BuildManagerBroadcastTests.swift`,
  `RemoteDeployTests/XcodeBuildEngineCancelTests.swift`,
  `RemoteDeployTests/APIRouterFactoryTests.swift`,
  `RemoteDeployTests/BuildEngineRouterTests.swift`.

**Verification (human ship gate)**
- Launch the app and do NOT open the menu bar popover. From the web app, trigger
  a build; confirm it runs and the log streams live over WebSocket.
- Mid-build, click Cancel in the web app; confirm `xcodebuild` actually stops
  (process gone; status returns to a terminal state).
- Trigger a build from the menu bar button; confirm identical behavior.

**Done when:** remote build + cancel work with the popover never opened, and no
build logic remains in any `View`.

---

## Phase 2 - Single source of truth for state

**Depends on:** Phase 1.

**Goal:** eliminate the dual project cache and the `AppStateBridge` snapshot so
every reader (menu bar, API, web, iOS) sees the same data immediately.

**What you are changing and why.** `appState.projects` is an independent in-memory
copy; the API writes `projectStore`. Make the store the authoritative source the
menu bar observes, and have the API providers read the store/coordinator directly
instead of snapshotting `AppState`. After this, `AppStateBridge` should be
deletable.

**Relevant files**
- `RemoteDeploy/Models/AppState.swift`, `RemoteDeploy/Views/SettingsView.swift`,
  `RemoteDeploy/Views/MenuBar/ProjectsListSection.swift` - stop owning a separate
  `projects` array; observe a store-backed source.
- `RemoteDeploy/Services/UserDefaultsProjectStore.swift` - if needed, add change
  notification so observers refresh when the store is written by any path.
- `RemoteDeploy/RemoteDeployApp.swift` (`AppStateBridge`) - remove once the API
  providers no longer snapshot `AppState`.
- `RemoteDeploy/Services/API/AppStateStatusProvider.swift`,
  `AppStateBridgeSettingsProvider.swift`, `DeferredSettingsUpdater.swift` -
  repoint at the coordinator + stores.

**Steps**
1. Introduce one store-backed observable project list both the menu bar and API
   read/write through the same handler logic.
2. Route settings reads/writes through a single path; drop the bridge snapshot.
3. Confirm status / build-history / installs all read from stores or the
   coordinator, then delete `AppStateBridge`.

**Gotchas**
- The server reads project routes off a `lockedProjectsBySlug` registry
  (`NIODeployServer.registerProject`); keep that registry in sync when projects
  change via the API, not just at startup (`AppDelegate.startServer`).
- Settings persistence currently round-trips through `AppDelegate`'s
  `.saveSettingsRequested` NotificationCenter handler and `settings.json`. Keep a
  single writer.

**Verification (human ship gate)**
- Create a project in the web app; confirm it appears in the menu bar list with no
  relaunch. Edit it in the menu bar; confirm the web app sees the edit on refresh.
- Confirm a newly created project's `/<slug>/` install route serves immediately.

**Done when:** there is one source of truth for projects and settings;
`AppStateBridge` is gone.

---

## Phase 3 - Menu bar becomes an API client

**Depends on:** Phases 1 and 2 (the backend must be self-sufficient and the stores
authoritative before the UI can safely talk over HTTP).

**Goal:** the inversion. The menu bar calls the same endpoints as the web/iOS
clients instead of sharing memory. After this, all three frontends are uniform.

> Decision (locked): we are doing the full HTTP-client inversion. The lighter
> "menu bar talks to an in-process core via the client protocol" variant is
> explicitly rejected - do the real work now.

**What you are building.** A macOS API + WebSocket client, modeled on
`RemoteDeployCompanion/Services/APIClient.swift` and
`RemoteDeployCompanion/Services/WebSocketClient.swift`. Prefer **moving the client
into `Packages/RemoteDeployShared/`** so macOS and iOS share one implementation
against the existing `APIEndpoint` contract; if platform glue prevents that,
mirror it under `RemoteDeploy/Services/`. The menu bar then talks to its own
server over loopback.

**Relevant files**
- New: shared `APIClient` + `WebSocketClient` (move from
  `RemoteDeployCompanion/Services/` into `Packages/RemoteDeployShared/Sources/RemoteDeployShared/`,
  or add a macOS twin). Use `Packages/.../API/APIEndpoint.swift` for paths.
- `RemoteDeploy/Views/MenuBar/*` (`ServerStatusSection`, `ProjectsListSection`,
  `BuildControlsSection`, `UtilitiesSection`), `RemoteDeploy/Views/SettingsView.swift`,
  `RemoteDeploy/Views/BuildLogView.swift` - repoint from `@EnvironmentObject`
  in-process objects to the client.
- `RemoteDeploy/AppDelegate.swift` / `RemoteDeployApp.swift` - mint a local
  loopback bearer token for the menu bar at startup (write a `PairedDevice` named
  e.g. "Menu bar (local)") and construct the client against
  `http://127.0.0.1:8080`.

**Steps**
1. Build/relocate the shared client; cover it with a unit test that round-trips
   each endpoint against a stubbed router.
2. At startup, ensure a local token exists and instantiate the client.
3. Convert menu bar sections one at a time: status -> projects (list/create/edit/
   delete) -> build (trigger/cancel + live log via WS) -> installs. Keep each
   conversion shippable.

**Gotchas**
- The menu bar will now depend on the server being up. Define behavior when the
  server is not yet started (cert not configured): show a connecting/disabled
  state, do not crash. The local HTTP listener on :8080 is best-effort and may
  fail to bind; prefer it but handle absence.
- Loopback over plain HTTP avoids TLS-trust friction; pairing-over-HTTP is blocked
  but the menu bar uses a pre-seeded token, so it never calls `/api/v1/pair`.
- Watch for main-actor reentrancy: the client is async; the views are
  `@MainActor`.

**Verification (human ship gate)**
- With the menu bar driven only through the client, exercise every section:
  status reflects reality, project create/edit/delete persist, build runs with a
  live streaming log, cancel works, installs list populates. Confirm parity with
  the pre-Phase-3 behavior.

**Done when:** no menu bar view reads or writes `AppState`/`BuildManager`/stores
directly; all data flows through the client.

---

## Phase 4 - Browser pairing + web client correctness

**Depends on:** the pairing endpoint exists today (`PairingRouteHandler`). Can be
built in parallel with Phases 1-3; logically lands around Phase 3.

**Goal:** the web app can authenticate itself end to end, and the Connect screen
behaves. No more pasting an iOS-minted token.

**Background.** Pairing works by the Mac generating a token, registering its hash
as "pending" (`PairingRouteHandler.registerPendingToken`), then a client POSTing
the raw token to `/api/v1/pair`, which saves a `PairedDevice`. The macOS pairing
sheet (`RemoteDeploy/Views/PairDeviceView.swift`) already generates a token, shows
a QR, and has a "copy token" affordance, but the PWA never calls `/api/v1/pair`.

**Relevant files**
- `RemoteDeploy/Resources/pwa/index.html`, `RemoteDeploy/Resources/pwa/app.js` -
  wrap the token field in a `<form>` so Enter submits; add a pairing flow that
  POSTs `/api/v1/pair` and stores the returned bearer token in `localStorage`.
- `RemoteDeploy/Views/PairDeviceView.swift` (+ a menu bar entry) - a "Pair browser"
  action that surfaces a short-lived code/token the browser can claim. Reuse
  `registerPendingToken`.
- `RemoteDeploy/API/Routes/PairingRouteHandler.swift` - reuse as-is; note the
  global rate limit and 10-minute pending-token expiry.

**Steps**
1. Fix the Connect form so Enter submits (`<form onsubmit=...>` calling
   `doConnect`, `preventDefault`).
2. Add a browser pairing path: the user invokes "Pair browser" on the Mac (menu
   bar), gets a one-time code; the PWA prompts for it, POSTs `/api/v1/pair` with a
   `deviceName` like "Browser", stores the token, and proceeds. Pairing must be
   over HTTPS (blocked on plain HTTP by design).

**Gotchas**
- The PWA must reach the API same-origin; over Tailscale that is HTTPS on :8443.
  Document the URL (`https://<host>:8443/app/`).
- Respect the rate limiter; surface its 429 message to the user.

**Verification (human ship gate)**
- From a fresh browser (cleared `localStorage`), complete pairing end to end and
  reach the project list with no manual token paste. Press Enter on the code field
  and confirm it submits.

**Done when:** a new browser can pair and use the app without the iOS companion.

---

## Phase 5 - Full PWA feature parity

**Depends on:** Phase 4 (a usable, self-authenticating web client). The API
already supports everything below.

**Goal:** the web app can do what the menu bar can - create/edit projects and edit
settings - not just browse and build. This is frontend buildout on the PWA;
**no decoupling work**, which is why it is its own phase.

**Background.** The REST API already exposes the needed endpoints (see
`RemoteDeployCompanion/Services/APIClient.swift` for the full surface):
`POST/PUT/DELETE /api/v1/projects[/:id]`, `PUT /api/v1/settings`,
`GET /api/v1/filesystem/browse` and `/filesystem/schemes` (for picking a project
path + scheme), and `GET/DELETE /api/v1/installs`. The current PWA
(`RemoteDeploy/Resources/pwa/app.js`) only renders read-only Projects, a Build
tab, Installs, and a read-only Settings tab.

**Relevant files**
- `RemoteDeploy/Resources/pwa/app.js`, `style.css`, `index.html` - add project
  create/edit/delete forms and a settings editor. The PWA is intentionally
  dependency-free vanilla JS; keep it that way.

**Steps**
1. Project create/edit/delete UI backed by the projects endpoints; use
   `/filesystem/browse` + `/filesystem/schemes` to pick path and scheme.
2. Settings editor backed by `GET`/`PUT /api/v1/settings` (port, hostname, cert/
   key paths, push config). Validate before submit.
3. Optional: install-record delete actions (endpoints already exist).

**Gotchas**
- Keep the existing same-origin CSP (`servePWAFile` sets it); avoid inline event
  handlers that violate it if you tighten the policy.
- Mirror the macOS validators where relevant
  (`RemoteDeploy/Views/SetupSteps/ProjectSetupValidators.swift`) so the web form
  rejects the same bad input.
- `Resources/pwa/**` is a bundled folder resource; after editing, rebuild so the
  app serves the new files (they are read from `Bundle.main.resourcePath/pwa`).

**Verification (human ship gate)**
- In the browser only: create a new project, build it, edit its scheme, change a
  setting (e.g. port) and confirm the change persists and the menu bar reflects
  it. Delete a test project.

**Done when:** the web app reaches feature parity with the menu bar for projects
and settings.

---

## Phase 6 - Physical process split (optional, gated)

**Depends on:** Phase 3 (menu bar already a client). **Gate:** only do this if you
need the server to run independently of the menu bar app's lifecycle. Re-read the
macOS constraint section first.

**Goal:** run the backend (server + coordinator + stores) as a separate headless
LaunchAgent process; the menu bar app becomes a pure client process.

**Relevant files**
- `project.yml` - add a headless `RemoteDeployServer` target (`LSUIElement`, no
  menu bar) containing the core; the menu bar target depends on the shared client
  package. Run `xcodegen generate` after.
- `LaunchAgent/com.remotedeploy.app.plist` - point at the headless binary; add the
  menu bar as a separate login item.
- Lifecycle code currently in `AppDelegate` (server start, Bonjour, status polling,
  settings load) - moves into the headless target's entry point.

**Steps**
1. Extract the core into the headless target; give it its own `main`/lifecycle.
2. Decide cert/keychain access for the agent (same user session - it inherits the
   login keychain; verify codesign/notarization still works from the agent).
3. Ship the menu bar as a separate client app launched at login, talking to the
   agent over loopback.

**Gotchas**
- Two processes means two things wanting :8080/:8443 - only the agent binds; the
  menu bar must not start a server.
- Notarization/release pipeline (`scripts/build-release.sh`,
  `scripts/ship-deploy.sh`) and the LaunchAgent installer (`deploy.sh`) need
  updating for two products.

**Verification (human ship gate)**
- Quit the menu bar app entirely; confirm the service keeps serving and building
  for the web/iOS clients. Relaunch the menu bar; confirm it reconnects and shows
  live state.

**Done when:** the backend runs and serves with the menu bar app not running.

---

## Phase 7 - Auth hardening for a browser-exposed control plane

**Depends on:** Phases 4-5 (the browser is now a first-class control surface with
write access). Lands last.

**Goal:** make the browser-facing control plane safe to expose, beyond the current
single-shared-bearer-token model.

**Background.** Today every client holds an equivalent bearer token (SHA-256
hashed at rest); there is no per-session expiry, no scoping, and the token lives
in `localStorage`. With the web app able to create projects, change settings, and
trigger builds (Phases 5), the blast radius of a leaked token grows. The transport
is HTTPS over Tailscale (already a private network), so this is defense in depth,
not a fix for an open hole.

**Candidate work (scope to be decided when this phase starts - open a ticket to
investigate first)**
- Token lifetimes / rotation / revocation surfaced in the UI (the
  `DevicesRouteHandler` + `revokeDevice` endpoint already exist; build the UX and
  add expiry).
- Distinguish read-only vs control scopes for tokens.
- CSRF/clickjacking review for the browser control surface (current responses set
  `X-Frame-Options: DENY` and a same-origin CSP - verify they cover the new write
  flows).
- Audit logging of control actions (build trigger, settings change, project
  delete).

**Verification (human ship gate)**
- Revoke a browser's token from the Mac and confirm that browser is immediately
  locked out on its next request. Confirm an expired token is rejected.

**Done when:** browser sessions can be scoped, expired, and revoked, with the
behavior demonstrated.

---

## Out of scope

- **Multi-Mac / remote-host scenarios.** The whole plan assumes one Mac in one
  user session. Routing one frontend to many build hosts is a separate effort.

---
investigated_at_sha: 2d4c0fa033b7029421a2db5fcc3fadf18465d57a
