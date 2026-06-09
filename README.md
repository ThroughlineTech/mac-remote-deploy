# RemoteDeploy

A macOS menu bar app that builds, signs, and serves your iOS apps over HTTPS. Install on any iPhone from anywhere with a single tap in Safari. Control everything from your phone with the iOS companion app, or from any browser with the built-in web app.

## The Problem

Deploying iOS builds to a test device is more painful than it should be. TestFlight takes 15-30 minutes to process each upload, USB deployment requires physical access to the device, and tools like Xcode's wireless debugging require both devices on the same network. If you're iterating quickly or your test device is somewhere else entirely, none of these options work well.

RemoteDeploy eliminates all of that. It builds your app, serves the signed IPA over HTTPS via Tailscale, and your iPhone installs it from a URL in Safari in about 10 seconds, from anywhere in the world. And you can kick off builds from your phone.

## How It Works

```
+-----------------------+         Tailscale VPN          +--------------------+
|   Mac (developer)     |<------------------------------>|  iPhone (remote)   |
|                       |                                |                    |
|  Menu Bar App:        |    HTTPS (port 8443)           |  Safari:           |
|  - Builds .ipa        |<------------------------------>|  - Opens install   |
|  - Serves via HTTPS   |    REST API + WebSocket        |    page            |
|  - REST API           |                                |  - Taps Install    |
|  - Bonjour discovery  |    HTTP (port 8080)            |                    |
|                       |<------- local WiFi ----------->|  Companion App:    |
|  Web PWA at /app/     |                                |  - Trigger builds  |
|                       |                                |  - Live build log  |
+-----------------------+                                +--------------------+
```

The Mac runs `xcodebuild` to archive and export your app with ad-hoc signing, then serves the IPA over HTTPS (SwiftNIO). Tailscale provides the secure tunnel and valid TLS certificate. On the iPhone side, open a URL in Safari, tap Install, and the app appears on your home screen.

The Mac also exposes a REST API and WebSocket endpoint so you can trigger builds, watch logs, and manage projects from the **iOS companion app** or the **built-in web PWA** (works on any device with a browser).

## Features

- **One-click build and deploy** -- archive, sign, serve, and notify in a single action
- **Works from anywhere** -- Tailscale connects your Mac and iPhone across any network
- **iOS companion app** -- native SwiftUI app to trigger builds, watch live logs, and manage projects from your phone
- **Web PWA** -- pinnable web app at `/app/` that works on any device (Android, iPad, desktop browser)
- **QR code pairing** -- scan a QR code on your Mac to securely pair your phone in seconds
- **Local WiFi support** -- API works over plain HTTP on port 8080 when you're on the same network (no Tailscale needed for build control)
- **Bonjour discovery** -- companion app and web clients auto-discover your Mac on the local network
- **Live build log streaming** -- WebSocket-powered real-time xcodebuild output on phone or browser
- **Multiple project support** -- configure as many iOS projects as you want, each with its own install URL
- **Push notifications** -- get notified via Prowl, Pushover, or ntfy when builds finish
- **macOS app builds** -- build, serve, and auto-deploy macOS apps (not just iOS). Download `.app.zip` from the install page or auto-deploy to the local machine
- **Local auto-deploy** -- macOS builds can automatically quit the running app, replace it, and relaunch. RemoteDeploy can even deploy itself.
- **REST API** -- 20 endpoints for full programmatic control (`/api/v1/`)
- **IPA import** -- skip the build step entirely by importing a pre-built IPA
- **Setup wizard** -- a 5-step guided assistant handles Tailscale, certificates, and project configuration
- **Protocol-oriented architecture** -- every major component is defined as a protocol, making the codebase testable and extensible

## Prerequisites

Before you start, you need:

1. **macOS 14 or later**
2. **Xcode** -- full installation (not just Command Line Tools)
3. **[Tailscale](https://tailscale.com/download)** -- installed on both your Mac and iPhone, signed into the same tailnet
4. **Apple Developer Program membership** -- with an ad-hoc provisioning profile that includes your test device's UDID
5. **[XcodeGen](https://github.com/yonaskolb/XcodeGen)** -- if building from source (`brew install xcodegen`)

---

## Getting Started: Build from Source

### 1. Clone and generate the Xcode project

```bash
git clone https://github.com/danrichardson/mac-remote-deploy.git
cd mac-remote-deploy
xcodegen generate
open RemoteDeploy.xcodeproj
```

This generates an Xcode project with three targets:
- **RemoteDeploy** -- the macOS menu bar app
- **RemoteDeployCompanion** -- the iOS companion app
- **RemoteDeployTests** / **RemoteDeployIntegrationTests** -- test suites

### 2. Configure signing

In Xcode, select each target and set your development team:

- **RemoteDeploy** target: select your team under Signing & Capabilities. This is a macOS app, so any Apple Developer account works.
- **RemoteDeployCompanion** target: select your team and set a unique bundle identifier (e.g., `com.yourname.remotedeploy.companion`). This is an iOS app and needs a valid provisioning profile to run on a device.

### 3. Build and run the Mac app

1. Select the **RemoteDeploy** scheme, target **My Mac**
2. Build and run (Cmd+R)
3. The app appears as a package icon in your menu bar -- there is no dock icon or main window
4. The **Setup Assistant** opens automatically on first launch

### 4. Walk through the Setup Assistant

The setup wizard has 5 steps:

1. **Tailscale** -- verifies Tailscale is installed and connected, shows your hostname
2. **Certificates** -- generates TLS certificates via `tailscale cert` (or lets you browse to existing ones)
3. **Add Project** -- pick your `.xcodeproj` or `.xcworkspace`, auto-detects schemes, you fill in bundle ID and team ID
4. **Push Notifications** (optional) -- configure Prowl, Pushover, or ntfy with test buttons
5. **Done** -- shows your install URL and a Copy button

### 5. Build and deploy your first app

1. Click the menu bar icon
2. Select your project from the dropdown
3. Click **Build & Deploy**
4. Watch the build log (click "View Build Log" for the full output)
5. When the build succeeds, open the install URL in Safari on your iPhone
6. Tap **Install** -- the app appears on your home screen in ~10 seconds

---

## Install on This Mac (Self-Hosting)

RemoteDeploy is meant to run continuously on your build machine. To install it
into `/Applications` and have it start automatically at login -- with **no
runtime dependency on Xcode, DerivedData, or this source tree** -- use the
one-command installer:

```bash
./deploy.sh
```

> First time only: `chmod +x deploy.sh` if git didn't preserve the executable bit.

This will:

1. Build a Release `.app` (in `/tmp` -- it never touches a relocated DerivedData volume)
2. Stop the LaunchAgent so it can't relaunch the old binary mid-swap
3. Gracefully quit the running RemoteDeploy and wait for port 8443 to free
4. Install the fresh `.app` into `/Applications`
5. Install a **LaunchAgent** (`~/Library/LaunchAgents/com.remotedeploy.app.plist`)
   that auto-starts the app at login and restarts it after a crash
6. Remove the legacy Login Item (so it can't double-launch alongside the agent)
7. Start the new version via `launchd`

The installed app in `/Applications` is fully self-contained: it does not read
from this repo or any `~/Library/Developer/Xcode` folder at runtime, so moving or
deleting your DerivedData/dev directories will not affect it.

| Command | What it does |
|---------|--------------|
| `./deploy.sh` | Fast install: signed (`build-release.sh --skip-notarize`), no Apple round-trip |
| `./deploy.sh --release` | Full signed **+ notarized** build (distributable to other Macs) |
| `./deploy.sh --no-build` | Skip the build; just (re)install the last `/tmp` output |

The `--release` path requires notarization credentials configured for
`build-release.sh` (see that script's header). LaunchAgent stdout/stderr is
written to `/tmp/remotedeploy.launchagent.log`.

To uninstall the autostart behavior:

```bash
launchctl bootout gui/$(id -u)/com.remotedeploy.app
rm ~/Library/LaunchAgents/com.remotedeploy.app.plist
```

---

## Using the iOS Companion App

The companion app lets you trigger builds, watch live build logs, and manage your Mac from your phone.

### Build and install on your iPhone

1. In Xcode, select the **RemoteDeployCompanion** scheme
2. Connect your iPhone or select it as the destination
3. Build and run (Cmd+R)

### Pair with your Mac

1. On the Mac, open **Settings** (from the menu bar dropdown) and go to the **Devices** tab
2. Click **Pair New Device** -- a QR code appears
3. On your iPhone, open the companion app and tap **Scan QR Code**
4. Point your camera at the QR code -- pairing completes automatically

The QR code contains your Mac's server URL and a one-time authentication token. The token is stored securely in the iOS Keychain and hashed (SHA-256) on the Mac -- the raw token is never written to disk on the Mac side.

### What you can do from the companion app

- **Projects tab** -- see all configured projects, tap one for details, trigger a build
- **Build tab** -- select a project, tap Build & Deploy, watch the live build log stream via WebSocket
- **Installs tab** -- pull-to-refresh list of every IPA download (who, when, from where)
- **Settings tab** -- see server status, Tailscale connection, push notification config, disconnect

### Local WiFi mode

When your phone and Mac are on the same WiFi network, the companion app can discover your Mac automatically via Bonjour -- no Tailscale needed for build control. The Mac advertises itself as `_remotedeploy._tcp` on the local network.

Note: OTA app installation still requires Tailscale (iOS needs trusted HTTPS certificates for `itms-services://` installs). But triggering builds, watching logs, and managing projects works fine over plain HTTP on port 8080.

---

## Using the Web PWA

The Mac serves a progressive web app at `/app/` that works on any device with a browser.

### Access it

Open your Mac's server URL with `/app/` appended:

```
https://your-mac.tail12345.ts.net:8443/app/
```

Or on local WiFi (no Tailscale):

```
http://your-mac-ip:8080/app/
```

### Pin it to your home screen

- **iOS Safari**: tap Share > Add to Home Screen
- **Android Chrome**: tap the three-dot menu > Add to Home Screen (or Install App)
- **Desktop browsers**: most Chromium browsers show an install prompt in the address bar

### Authenticate

The first time you open the PWA, it asks for your bearer token. You can get this from the QR code pairing flow on your Mac (the token is shown as text below the QR code for manual entry). The token is stored in the browser's localStorage.

### What you can do

Everything the iOS companion app does:
- View and select projects
- Trigger builds
- Watch the live build log (WebSocket)
- View install history
- Check server and Tailscale status
- Disconnect

---

## REST API

The Mac exposes a full REST API at `/api/v1/` for programmatic control. All endpoints except `POST /api/v1/pair` require a bearer token in the `Authorization` header.

### Authentication

```bash
# All requests (except pairing) need this header:
-H "Authorization: Bearer YOUR_TOKEN_HERE"
```

### Example: list projects

```bash
curl -H "Authorization: Bearer $TOKEN" \
  https://your-mac.tail12345.ts.net:8443/api/v1/projects
```

### Example: trigger a build

```bash
curl -X POST \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{}' \
  https://your-mac.tail12345.ts.net:8443/api/v1/projects/PROJECT_UUID/build
```

### Example: check server status

```bash
curl -H "Authorization: Bearer $TOKEN" \
  https://your-mac.tail12345.ts.net:8443/api/v1/status
```

### Full endpoint reference

| Method | Path | Description |
|--------|------|-------------|
| POST | `/api/v1/pair` | Complete QR pairing (no auth required) |
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

## Architecture

RemoteDeploy uses a protocol-oriented architecture. Every major component is defined as a Swift protocol with a concrete implementation.

| Protocol | Implementation | Purpose |
|----------|---------------|---------|
| `BuildEngineProtocol` | `XcodeBuildEngine` | Wraps xcodebuild archive + export |
| `DeployServerProtocol` | `NIODeployServer` | HTTPS + HTTP server via SwiftNIO |
| `TailscaleProviderProtocol` | `CLITailscaleProvider` | Hostname detection, cert management |
| `ManifestGenerating` | `ManifestGenerator` | Generates OTA manifest.plist |
| `InstallPageGenerating` | `InstallPageGenerator` | Generates HTML install page |
| `ProjectStoring` | `UserDefaultsProjectStore` | CRUD for project configurations |
| `PairedDeviceStoring` | `JSONPairedDeviceStore` | CRUD for paired companion devices |
| `CertificateProviding` | `TailscaleCertificateProvider` | Loads and refreshes TLS certs |
| `InstallTracking` | `ServerInstallTracker` | Logs IPA downloads |
| `PushNotifying` | `ProwlNotifier`, `PushoverNotifier`, `NtfyNotifier` | Push notifications on build events |
| `LocalDeployManagerProtocol` | `LocalDeployManager` | Post-build local deploy (quit, copy, relaunch) |

### Project structure

```
mac-remote-deploy/
  Packages/RemoteDeployShared/     # Shared SPM package (models, API types)
  RemoteDeploy/                    # macOS menu bar app
    API/                           # REST API router, auth, route handlers
      Routes/                      # Per-resource handlers
      WebSocket/                   # WebSocket manager + handler
    Models/                        # Re-exports from shared package
    Protocols/                     # Service protocols
    Services/                      # Concrete implementations
    Views/                         # SwiftUI views
    Resources/pwa/                 # Web PWA static files
  RemoteDeployCompanion/           # iOS companion app
    Services/                      # APIClient, Keychain, Bonjour, WebSocket
    Views/                         # SwiftUI views (Discovery, Build, etc.)
  RemoteDeployTests/               # Unit tests
  RemoteDeployIntegrationTests/    # Integration tests (real NIO server)
  docs/                            # Documentation
  project.yml                      # XcodeGen project definition
```

### Shared code

The `RemoteDeployShared` SPM package contains all model types and API DTOs. Both the Mac app and iOS companion depend on it, so data serializes identically on both sides. The package targets macOS 14+ and iOS 17+.

See [docs/remote-deploy-server-spec.md](docs/remote-deploy-server-spec.md) for the full technical spec, [docs/v2-changes.md](docs/v2-changes.md) for detailed v2 change notes, and [CHANGELOG.md](CHANGELOG.md) for the full release history.

---

## Network Ports

| Port | Protocol | Purpose | When |
|------|----------|---------|------|
| 8443 | HTTPS (TLS) | OTA installs, API, PWA | Always (via Tailscale) |
| 8080 | HTTP (plain) | API, PWA (no OTA installs) | Local WiFi only |

OTA app installs require HTTPS with a trusted certificate (iOS requirement). The plain HTTP listener on 8080 is for API access and the web PWA when Tailscale isn't available.

---

## Push Notifications

Three push notification providers are supported. Enable any combination of them in Settings.

- **Prowl** -- iOS push notifications via the Prowl app. Requires an API key from [prowlapp.com](https://www.prowlapp.com/).
- **Pushover** -- cross-platform notifications with clickable install URLs. Requires an app token and user key from [pushover.net](https://pushover.net/).
- **ntfy** -- free, open-source notifications. Use the public server at [ntfy.sh](https://ntfy.sh/) or self-host your own.

Each provider has a "Send Test Notification" button in Settings so you can verify the configuration works before relying on it.

---

## Troubleshooting

### "Build failed" in the companion app or PWA

The build runs on your Mac via `xcodebuild`. Make sure your project builds successfully in Xcode first. Check the live build log for the specific error.

### Companion app can't find the Mac

- **On Tailscale**: make sure both devices are connected to the same tailnet and the Mac's server is running
- **On local WiFi**: make sure both devices are on the same network. The Mac advertises via Bonjour (`_remotedeploy._tcp`). Check that your iPhone's local network permission is enabled for the companion app.

### QR code scanning doesn't work

Make sure you granted camera access to the companion app. The QR code is valid for 10 minutes -- if it expires, generate a new one from Settings > Devices > Pair New Device.

### OTA install fails on local WiFi

This is expected. iOS requires HTTPS with a certificate from a trusted CA for OTA installs (`itms-services://` protocol). Connect to Tailscale for OTA installs. Build triggering and monitoring work fine over plain HTTP.

### "401 Unauthorized" from the API

Your bearer token is invalid or expired. Re-pair your device by scanning a new QR code, or re-enter the token in the web PWA.

---

## Running Tests

```bash
# Generate the project first
xcodegen generate

# Unit tests
xcodebuild test -scheme RemoteDeployTests -destination 'platform=macOS'

# Integration tests (spins up a real NIO server)
xcodebuild test -scheme RemoteDeployIntegrationTests -destination 'platform=macOS'
```

---

## Logging

RemoteDeploy uses Apple's `os.Logger` (unified logging) for all production logs. Both targets are organized by subsystem and category so you can filter to exactly what you care about.

**Subsystems:**
- `com.remotedeploy.host` — the macOS app
- `com.remotedeploy.companion` — the iOS companion app

**macOS host categories:** `server`, `api`, `pairing`, `build`, `tailscale`, `storage`, `notifications`, `bonjour`, `ui`

**iOS companion categories:** `pairing`, `api`, `ui`

**Streaming logs from the terminal:**

```sh
# Everything from the macOS host
log stream --subsystem com.remotedeploy.host

# Just the API request log lines
log stream --subsystem com.remotedeploy.host --predicate 'category == "api"'

# Build engine errors only, with debug detail
log stream --subsystem com.remotedeploy.host --predicate 'category == "build"' --level debug

# iOS companion (when the device is connected)
log stream --subsystem com.remotedeploy.companion --predicate 'category == "pairing"'
```

**Console.app:** open Console, click your Mac in the sidebar, and filter the search field with `subsystem:com.remotedeploy.host` or `subsystem:com.remotedeploy.companion`.

**Privacy:** by default `os.Logger` redacts user-identifying values (paths, hostnames, project names) in release builds — they show up as `<private>` in Console unless you've enabled the private-data debug profile. Status codes, HTTP methods, and durations are always public.

---

## Contributing

Contributions are welcome. Here's how to get started:

- Fork the repo and open a pull request against `main`
- Run tests before submitting (see above)
- All major components use protocols -- you can add new implementations (a new push notification provider, a different build engine, etc.) without changing existing code
- See [docs/remote-deploy-server-spec.md](docs/remote-deploy-server-spec.md) for architecture details

## License

MIT

## About

RemoteDeploy is built by [Throughline Tech, LLC](https://www.throughlinetech.net).

Read the full deep dive on how RemoteDeploy was built: [throughlinetech.net/deep-dives/remotedeploy](https://www.throughlinetech.net/deep-dives/remotedeploy)

## Acknowledgments

- [SwiftNIO](https://github.com/apple/swift-nio) and [NIOSSL](https://github.com/apple/swift-nio-ssl) by Apple for the HTTPS server
- [Tailscale](https://tailscale.com/) for making secure networking simple enough to build on top of
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) for declarative Xcode project generation
