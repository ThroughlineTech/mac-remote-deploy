# Changelog

All notable changes to RemoteDeploy are documented in this file.

Format follows [Keep a Changelog](https://keepachangelog.com/). Versions follow [Semantic Versioning](https://semver.org/).

---

## [2.3.0] — 2026-04-13

macOS app build and deploy support. RemoteDeploy can now build, serve, and auto-deploy macOS apps — including itself.

### Added
- **macOS build support** (TKT-051) — build engine branches by platform: macOS projects skip `exportArchive` and instead zip the `.app` bundle directly from the archive. Served as `app.zip` with a download page instead of iOS OTA install.
- **Local auto-deploy for macOS builds** (TKT-053) — new `LocalDeployManager` service handles post-build deployment on the same machine: gracefully quits the running app, copies the new `.app` to the target directory, and relaunches it. Self-deploy trampoline for when RemoteDeploy deploys itself.
- **Graceful app restart** (TKT-050) — `scripts/graceful-relaunch.sh` for shell-based quit/relaunch. `applicationWillTerminate` handler in AppDelegate cleanly stops the NIO server and Bonjour before exit, ensuring ports are released.
- `app.zip` HTTP route for macOS project downloads
- macOS download page template (no `itms-services://`, direct download button)
- `manifest.plist` returns 404 for macOS projects (not applicable)
- `LocalDeployManagerProtocol` for testability
- "Auto-deploy locally" toggle and deploy path field in project settings UI (macOS projects only)
- `localDeploy` and `localDeployPath` fields on `ProjectConfig` (backward-compatible)
- PWA shows macOS badge on project cards, "Build & Package" label, and download link for macOS builds
- 16 new tests (369 total)

### Changed
- `sendFileResponse` in HTTPHandler now accepts dynamic content type and filename (defaults preserve iOS backward compat)
- `serveInstallPage` branches by platform (download page for macOS, OTA install for iOS)
- Build notifications say "deployed to /Applications/" for local-deploy macOS projects instead of "ready to install"
- Preview profile uses `graceful-relaunch.sh` instead of `pkill` + `sleep`

---

## [2.2.0] — 2026-04-13

Expo (React Native) project support, companion build log UX improvements, and better error messages.

### Added
- **Expo project support** (TKT-048, TKT-049) — new `ExpoBuildEngine` runs npm install → expo prebuild → pod install → xcodebuild archive. `BuildEngineRouter` dispatches by project type. Settings UI supports adding Expo projects with auto-detection.
- Scheme picker filters out CocoaPods sub-schemes for Expo projects

### Fixed
- **Companion build log UX** (TKT-046, TKT-047) — log collapsed by default, auto-scroll stops at terminal state, new build re-collapses and re-enables scroll. Fixed DisclosureGroup freezing the tab bar.
- **Preflight failure handling** (TKT-045) — `XcodeBuildEngine` captures last 8 stderr lines into ring buffer. Errors now surface actual xcodebuild output instead of generic exit codes.

---

## [2.1.0] — 2026-04-08

Live build log streaming, WebSocket authentication, and internal hardening.

### Added
- **Live build log streaming** on iOS companion via authenticated WebSocket (`/api/v1/ws`)
- WebSocket exponential backoff reconnect (1s → 2s → 4s → 8s → 16s cap)
- WebSocket upgrade path enforces bearer-token auth (unauthenticated → 401)
- Bundle ID validation on `POST/PUT /projects` (shared `BundleIDValidator`)
- `scripts/ship-deploy.sh` dispatch wrapper — skips notarized release build for companion-only and docs-only ships
- 29 new tests (315 total) covering build history store, AppDelegate startup, project validators, WebSocket flows

### Fixed
- Layout recursion warning at startup (`_NSDetectedLayoutRecursion`) — migrated `BonjourAdvertiser` from `NetService` to `NWListener`, deferred startup mutations past first layout pass
- SwiftUI Picker "selection is invalid" warnings in project and scheme pickers
- Companion signing prompt on every `xcodegen generate` — fixed `DEVELOPMENT_TEAM` in `project.yml`

### Changed
- `HTTPHandler` is now per-channel instead of a single shared instance (latent concurrency fix)
- Plain-HTTP listener port is configurable; integration tests use ephemeral ports
- `MenuBarView` decomposed into 5 focused subviews (84 lines, down from ~400)
- Companion Swift 6 concurrency cleanup

---

## [2.0.1] — 2026-04-04

Security hardening, app icon, and About page.

### Security
- TLS validation restored on iOS companion (was accepting all certs)
- Pairing blocked over HTTP — `POST /pair` rejected on plain-HTTP listener
- API secrets redacted in `GET /settings` responses
- Content-Security-Policy headers on all HTML responses
- XSS fixes — HTML escaping on server index page, single-quote escaping in PWA, XML escaping in ExportOptions.plist
- CORS wildcard removed
- Keychain biometric (FaceID/passcode) on iOS companion
- Path traversal hardened in PWA file serving and scheme detection
- Error messages sanitized — no internal file paths in API responses
- Token input masked in iOS and PWA
- Debug logging guarded behind `#if DEBUG`

### Added
- App icon for Mac and iOS (`.xcassets` catalog, `CFBundleIconName`)
- About page in Mac app Settings with version info and links

---

## [2.0.0] — 2026-04-04

Major release: iOS companion app, web PWA, REST API, and local WiFi support.

### Added
- **iOS Companion App** — native SwiftUI app for triggering builds, watching status, and managing projects from your phone. QR code pairing.
- **Web PWA** at `/app/` — pinnable web app with full build control. Works on any device with a browser.
- **REST API** — 20 endpoints at `/api/v1/` with bearer token authentication for full programmatic control
- **Local WiFi support** — API works over plain HTTP on port 8080 when Tailscale isn't connected. Bonjour auto-discovery.
- **QR code pairing** — scan to pair companion devices. Tokens SHA-256 hashed on disk.
- **Device management** — pair, view, and revoke companion devices
- **Platform-aware builds** — configure projects as iOS or macOS with auto-detection from Xcode schemes
- Auto-detect bundle ID, team ID, and platform from schemes
- Project delete from edit form
- `RemoteDeployShared` SPM package for shared models and API types
- WebSocket endpoint for real-time build status and log streaming
- Bonjour advertisement (`_remotedeploy._tcp`)

---

## [1.0.0] — 2026-03-31

Initial release.

### Added
- macOS 14+ menu bar app for one-click iOS app deployment
- 5-step setup wizard (Tailscale, certificates, project, push notifications, done)
- `xcodebuild archive` + `exportArchive` + HTTPS serve pipeline
- HTTPS server via SwiftNIO with OTA install pages and manifest.plist generation
- Push notifications via Prowl, Pushover, and ntfy
- Real-time build log viewer
- Pre-built IPA import
- Launch at login
- Protocol-oriented architecture — every major component is swappable
- Signed and notarized by Apple (Developer ID distribution)

[2.3.0]: https://github.com/danrichardson/mac-remote-deploy/releases/tag/v2.3.0
[2.2.0]: https://github.com/danrichardson/mac-remote-deploy/releases/tag/v2.2.0
[2.1.0]: https://github.com/danrichardson/mac-remote-deploy/releases/tag/v2.1.0
[2.0.1]: https://github.com/danrichardson/mac-remote-deploy/releases/tag/v2.0.1
[2.0.0]: https://github.com/danrichardson/mac-remote-deploy/releases/tag/v2.0.0
[1.0.0]: https://github.com/danrichardson/mac-remote-deploy/releases/tag/v1.0.0
