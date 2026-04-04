# RemoteDeploy v2 Changes

This document covers everything added in the v2 expansion: the REST API layer, iOS companion app, Web PWA, and supporting infrastructure.

---

## Shared Package: `Packages/RemoteDeployShared/`

A local SPM package that both the Mac app and iOS companion depend on. Contains:

- **Models** -- `ProjectConfig`, `BuildResult`, `InstallRecord`, `PushNotificationConfig`, `SettingsData` (moved from the Mac app, made `public`), plus new `PairedDevice`
- **API types** -- `PairRequest`, `PairResponse`, `ServerStatus`, `BuildStatusInfo`, `BuildRequest`, `FilesystemBrowseResponse`, `SchemesResponse`, `WSMessage`, `APIError`
- **APIEndpoint enum** -- defines all 20 REST endpoints with their paths, HTTP methods, and auth requirements

The original Mac model files now just re-export from this package (`@_exported import`), so nothing in the existing codebase broke.

---

## Mac App Changes

### REST API Layer (`RemoteDeploy/API/`)

**APIRouter.swift** -- Central router that intercepts `/api/v1/` requests. Parses path segments, dispatches to the right handler, and handles auth.

**AuthMiddleware.swift** -- Extracts `Authorization: Bearer <token>` headers, hashes the token with SHA-256, looks it up in the paired device store. Updates last-seen timestamps.

**7 route handlers** in `RemoteDeploy/API/Routes/`:

| Handler | Endpoints | What it does |
|---------|-----------|-------------|
| `PairingRouteHandler` | `POST/DELETE /pair` | QR code pairing with pending token validation |
| `StatusRouteHandler` | `GET /status` | Server + Tailscale + build status snapshot |
| `ProjectsRouteHandler` | `CRUD /projects` | List, create, read, update, delete projects |
| `BuildRouteHandler` | `/projects/:id/build`, `/builds` | Trigger, status, cancel, history |
| `InstallsRouteHandler` | `GET /installs` | IPA download history |
| `SettingsRouteHandler` | `GET/PUT /settings` | Read/write server settings |
| `FilesystemRouteHandler` | `GET /filesystem/browse`, `/schemes` | Browse Mac directories, detect Xcode schemes (restricted to `/Users/`) |
| `DevicesRouteHandler` | `GET /devices`, `DELETE /devices/:id` | List and revoke paired devices |

### WebSocket (`RemoteDeploy/API/WebSocket/`)

**WebSocketHandler.swift** -- `WebSocketManager` tracks active connections and broadcasts to subscribers. `WebSocketChannelHandler` handles individual connections -- subscribe commands, ping/pong, close. Clients subscribe to channels: `buildlog`, `buildstatus`, `install`.

### New Services

**JSONPairedDeviceStore.swift** -- Persists paired devices as JSON in Application Support. Tokens stored as SHA-256 hashes (raw tokens never on disk). File permissions `0o600`. Also has `generateToken()` (256-bit via `SecRandomCopyBytes`) and `hashToken()`.

**QRCodeGenerator.swift** -- CoreImage `CIQRCodeGenerator`. Produces QR codes containing `{ url, token, serverName }` JSON. Used by the pairing UI.

**BonjourAdvertiser.swift** -- Advertises `_remotedeploy._tcp` via Network framework's `NWListener`. TXT record includes `hostname`, `httpsPort`, `httpPort`. Starts when the server starts.

### Protocol

**PairedDeviceStoring.swift** -- Protocol for device CRUD + token lookup, following the existing `ProjectStoring` pattern.

### Modified Files

**NIODeployServer.swift** -- Three additions, existing OTA logic untouched:
1. **Body buffering** -- `HTTPHandler` now accumulates request bodies (up to 1MB) for POST/PUT
2. **API routing** -- `/api/` requests delegate to the `APIRouter`; CORS headers + OPTIONS preflight
3. **Dual listener** -- secondary plain-HTTP `ServerBootstrap` on port 8080 (same `EventLoopGroup`, no TLS) for local WiFi
4. **PWA serving** -- `/app/` routes serve static files from the bundle's `Resources/pwa/` directory

**RemoteDeployApp.swift** -- `ServiceContainer` gained `pairedDeviceStore`, `qrCodeGenerator`, `bonjourAdvertiser`. `startServer()` now calls `configureAPIRouter()` and starts Bonjour advertisement.

**SettingsView.swift** -- Added a "Devices" tab.

### New Views

**PairDeviceView.swift** -- Sheet that generates a fresh token, registers it as pending, and displays a QR code. Includes manual token copy fallback.

**PairedDevicesView.swift** -- Lists paired devices with name, paired date, last seen. "Pair New Device" button opens the QR sheet. "Revoke" button removes a device.

---

## iOS Companion App: `RemoteDeployCompanion/`

A full native SwiftUI iOS app (deployment target iOS 17.0). New XcodeGen target with camera and Bonjour entitlements.

### Services

**APIClient.swift** -- Async/await wrapper around `URLSession`. Methods for every API endpoint (`listProjects()`, `triggerBuild()`, `getInstalls()`, etc.). JSON encoding/decoding with ISO 8601 dates.

**KeychainStore.swift** -- Saves/loads/clears server URL + token + name in the iOS Keychain via Security framework.

**BonjourBrowser.swift** -- `NWBrowser` wrapper that discovers `_remotedeploy._tcp` services on the local network. Publishes discovered servers with name, hostname, ports.

**WebSocketClient.swift** -- `URLSessionWebSocketTask` wrapper. Connects to `/api/v1/ws`, subscribes to `buildlog` + `buildstatus` channels. Publishes received log lines and status updates.

**ConnectionManager.swift** -- Central `@MainActor ObservableObject`. Manages pairing, connection state, credential restoration from Keychain. Provides `apiClient` and `webSocketClient` to views.

### Views

**RemoteDeployCompanionApp.swift** -- App entry point. Shows `ServerDiscoveryView` when disconnected, `MainTabView` when connected (Projects, Build, Installs, Settings tabs).

**ServerDiscoveryView.swift** -- Landing screen with "Scan QR Code" button, Bonjour-discovered servers list, and manual entry sheet. The `ManualEntryView` has URL + token text fields.

**QRScannerView.swift** -- Camera preview using `AVCaptureSession` + `AVCaptureMetadataOutput`. Detects QR codes, parses the pairing JSON, calls `connectionManager.pair()`.

**ProjectListView.swift** -- Lists all projects from the API. Tapping navigates to `ProjectDetailView` showing all config fields + a "Build & Deploy" button.

**BuildControlView.swift** -- Project picker dropdown, build trigger button, cancel button, status indicator. `BuildLogStreamView` shows live WebSocket log lines with color coding (red for errors, yellow for warnings), auto-scrolling to bottom.

**InstallHistoryView.swift** -- Pull-to-refresh list of IPA download records (project name, source IP, timestamp, user agent).

**RemoteSettingsView.swift** -- Shows connection status (server running, Tailscale connected, hostname, port), push notification provider status, and a "Disconnect" button with confirmation dialog.

---

## Web PWA: `RemoteDeploy/Resources/pwa/`

Four static files served by the Mac at `/app/`:

**index.html** -- Shell with PWA meta tags, `apple-mobile-web-app-capable`, theme color, manifest link.

**app.js** -- ~200 lines of vanilla JS. Token-based auth (stored in localStorage). Tabs: Projects, Build (with live WebSocket log), Installs, Settings. Full API client using `fetch()`. WebSocket connection with auto-reconnect.

**style.css** -- Dark mode by default with `prefers-color-scheme: light` support. iOS-native look: rounded cards, status dots, monospace build log.

**manifest.json** -- Enables "Add to Home Screen" on iOS Safari and Android Chrome. Standalone display mode.

**sw.js** -- Service worker that caches the shell files. Network-first for API calls, cache-first for static assets.

---

## Config Changes

**project.yml** -- Added `RemoteDeployShared` local package, `NIOWebSocket` dependency, `RemoteDeployCompanion` iOS target with camera/Bonjour entitlements, PWA resources build phase.

---

## API Reference

All endpoints under `/api/v1/`. All require `Authorization: Bearer <token>` except `POST /api/v1/pair`.

| Method | Path | Description |
|--------|------|-------------|
| POST | `/api/v1/pair` | Complete QR pairing (unauthenticated) |
| DELETE | `/api/v1/pair` | Unpair the calling device |
| GET | `/api/v1/status` | Server + Tailscale + build status |
| GET | `/api/v1/projects` | List all projects |
| POST | `/api/v1/projects` | Create a project |
| GET | `/api/v1/projects/:id` | Get project detail |
| PUT | `/api/v1/projects/:id` | Update a project |
| DELETE | `/api/v1/projects/:id` | Delete a project |
| POST | `/api/v1/projects/:id/build` | Trigger a build |
| GET | `/api/v1/projects/:id/build` | Get build status |
| DELETE | `/api/v1/projects/:id/build` | Cancel a build |
| GET | `/api/v1/builds` | Build history |
| GET | `/api/v1/installs` | Install history |
| GET | `/api/v1/settings` | Get server settings |
| PUT | `/api/v1/settings` | Update server settings |
| GET | `/api/v1/filesystem/browse?path=...` | Browse Mac directories |
| GET | `/api/v1/filesystem/schemes?path=...` | Detect Xcode schemes |
| GET | `/api/v1/devices` | List paired devices |
| DELETE | `/api/v1/devices/:id` | Revoke a paired device |
| GET | `/api/v1/ws` | WebSocket (build logs, status) |

---

## What Was NOT Touched

- All existing OTA install logic (Tailscale, manifest generation, install pages, IPA serving)
- All existing push notification providers (Prowl, Pushover, ntfy)
- All existing tests (12 unit + integration tests still pass)
- The setup assistant, build engine, certificate provider
