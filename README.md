# RemoteDeploy

A macOS menu bar app that builds, signs, and serves your iOS apps over HTTPS. Install on any iPhone from anywhere with a single tap in Safari. No USB cable, no TestFlight, no waiting.

## The Problem

Deploying iOS builds to a test device is more painful than it should be. TestFlight takes 15-30 minutes to process each upload, USB deployment requires physical access to the device, and tools like Xcode's wireless debugging require both devices on the same network. If you're iterating quickly or your test device is somewhere else entirely, none of these options work well.

RemoteDeploy eliminates all of that. It builds your app, serves the signed IPA over HTTPS via Tailscale, and your iPhone installs it from a URL in Safari in about 10 seconds, from anywhere in the world.

## How It Works

```
+-----------------------+         Tailscale VPN          +--------------------+
|   Mac (developer)     |<------------------------------>|  iPhone (remote)   |
|                       |                                |                    |
|  Menu Bar App:        |    HTTPS (port 8443)           |  Safari:           |
|  - Builds .ipa        |<------------------------------>|  - Opens install   |
|  - Serves via HTTPS   |    itms-services:// manifest   |    page            |
|  - Shows status       |                                |  - Taps Install    |
|                       |                                |  - iOS downloads   |
+-----------------------+                                +--------------------+
```

RemoteDeploy runs `xcodebuild` to archive and export your app with ad-hoc signing, then serves the IPA over a local HTTPS server built on SwiftNIO. Tailscale provides the secure tunnel and a valid TLS certificate, so iOS accepts the OTA install without any MDM profile. On the iPhone side, you open a URL in Safari, tap Install, and the app appears on your home screen.

## Features

- **One-click build and deploy** -- archive, sign, serve, and notify in a single action
- **Works from anywhere** -- Tailscale connects your Mac and iPhone across any network
- **Multiple project support** -- configure as many iOS projects as you want, each with its own install URL
- **Real-time build log** -- color-coded xcodebuild output streamed live to a log viewer
- **Push notifications** -- get notified on your phone via Prowl, Pushover, or ntfy when builds finish
- **IPA import** -- skip the build step entirely by importing a pre-built IPA
- **Setup wizard** -- a 5-step guided assistant handles Tailscale, certificates, and project configuration
- **Protocol-oriented architecture** -- every major component is defined as a protocol, making the codebase testable and extensible

## Quick Start

### Prerequisites

- macOS 14 or later
- Xcode installed (full installation, not just Command Line Tools)
- [Tailscale](https://tailscale.com/download) installed on both your Mac and iPhone, signed into the same tailnet
- Apple Developer Program membership with an ad-hoc provisioning profile that includes your test device's UDID

### Install

1. Download the latest `.dmg` from [Releases](https://github.com/plympton/mac-remote-deploy/releases)
2. Drag RemoteDeploy to your Applications folder
3. Launch it -- the setup wizard walks you through everything

### Build from Source

```bash
git clone https://github.com/plympton/mac-remote-deploy.git
cd mac-remote-deploy
xcodegen generate
open RemoteDeploy.xcodeproj
# Build and run (Cmd+R)
```

## Usage

RemoteDeploy lives in your menu bar -- there is no dock icon or main window.

1. **Launch** -- the package icon appears in your menu bar
2. **Setup wizard** -- configures Tailscale detection, TLS certificates, and your first project
3. **Build & Deploy** -- click the button, watch the build log, wait for the green status indicator
4. **Install** -- open the install URL in Safari on your iPhone and tap Install

The full walkthrough, including troubleshooting, is in [docs/HOW-TO-USE.md](docs/HOW-TO-USE.md).

## Architecture

RemoteDeploy uses a protocol-oriented architecture. Every major component is defined as a Swift protocol with a concrete implementation, so you can swap implementations, write unit tests with mocks, and extend the app without modifying existing code.

| Protocol | Implementation | Purpose |
|----------|---------------|---------|
| `BuildEngineProtocol` | `XcodeBuildEngine` | Wraps xcodebuild archive + export |
| `DeployServerProtocol` | `NIODeployServer` | HTTPS server via SwiftNIO |
| `TailscaleProviderProtocol` | `CLITailscaleProvider` | Hostname detection, cert management |
| `ManifestGenerating` | `ManifestGenerator` | Generates OTA manifest.plist |
| `InstallPageGenerating` | `InstallPageGenerator` | Generates HTML install page |
| `ProjectStoring` | `UserDefaultsProjectStore` | CRUD for project configurations |
| `CertificateProviding` | `TailscaleCertificateProvider` | Loads and refreshes TLS certs |
| `InstallTracking` | `ServerInstallTracker` | Logs IPA downloads |
| `PushNotifying` | `ProwlNotifier`, `PushoverNotifier`, `NtfyNotifier` | Push notifications on build events |

See [docs/remote-deploy-server-spec.md](docs/remote-deploy-server-spec.md) for the full technical spec.

## Push Notifications

Three push notification providers are supported. Enable any combination of them in Settings.

- **Prowl** -- iOS push notifications via the Prowl app. Requires an API key from [prowlapp.com](https://www.prowlapp.com/).
- **Pushover** -- cross-platform notifications with clickable install URLs. Requires an app token and user key from [pushover.net](https://pushover.net/).
- **ntfy** -- free, open-source notifications. Use the public server at [ntfy.sh](https://ntfy.sh/) or self-host your own.

Each provider has a "Send Test Notification" button in Settings so you can verify the configuration works before relying on it.

## Contributing

Contributions are welcome. Here's how to get started:

- Fork the repo and open a pull request against `main`
- Run tests before submitting:
  ```bash
  xcodebuild test -scheme RemoteDeployTests -destination 'platform=macOS'
  ```
- All major components use protocols -- you can add new implementations (a new push notification provider, a different build engine, etc.) without changing existing code
- See [docs/remote-deploy-server-spec.md](docs/remote-deploy-server-spec.md) for architecture details and design decisions

## License

MIT

## Acknowledgments

- [SwiftNIO](https://github.com/apple/swift-nio) and [NIOSSL](https://github.com/apple/swift-nio-ssl) by Apple for the HTTPS server
- [Tailscale](https://tailscale.com/) for making secure networking simple enough to build on top of
