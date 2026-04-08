# Shipped Ticket Audit — 2026-04-08

Static verification of tickets marked `status: shipped` (TKT-003 through TKT-023). Each ticket was checked against the code it claimed to have changed. No tests were run.

Second pass (TKT-008, 009, 011, 012, 014, 019, 020, 023) was performed after the initial audit; previously flagged anomalies were re-checked to see if they had since been fixed.

## Summary

| Ticket | Verdict | Location |
|---|---|---|
| TKT-003 | PASS | `closed/` |
| TKT-004 | PASS | `closed/` |
| TKT-005 | PASS | `closed/` |
| TKT-006 | PASS | `closed/` |
| TKT-007 | PASS | `closed/` |
| TKT-008 | RESOLVED (TKT-024 `c07d516`) | — |
| TKT-009 | RESOLVED (TKT-024 `8a28588`) | — |
| TKT-010 | PASS | `closed/` |
| TKT-011 | RESOLVED (TKT-024 `396fdb8`) | — |
| TKT-012 | RESOLVED (TKT-024 `5a5f0ad`) | — |
| TKT-013 | PASS | `closed/` |
| TKT-014 | RESOLVED (TKT-024 `a1ca280`) | — |
| TKT-015 | PASS | `closed/` |
| TKT-016 | PASS | `closed/` |
| TKT-017 | PASS | `closed/` |
| TKT-018 | PASS | `closed/` |
| TKT-019 | RESOLVED (TKT-024 `ac8d2cf`) | — |
| TKT-020 | PASS | `closed/` |
| TKT-023 | PASS | `closed/` |

Not audited: TKT-022 (`in-progress`).

TKT-021 audit (performed 2026-04-08 as part of TKT-024): **ANOMALY** — code shipped without on-device verification; both AC warnings were still firing at launch. **RESOLVED** under TKT-024 commit `3f9c358` via the fallback path (NWListener Bonjour migration + 150ms startup dispatch delay). Verified on device: both warnings now absent.

## Anomalies

### TKT-008 — Build history persistence
`JSONBuildHistoryStore` is correctly implemented and wired into `BuildManager` (success + failure paths) and the API layer via `EmptyBuildHistoryProvider` / `BuildRouteHandler.getBuildHistory()`. The acceptance criterion "Unit tests cover append, cap, load, query" is **still not met** — `RemoteDeployTests/` contains only a mock, no test file exercising the JSON store. Implementation is functional; test coverage promised by the ticket is missing.

### TKT-009 — Settings update endpoint
Port and cert/key path validation are implemented in `DeferredSettingsUpdater.swift`, and `DeferredSettingsUpdaterTests.swift` covers those branches. **Still missing**: bundle-ID regex validation called out in the AC is present only in the UI (`ProjectSetupStep.swift:38-44`), not in the settings updater itself. A programmatic `PUT /api/v1/settings` call can write a malformed bundle ID without rejection, and there are no bundle-ID tests in `DeferredSettingsUpdaterTests.swift`.

### TKT-011 — WebSocket implementation tests & security
`WebSocketManager` has unit tests (the narrow scope the ticket delivered), but the broader work the ticket describes is **still not wired up**:
- `NIODeployServer.swift:180-184` installs SSL → HTTP → `HTTPHandler`; there is no `WebSocketUpgrader` or `WebSocketChannelHandler` in the pipeline.
- `webSocketManager` is instantiated (`NIODeployServer.swift:53`) but never referenced by the server.
- Bearer-token auth on the WS upgrade path is not implemented.
- iOS reconnect-with-backoff client behavior is not implemented.
- `WebSocketManagerTests.swift:7-12` explicitly notes the integration is deferred.

From the server's perspective `WebSocketManager` is dead code. Either the ticket scope should be re-framed ("tests only; wiring out of scope") or a follow-up ticket should cover upgrade wiring + auth + client reconnect.

### TKT-012 — Decompose MenuBarView
AC calls for **5** subview files and `MenuBarView.swift` under **100 lines**. Current state (unchanged since first audit):
- Only **4** subview files exist under `RemoteDeploy/Views/MenuBar/`: `BuildControlsSection.swift`, `MenuBarHeaderSection.swift`, `ProjectsListSection.swift`, `UtilitiesSection.swift`. `ServerStatusSection.swift` is missing.
- `MenuBarView.swift` is **112 lines** (includes an inline `ProjectRowView` helper).

Functional decomposition happened, but the ticket's own numeric bar is not met.

### TKT-014 — Setup Assistant UX polish
Most validation work is present (bundle ID, team ID, path existence, cert/key readability with inline error display via `validationStatus`). **Still missing**: "scheme not empty" validation from the AC — `ProjectSetupStep.swift:368` saves `project.scheme = selectedScheme` unconditionally with no `schemeError` state and no block on advance when the scheme picker is empty.

### TKT-019 — Startup via AppDelegate
The core implementation is correct and the previously-flagged root cause is fixed: `AppDelegate.applicationDidFinishLaunching` (line 81) calls `performStartup()` (line 102), wired via `@NSApplicationDelegateAdaptor` in `RemoteDeployApp.swift:24`. Server now starts at launch, not on first popover click. **Soft miss**: the implementation-plan item promising a focused unit test `RemoteDeployTests/AppDelegateStartupTests.swift` was not delivered — no such file exists. Keeping this in `tickets/` as a tracking reminder even though the user-facing bug is resolved. (Separately, TKT-021 identifies a layout-recursion bug stemming from how this delegate is wired; that's a distinct follow-up, not a regression of TKT-019.)

## Notes on duplicates

TKT-003, 004, 010, and 015 were originally present in both `tickets/` and `tickets/closed/` with byte-identical contents. The root-level copies were removed in the first audit pass. The user is tracking the `/ticket-ship` copy-vs-move issue separately with another agent.
