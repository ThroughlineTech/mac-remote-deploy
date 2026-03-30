# Remote iOS Deploy Server - Mac Menu Bar App

**Date:** 2026-03-30
**Status:** Spec for implementation
**Type:** macOS menu bar app (SwiftUI + AppKit)
**Goal:** One-click remote deployment of iOS apps to devices over Tailscale

---

## Agent Instructions

This document is the single source of truth for building RemoteDeploy. If you are an agent reading this:

1. **Read this entire document** before doing anything.
2. **Tell the user** what you think you should build, in your own words.
3. **Ask for changes or updates** — do not assume anything not written here.
4. **Update this document** as decisions are made during the conversation. This is a living spec. If you and the user agree on something, add it here so future agents inherit the decision.
5. **Commit frequently** with descriptive messages. No AI/Claude references in commit messages.
6. **Comment all functions** with what goes in, what comes out, and what the function is supposed to do. Write for humans reading the code for the first time.
7. **Run all tests** before presenting work for review.
8. **Components are not enough.** Every component must be wired into the app lifecycle. If you build a service, you must also write the code that calls it at the right time (launch, user action, timer, etc.). A service that exists but is never invoked is a bug. The "App Lifecycle" section below defines exactly what happens and when — follow it.
9. **Manually verify the app runs** after building. Launch it, confirm the UI reflects real state (Tailscale status, loaded projects, etc.), and fix anything that doesn't work before presenting.
10. **Every button must have a real action.** Empty closures `{}`, placeholder comments, and "coordinator will handle this" are bugs. If a button exists in the UI, the code behind it must do real work — call a service, open a panel, save data. Walk through every button in every view and verify it does something. A button that does nothing is worse than no button at all.
11. **Views must use ServiceContainer.** Every view that performs an action (build, save, detect, test) must have `@EnvironmentObject var serviceContainer: ServiceContainer`. Views must never create their own service instances or use placeholder logic. If a view collects data (setup wizard, settings), that data must be persisted — written to AppState AND saved to disk. `@State` variables that are never synced back are data loss bugs.
12. **Settings must persist.** All user-configurable values (cert paths, hostname, port, push config, projects) must survive app restart. Use `SettingsData` JSON for app settings and `ProjectStore` for projects. Load on launch, save on every change.

---

## Architecture Decisions (Agreed)

These decisions have been discussed and approved. Do not revisit unless the user asks.

### Distribution: Developer ID + Notarization (NOT Mac App Store)
The app requires capabilities incompatible with App Sandbox:
- Running `xcodebuild` (arbitrary process execution)
- Opening server ports (HTTPS on configurable port)
- Accessing arbitrary file paths (Xcode projects, Tailscale certs)
- Running `tailscale` CLI commands

Distribute as a signed, notarized `.dmg` or `.app` via direct download. This is standard for developer tools.

### Protocol-Oriented Architecture
Every major component must be defined as a Swift `protocol` with a concrete implementation. This enables:
- Unit testing with mock implementations
- Swapping implementations without touching consumers
- Clean separation of concerns for an open-source project

Required protocols and their concrete implementations:

| Protocol | Implementation | Purpose |
|----------|---------------|---------|
| `BuildEngineProtocol` | `XcodeBuildEngine` | Wraps xcodebuild archive + export |
| `DeployServerProtocol` | `NIODeployServer` | HTTPS server via SwiftNIO |
| `TailscaleProviderProtocol` | `CLITailscaleProvider` | Hostname detection, cert management |
| `ManifestGenerating` | `ManifestGenerator` | Generates OTA manifest.plist |
| `InstallPageGenerating` | `InstallPageGenerator` | Generates HTML install page |
| `ProjectStoring` | `UserDefaultsProjectStore` | CRUD for project configurations |
| `CertificateProviding` | `TailscaleCertificateProvider` | Loads and refreshes TLS certs |
| `InstallTracking` | `ServerInstallTracker` | Logs IPA downloads with timestamp + source IP |
| `PushNotifying` | `ProwlNotifier`, `PushoverNotifier`, `NtfyNotifier` | Push notifications to iOS device on build events |

### Testing Strategy
- **Unit tests:** Mock all protocols. Test build pipeline logic, manifest generation, HTML templating, project config serialization. No Xcode or Tailscale needed.
- **Integration tests:** Spin up a real NIO HTTPS server with a self-signed cert, hit it with `URLSession`, verify correct responses for `/`, `/manifest.plist`, `/app.ipa`.
- **End-to-end:** Manual. Build a real project, serve it, install on device.
- Unit + integration tests must pass in CI with no hardware dependencies.
- **Run all tests before presenting work for review.**

### Code Style
- Comment all public functions: what it does, parameters, return value.
- Descriptive commit messages, frequent commits. No AI/Claude/copilot references.
- This is intended to be open-sourced. Write code as if strangers will read it.

### Testing the App
- **First launch** requires physical access to the Mac to configure certs, Tailscale, and add projects.
- **After setup**, everything works remotely over Tailscale — that's the whole point.
- The iPhone side is just Safari. Open the URL, tap install.
- You can SSH into the Mac to launch/manage the app remotely after initial setup.

---

## App Lifecycle — What Happens and When

This section is critical. It defines how components are wired together at runtime. Every service must be called at the right time — a service that exists but is never invoked is a bug.

### On Launch (app entry point, runs once)

These steps execute in order when the app starts:

1. **Request notification permissions** — Call `NotificationManager.shared.requestPermission()` so macOS notifications work from the first build.
2. **Load saved projects** — Call `projectStore.loadProjects()` and populate `appState.projects`. Select the first project as `selectedProjectID`.
3. **Check Tailscale status** — Call `tailscaleProvider.isConnected()`. If connected, call `tailscaleProvider.detectHostname()` and set `appState.serverURL` to `https://<hostname>:<port>`. Update `appState.tailscaleConnected`.
4. **Show setup assistant** — If `appState.projects` is empty after loading, set `appState.showSetupAssistant = true`.
5. **Start status polling** — Start a 30-second timer that re-checks Tailscale connection status and updates the UI.

### On "Build & Deploy" (user clicks button)

1. **Update build status** — Set `appState.buildStatus = .building("Starting...")`.
2. **Send build-started notifications** — Post macOS notification and push notifications (if configured).
3. **Run build** — Call `buildEngine.build(project:)` for the selected project. Stream `buildLogStream` into `appState.buildLog` in real time.
4. **On success:**
   - Set `appState.buildStatus = .success(ipaPath:)`.
   - Generate manifest and install page for the project.
   - Register the project with the deploy server if not already registered.
   - Start the HTTPS server if not already running (call `deployServer.start(port:certPath:keyPath:)`).
   - Create a `BuildResult` and set `appState.lastBuildResult`.
   - Post success notifications (macOS + push with install URL).
5. **On failure:**
   - Set `appState.buildStatus = .failure(error:)`.
   - Create a `BuildResult` with the error.
   - Post failure notifications (macOS + push with error summary).

### On IPA Download (server callback)

1. **Record install** — The deploy server's `onIPADownload` callback fires with `(slug, sourceIP, userAgent)`. Call `installTracker.recordInstall(...)`.
2. **Update UI** — Fetch the latest install record and set `appState.lastInstall`.

### On "Import IPA" (user selects file)

1. **Import** — Call `IPAImporter.importIPA(from:to:serveDirectory:)`.
2. **Generate manifest** — Create manifest for the imported IPA.
3. **Register with server** — Add the project slug to the deploy server.
4. **Start server** if not running.

### On Settings Change

- **Projects added/edited/deleted:** Save via `projectStore.save(project:)` or `delete(projectID:)`. Update `appState.projects`.
- **Push notification config changed:** Call `serviceContainer.configurePushNotifiers(from:)`.
- **Server port changed:** Stop and restart the deploy server on the new port.
- **Cert paths changed:** Reload certs, restart server.

### Data Flow Summary

```
projectStore.loadProjects() ──→ appState.projects ──→ MenuBarView (project list)
tailscaleProvider.isConnected() ──→ appState.tailscaleConnected ──→ MenuBarView (status dot)
tailscaleProvider.detectHostname() ──→ appState.serverURL ──→ MenuBarView (URL display)
buildEngine.build() ──→ appState.buildStatus ──→ MenuBarView (build button state)
buildEngine.buildLogStream ──→ appState.buildLog ──→ BuildLogView (real-time output)
installTracker.recentInstalls() ──→ appState.lastInstall ──→ MenuBarView (last install info)
deployServer.onIPADownload ──→ installTracker.recordInstall() ──→ appState.lastInstall
```

---

## What This App Does

A macOS menu bar app that runs a local HTTPS server. When you build an iOS app, it signs an ad-hoc .ipa and serves it over Tailscale. On the iPhone, you open a Safari bookmark and tap "Install" - the app downloads and installs in ~10 seconds. No USB, no same-network requirement, no TestFlight.

It can deploy **any iOS app** — not just a single hardcoded project. Users configure projects with their path, scheme, bundle ID, team ID, and provisioning profile. The only Apple-imposed constraint is that the target device's UDID must be registered in the provisioning profile.

---

## Architecture Overview

```
┌─────────────────────┐         Tailscale VPN          ┌──────────────────┐
│   Mac (developer)   │◄──────────────────────────────►│  iPhone (remote) │
│                     │                                 │                  │
│  Menu Bar App:      │    HTTPS (port 8443)           │  Safari:         │
│  - Builds .ipa      │◄──────────────────────────────►│  - Opens install │
│  - Serves via HTTPS │    itms-services:// manifest    │    page          │
│  - Shows status     │                                 │  - Taps Install  │
│                     │                                 │  - iOS downloads │
└─────────────────────┘                                 └──────────────────┘
```

---

## Prerequisites (document in app's first-launch setup assistant)

1. **Tailscale** installed on both Mac and iPhone, both on same tailnet
2. **Tailscale HTTPS cert** for the Mac's MagicDNS name:
   ```bash
   tailscale cert <mac-hostname>.tailf3787.ts.net
   ```
   This produces a cert + key file. The app needs to know where these are.
3. **Apple Developer account** with:
   - Ad-hoc distribution provisioning profile
   - The target iPhone's UDID registered in the dev portal
   - Distribution certificate (or development cert for ad-hoc)
4. **Xcode** installed (for `xcodebuild` and code signing)

---

## macOS App Structure

### Project Type
- macOS App, SwiftUI lifecycle
- Menu bar app (no dock icon, no main window)
- Uses `MenuBarExtra` (macOS 13+)
- Xcode project, Swift, minimum deployment macOS 14
- **Distribution:** Developer ID + Notarization (NOT Mac App Store)

### Menu Bar UI

```
┌─ 📦 (menu bar icon) ──────────────────────┐
│                                             │
│  Remote Deploy Server                       │
│  ─────────────────────                      │
│  Status: ● Running on port 8443            │
│  Tailscale: ● Connected                    │
│  URL: https://dans-mbp.tailf3787...        │
│  📋 Copy URL                               │
│                                             │
│  ─────────────────────                      │
│  Projects:                                  │
│    rejog-ios  /Users/plympton/src/...       │
│    other-app  /Users/plympton/src/...       │
│    + Add Project...                         │
│                                             │
│  ─────────────────────                      │
│  🔨 Build & Deploy  [rejog-ios ▾]          │
│  Configuration: [Release ▾]                │
│  ─────────────────────                      │
│  Last build: 2 min ago (success)           │
│  Last install: 192.168.1.5, 1 min ago      │
│  📄 View Build Log                         │
│                                             │
│  ─────────────────────                      │
│  📥 Import IPA...                           │
│  📖 Setup Guide                             │
│  ⚙ Settings...                              │
│  Quit                                       │
└─────────────────────────────────────────────┘
```

### Settings Window

- **Server port** (default: 8443)
- **Tailscale hostname** (auto-detect from `tailscale status --json`, or manual entry)
- **TLS cert path** + **key path** (from `tailscale cert`)
- **Projects list** (each has):
  - Project path (folder containing .xcodeproj or .xcworkspace) — supports drag-and-drop
  - Scheme name (auto-detected from project, shown as dropdown)
  - Bundle ID
  - Development Team ID
  - Provisioning profile (auto via `signingStyle=automatic`, manual entry as fallback)
  - Build configuration (Debug / Release, default: Release)
  - URL path (e.g., `/rejog/` — for multi-project serving)
- **Launch at login** toggle
- **Push Notifications** (each provider independently toggleable):
  - Prowl: API key
  - Pushover: App token + User key
  - ntfy: Server URL + Topic
  - Event toggles: build started, build success, build failure

### First-Launch Setup Assistant

A 5-step guided sheet shown on first launch (or when no projects are configured). Can be re-launched anytime via "Setup Guide" in the menu bar dropdown.

1. **Welcome / Tailscale**
   - Detect if Tailscale is running, show connection status, display hostname
   - If not running: explain what Tailscale is, link to install page, explain that both Mac and iPhone need it on the same tailnet
   - Show a "Check Again" button to re-detect after user installs

2. **Certificate**
   - Explain why HTTPS is required (iOS refuses OTA install over HTTP)
   - Offer to run `tailscale cert` to generate cert automatically, or let user browse to existing cert/key files
   - Validate that cert matches hostname
   - Show success state with cert expiry date

3. **Add First Project**
   - File picker (or drag-and-drop) to select .xcodeproj/.xcworkspace
   - Auto-detect schemes, let user pick one
   - Auto-fill bundle ID and team ID if detectable
   - Brief explanation of ad-hoc signing and UDID registration (with link to Apple developer portal)

4. **Push Notifications (Optional)**
   - Explain that push notifications alert your phone when builds finish
   - Per-provider setup panes:
     - **Prowl:** "Get your API key from prowlapp.com/api_settings. Paste it below."
     - **Pushover:** "Create an application at pushover.net/apps/build. Copy the App Token and your User Key."
     - **ntfy:** "Enter your ntfy server URL (or use ntfy.sh for free). Pick a topic name."
   - Each provider has a **"Send Test Notification"** button that fires a test push immediately so the user can verify it works
   - "Skip" button — push notifications are optional, don't block setup

5. **Done**
   - Summary of what was configured
   - Show the install URL prominently
   - "Copy URL" button
   - Explain: "Open this URL in Safari on your iPhone to install apps. Save it as a home screen bookmark for one-tap access."
   - Server starts automatically, menu bar icon goes green

### Re-accessible Setup & Help

- **"Setup Guide" menu item** in the menu bar dropdown — re-launches the full setup assistant at any time
- **"?" help buttons** next to each push notification provider in Settings — opens a popover with the same setup instructions from the assistant (where to get keys, how to configure)
- **Settings → Push Notifications → "Send Test"** button per provider — always available, not just during setup

---

## Core Components

### 1. Build Engine (`BuildEngineProtocol` → `XcodeBuildEngine`)

Wraps `xcodebuild` commands. Runs in a background task. Streams build output to the build log viewer in real time.

**Step 1: Archive**
```bash
xcodebuild archive \
  -project <path>/rejog-ios.xcodeproj \
  -scheme rejog-ios \
  -archivePath /tmp/RemoteDeploy/rejog-ios.xcarchive \
  -destination 'generic/platform=iOS' \
  -configuration <Release|Debug> \
  DEVELOPMENT_TEAM=<teamID> \
  -quiet
```

Also supports `-workspace` for `.xcworkspace` projects.

**Step 2: Export IPA**

Create an export options plist:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "...">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>ad-hoc</string>
    <key>teamID</key>
    <string>RDJQ523WP4</string>
    <key>stripSwiftSymbols</key>
    <true/>
    <key>compileBitcode</key>
    <false/>
</dict>
</plist>
```

Then:
```bash
xcodebuild -exportArchive \
  -archivePath /tmp/RemoteDeploy/rejog-ios.xcarchive \
  -exportOptionsPlist /tmp/RemoteDeploy/ExportOptions.plist \
  -exportPath /tmp/RemoteDeploy/export \
  -quiet
```

This produces a `.ipa` file in the export path.

**Step 3: Copy to server directory**
```bash
cp /tmp/RemoteDeploy/export/rejog-ios.ipa ~/Library/Application\ Support/RemoteDeploy/serve/<project-slug>/app.ipa
```

Each project gets its own subdirectory under `serve/`.

**Step 4: Generate manifest plist** (see below)

**Scheme Auto-Detection:**
```bash
xcodebuild -list -project <path>/<name>.xcodeproj
```
Parses the output to populate a scheme dropdown in the UI. Runs when a project is added or the path changes.

### 2. HTTPS Server (`DeployServerProtocol` → `NIODeployServer`)

A lightweight Swift HTTPS server using SwiftNIO + NIOSSL.

The server serves routes per project:
1. `GET /<project-slug>/` - Install page (HTML)
2. `GET /<project-slug>/manifest.plist` - iOS OTA manifest
3. `GET /<project-slug>/app.ipa` - The actual app binary
4. `GET /` - Project index page (lists all configured projects with install links)

**TLS:** Load the Tailscale cert + key. SwiftNIO's `NIOSSL` handles this:
```swift
let tlsConfig = TLSConfiguration.makeServerConfiguration(
    certificateChain: [.file(certPath)],
    privateKey: .file(keyPath)
)
```

**Install tracking:** On every `/app.ipa` download, log the timestamp, requesting IP address, and project name. Surface this in the menu bar UI as "Last install" info.

### 3. Install Page (`InstallPageGenerating` → `InstallPageGenerator`)

Served at `https://<hostname>:8443/<project-slug>/`

```html
<!DOCTYPE html>
<html>
<head>
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Install App</title>
    <style>
        body { font-family: -apple-system; text-align: center; padding: 40px 20px; }
        .install-btn {
            display: inline-block;
            background: #007AFF;
            color: white;
            padding: 16px 32px;
            border-radius: 12px;
            text-decoration: none;
            font-size: 18px;
            font-weight: 600;
        }
        .info { color: #666; margin-top: 20px; font-size: 14px; }
    </style>
</head>
<body>
    <h1>📦 {{APP_NAME}}</h1>
    <p>Version {{VERSION}} ({{BUILD}})</p>
    <p>Built {{BUILD_TIME}}</p>
    <br>
    <a class="install-btn" href="itms-services://?action=download-manifest&url={{MANIFEST_URL}}">
        Install on This Device
    </a>
    <p class="info">Tap Install, then check your home screen.</p>
</body>
</html>
```

The `itms-services://` URL scheme is what tells iOS to download and install an app from a manifest.

### 4. OTA Manifest (`ManifestGenerating` → `ManifestGenerator`)

This is what iOS reads to know what to download:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>items</key>
    <array>
        <dict>
            <key>assets</key>
            <array>
                <dict>
                    <key>kind</key>
                    <string>software-package</string>
                    <key>url</key>
                    <string>{{IPA_URL}}</string>
                </dict>
            </array>
            <key>metadata</key>
            <dict>
                <key>bundle-identifier</key>
                <string>{{BUNDLE_ID}}</string>
                <key>bundle-version</key>
                <string>{{VERSION}}</string>
                <key>kind</key>
                <string>software</string>
                <key>title</key>
                <string>{{APP_NAME}}</string>
            </dict>
        </dict>
    </array>
</dict>
</plist>
```

The `{{IPA_URL}}` must be HTTPS - iOS refuses to install over HTTP. This is why we need the Tailscale cert.

### 5. Tailscale Integration (`TailscaleProviderProtocol` → `CLITailscaleProvider`)

- Auto-detect hostname via `tailscale status --json`
- Manage TLS certificates via `tailscale cert`
- Monitor Tailscale connection status and surface it in the menu bar UI
- Show clear warning in menu bar when Tailscale is disconnected

### 6. Certificate Management (`CertificateProviding` → `TailscaleCertificateProvider`)

- Load TLS cert + key from configured paths
- Handle cert refresh (re-run `tailscale cert` periodically)
- Store certs in `~/Library/Application Support/RemoteDeploy/certs/`

### 7. Project Storage (`ProjectStoring` → `UserDefaultsProjectStore`)

- CRUD operations for project configurations
- Persist via UserDefaults or JSON file in Application Support
- Support drag-and-drop of .xcodeproj/.xcworkspace/.ipa files to add projects

### 8. Install Tracker (`InstallTracking` → `ServerInstallTracker`)

- Logs every IPA download: timestamp, source IP, project name, user-agent
- Surfaces most recent install in the menu bar UI
- Stores install history in Application Support (simple JSON log)

### 9. Build Log Viewer

- Captures xcodebuild stdout/stderr in real time during builds
- Displayed in a scrollable text view (popover or sheet from menu bar)
- Accessible via "View Build Log" button in menu bar dropdown
- Retains log for the most recent build per project
- Color-coded: errors in red, warnings in yellow

### 10. IPA Import

- Users can import a pre-built .ipa file directly, skipping the build step
- Accessible via "Import IPA..." in the menu bar dropdown, or drag-and-drop onto the settings window
- Reads bundle ID and version from the IPA's embedded Info.plist
- Copies to the appropriate project's serve directory and generates manifest

### 11. macOS Notifications

- Uses `UNUserNotificationCenter` to post native macOS notifications
- Notify on: build success, build failure (with error summary), build started
- Clicking the notification opens the build log viewer (on failure) or copies the install URL (on success)

### 12. Push Notifications (`PushNotifying` → `ProwlNotifier`, `PushoverNotifier`, `NtfyNotifier`)

Push notifications to iOS devices when build events happen. Three providers, all behind a single `PushNotifying` protocol so they're interchangeable. Users pick which service(s) to enable in Settings. Multiple can be active simultaneously.

**Protocol:**
```swift
protocol PushNotifying {
    /// Sends a push notification with the given title, message, and priority.
    /// - Parameters:
    ///   - title: Short title (e.g., "Build Success")
    ///   - message: Body text (e.g., "rejog-ios ready — https://...")
    ///   - priority: Notification urgency level
    func send(title: String, message: String, priority: PushPriority) async throws
}

enum PushPriority: Int {
    case low = -1      // build started
    case normal = 0    // build success
    case high = 1      // build failure
}
```

**Events and priorities:**

| Event | Priority | Message includes |
|-------|----------|-----------------|
| Build started | low | Project name |
| Build success | normal | Project name + install URL |
| Build failure | high | Project name + first error line |

**Provider: Prowl**
- API: `POST https://api.prowlapp.com/publicapi/add`
- Parameters: `apikey`, `application` (RemoteDeploy), `event`, `description`, `priority` (-2 to 2)
- Settings field: Prowl API key
- No dependencies — just `URLSession`

**Provider: Pushover**
- API: `POST https://api.pushover.net/1/messages.json`
- Parameters: `token` (app token), `user` (user key), `title`, `message`, `priority` (-2 to 2), `url` (install link)
- Settings fields: Pushover App Token, Pushover User Key
- Pushover supports clickable URLs natively — include install URL on success

**Provider: ntfy**
- API: `POST https://<server>/<topic>`
- Headers: `Title`, `Priority` (1-5), `Click` (URL to open on tap)
- Body: plain text message
- Settings fields: ntfy server URL, ntfy topic
- Self-hosted or use `ntfy.sh` — user configures their own server URL
- Supports clickable URLs via `Click` header — include install URL on success

**Settings UI (Push Notifications section):**
```
Push Notifications
─────────────────
☑ Prowl
  API Key: [________________________]

☐ Pushover
  App Token: [____________________]
  User Key:  [____________________]

☑ ntfy
  Server URL: [https://ntfy.example.com]
  Topic:      [remotedeploy________]

Notify on:
  ☑ Build started
  ☑ Build success
  ☑ Build failure
```

---

## Key Technical Details

### Code Signing for Ad-Hoc
- The .ipa must be signed with an ad-hoc provisioning profile
- The target device's UDID must be included in the profile
- The development team ID for this project is `RDJQ523WP4`
- If using a development cert (not distribution), the export method should be `development` instead of `ad-hoc`
- Support `signingStyle=automatic` to let xcodebuild pick the right profile

### Tailscale HTTPS Certs
- `tailscale cert <hostname>` generates a Let's Encrypt cert valid for the MagicDNS name
- Certs auto-renew but the app should handle cert refresh (re-run `tailscale cert` periodically)
- Default cert location: the current directory when you run the command
- The app should store certs in `~/Library/Application Support/RemoteDeploy/certs/`

### iOS OTA Install Requirements
- MUST be served over HTTPS with a valid cert (self-signed won't work without MDM)
- The manifest.plist URL must also be HTTPS
- Bundle ID in manifest must match the .ipa
- Device UDID must be in the provisioning profile
- iOS shows a system alert: "Would you like to install <app>?" - user taps Install
- No MDM profile needed for ad-hoc distribution

### Build Output Caching
- Store the last successful .ipa and its build info (version, build number, timestamp)
- Only rebuild if source files changed (check git status or file modification dates)
- Show "Up to date" in menu if no changes since last build

---

## File Structure

```
RemoteDeploy/
├── RemoteDeploy.xcodeproj
├── RemoteDeploy/
│   ├── RemoteDeployApp.swift              # @main, MenuBarExtra
│   ├── Views/
│   │   ├── MenuBarView.swift              # Menu bar dropdown UI
│   │   ├── SettingsView.swift             # Settings window
│   │   ├── SetupAssistantView.swift       # 5-step first-launch setup wizard
│   │   ├── SetupSteps/
│   │   │   ├── TailscaleSetupStep.swift   # Step 1: Tailscale detection + instructions
│   │   │   ├── CertificateSetupStep.swift # Step 2: Cert generation + validation
│   │   │   ├── ProjectSetupStep.swift     # Step 3: Add first project
│   │   │   ├── PushNotifSetupStep.swift   # Step 4: Configure push providers + test
│   │   │   └── SetupCompleteStep.swift    # Step 5: Summary + install URL
│   │   ├── BuildLogView.swift             # Scrollable build log viewer
│   │   ├── ProjectFormView.swift          # Add/edit project form
│   │   └── PushNotifHelpPopover.swift     # Re-usable help popover for push provider setup
│   ├── Protocols/
│   │   ├── BuildEngineProtocol.swift      # Build engine interface
│   │   ├── DeployServerProtocol.swift     # HTTPS server interface
│   │   ├── TailscaleProviderProtocol.swift# Tailscale integration interface
│   │   ├── ManifestGenerating.swift       # Manifest generation interface
│   │   ├── InstallPageGenerating.swift    # Install page generation interface
│   │   ├── ProjectStoring.swift           # Project storage interface
│   │   ├── CertificateProviding.swift     # Certificate management interface
│   │   ├── InstallTracking.swift          # Install download tracking interface
│   │   └── PushNotifying.swift            # Push notification provider interface
│   ├── Services/
│   │   ├── XcodeBuildEngine.swift         # xcodebuild wrapper
│   │   ├── NIODeployServer.swift          # SwiftNIO HTTPS server
│   │   ├── CLITailscaleProvider.swift     # Tailscale CLI integration
│   │   ├── ManifestGenerator.swift        # Generates manifest.plist
│   │   ├── InstallPageGenerator.swift     # Generates HTML install page
│   │   ├── UserDefaultsProjectStore.swift # Project config persistence
│   │   ├── TailscaleCertificateProvider.swift # TLS cert management
│   │   ├── ServerInstallTracker.swift     # Logs IPA downloads
│   │   ├── IPAImporter.swift              # Import pre-built .ipa files
│   │   ├── NotificationManager.swift      # macOS notification posting
│   │   ├── ProwlNotifier.swift            # Prowl push notification provider
│   │   ├── PushoverNotifier.swift         # Pushover push notification provider
│   │   └── NtfyNotifier.swift             # ntfy push notification provider
│   ├── Models/
│   │   ├── ProjectConfig.swift            # Codable model for project settings
│   │   ├── BuildResult.swift              # Build outcome (success/failure, log, timestamp)
│   │   ├── InstallRecord.swift            # Single install event (timestamp, IP, project)
│   │   └── PushNotificationConfig.swift   # Per-provider config (keys, URLs, toggles)
│   └── Resources/
│       └── install-template.html          # HTML template
├── RemoteDeployTests/
│   ├── ManifestGeneratorTests.swift
│   ├── InstallPageGeneratorTests.swift
│   ├── ProjectConfigTests.swift
│   ├── BuildEngineTests.swift             # Uses mock process runner
│   ├── IPAImporterTests.swift
│   ├── InstallTrackerTests.swift
│   ├── ProwlNotifierTests.swift
│   ├── PushoverNotifierTests.swift
│   ├── NtfyNotifierTests.swift
│   └── Mocks/
│       ├── MockBuildEngine.swift
│       ├── MockDeployServer.swift
│       ├── MockTailscaleProvider.swift
│       ├── MockProjectStore.swift
│       ├── MockInstallTracker.swift
│       └── MockPushNotifier.swift
├── RemoteDeployIntegrationTests/
│   └── HTTPServerIntegrationTests.swift   # Real NIO server, self-signed cert
├── Package.swift or SPM dependencies
│   ├── swift-nio
│   ├── swift-nio-ssl
│   └── swift-nio-http2 (optional)
└── README.md
```

---

## Dependencies

- **SwiftNIO** (apple/swift-nio) - async networking
- **NIOSSL** (apple/swift-nio-ssl) - TLS support
- **NIOHTTP1** (included in SwiftNIO) - HTTP server
- No other external dependencies

All are Apple-maintained Swift packages.

---

## Workflow Once Built

### Developer (Mac):
1. Launch RemoteDeploy — first-launch setup assistant walks through Tailscale + cert + project
2. Click "Build & Deploy" (or pick project from dropdown if multiple)
3. Build log streams in real time; macOS notification fires on completion
4. Status shows "Ready" with green indicator
5. Click "Copy URL" to share with testers

### Tester (iPhone, anywhere in the world):
1. Open Safari
2. Navigate to `https://dans-mbp.tailf3787.ts.net:8443/rejog/` (or tap saved bookmark)
3. Tap "Install on This Device"
4. iOS prompts "Would you like to install Rejog?"
5. Tap Install
6. App appears on home screen in ~10s

### Shortcut:
- Save the install URL as a home screen bookmark on the iPhone
- One tap to check for new builds

### Pre-built IPA:
1. Click "Import IPA..." or drag .ipa onto settings window
2. App reads bundle ID and version from embedded Info.plist
3. IPA is immediately available for install — no build step needed

---

## Deferred Features (Explicitly NOT building now)

These were considered and intentionally deferred. Do not implement unless the user asks.

| Feature | Why deferred |
|---------|-------------|
| **Auto-build on file change** (FSEvents watcher) | Burns battery/CPU continuously. Rarely what you actually want — manual trigger is more predictable. |
| **QR code in menu bar** | You save the bookmark once and never scan again. Not worth the UI space. |
| **Build number auto-increment** | Modifies source files as a side effect, which is surprising. Should be opt-in if ever added. |
| **Webhook / push notification to phone** | Requires a push notification server or APNS setup. Overkill for v1 — macOS notification + manual Safari refresh is sufficient. |
| **Device log streaming** | Different problem domain (debugging vs deployment). Better as a separate tool. |

---

## Optional Future Enhancements

Features that could be valuable later but are not in scope for the initial build:

- **Build history list** — Show last N builds per project (not just the most recent)
- **Multiple simultaneous builds** — Queue or parallelize builds across projects
- **Automatic cert renewal** — Detect cert expiry and re-run `tailscale cert` proactively
- **Export/import settings** — Share RemoteDeploy configuration between machines
- **CLI companion** — `remotedeploy build rejog-ios` for scripting and CI integration

---

## Current Project Info (for first project setup)

- **Project path:** `/Users/plympton/src/rejog-ios-poc`
- **Project file:** `rejog-ios.xcodeproj`
- **Scheme:** `rejog-ios`
- **Bundle ID:** `net.rejog.voicememo`
- **Development Team:** `RDJQ523WP4`
- **Mac Tailscale hostname:** Check via `tailscale status --self --json | jq -r '.Self.DNSName'`
- **iPhone Tailscale hostname:** `iphone181.tailf3787.ts.net`

---

*Spec last updated: 2026-03-30*
