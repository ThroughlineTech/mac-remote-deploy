# App lifecycle from builds — how we do it in mac-remote-deploy

This project builds a macOS app (`RemoteDeploy.app`) and manages its full lifecycle — build, launch, stop, and clean up. Here's what we learned and the scripts that implement it.

## Key scripts

All in `scripts/`:

- **`graceful-relaunch.sh`** — The core start/stop primitive. Handles gracefully quitting a running macOS app, waiting for port release, and optionally relaunching. Uses AppleScript `tell application "X" to quit` for graceful shutdown, polls for process exit, force-kills (`kill -9`) after a configurable timeout, and waits for the port to be free before returning. Usage: `scripts/graceful-relaunch.sh <AppName> [--port PORT] [--timeout SECS] [--no-relaunch]`

- **`build-release.sh`** — Full release pipeline: xcodegen → xcodebuild (Release) → codesign → notarize → DMG + ZIP. For local/preview builds, you skip this and just use `xcodebuild` with Debug config and `open` the `.app` directly.

- **`ship-deploy.sh`** — Smart dispatch wrapper. Inspects git diff to decide whether a build is even needed (skips notarized builds for companion-only or docs-only changes). Delegates to `build-release.sh` when host code changed.

## Patterns that worked

1. **Graceful quit before launch.** Always stop the old instance before launching the new one. The sequence is: quit via AppleScript → poll for exit → force-kill if needed → wait for port free → then launch. This avoids port conflicts and zombie processes.

2. **AppleScript for quit, `open -a` for launch.** `osascript -e 'tell application "X" to quit'` triggers `NSApplication.terminate`, which lets the app clean up (save state, close connections). `open -a "AppName"` for relaunch. `pgrep -x "AppName"` to check if running.

3. **Port gating.** If the app binds a port (ours uses 8443), wait for `lsof -i :PORT` to report free before relaunching. Otherwise the new instance fails to bind.

4. **Timeout + force-kill fallback.** Give the app N seconds to quit gracefully (default 5), then `kill -9`. Don't wait forever.

5. **`--no-relaunch` flag.** Sometimes the caller wants to stop the app and handle launch itself (e.g., preview builds that launch from a specific derivedData path, not the installed app). The stop logic should be separable from the start logic.

6. **Preview builds vs release builds.** For quick iteration/preview, build Debug to a temp derivedData path and `open` the `.app` directly: `xcodebuild build ... -derivedDataPath /tmp/RemoteDeployPreview && open /tmp/RemoteDeployPreview/Build/Products/Debug/RemoteDeploy.app`. Release builds go through the full sign+notarize+DMG pipeline.

7. **Smart deploy gating.** Not every code change needs a full rebuild. We check git diff against an allowlist of host-relevant paths and skip the build entirely for changes that can't affect the binary.

## The stop → start sequence in practice (from ticket-config.md preview profile)

```bash
# Stop old instance, wait for port, don't relaunch (we'll launch the new build ourselves)
scripts/graceful-relaunch.sh RemoteDeploy --port 8443 --no-relaunch

# Build fresh
xcodegen generate
xcodebuild build -project RemoteDeploy.xcodeproj -scheme RemoteDeploy \
  -destination 'platform=macOS' -configuration Debug \
  -derivedDataPath /tmp/RemoteDeployPreview

# Launch new build
open /tmp/RemoteDeployPreview/Build/Products/Debug/RemoteDeploy.app
```

## Delete / cleanup

For deleting apps from builds, it's just `rm -rf` on the derivedData path (e.g., `/tmp/RemoteDeployPreview`). The app itself isn't "installed" anywhere persistent during dev — it runs from the build output directory. For installed releases, the DMG creates a drag-to-Applications flow, so uninstall is removing from `/Applications/`.
