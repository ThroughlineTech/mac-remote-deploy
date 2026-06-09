#!/bin/bash
#
# deploy.sh — build RemoteDeploy from source and install it as a self-starting
# app on THIS Mac, with no runtime dependency on Xcode, DerivedData, or this repo.
#
# What it does, in order:
#   1. Build a Release .app (default: fast, signed-but-not-notarized).
#   2. Stop the LaunchAgent so it won't relaunch the old binary mid-swap.
#   3. Gracefully quit the running RemoteDeploy and wait for its port to free.
#   4. Install the fresh .app into /Applications.
#   5. Install/refresh the LaunchAgent (auto-start at login + crash restart).
#   6. Remove the legacy Login Item so it can't double-launch.
#   7. Start the new version via launchd.
#
# The build happens entirely in /tmp — it never touches an external/relocated
# DerivedData volume. The installed app in /Applications is fully self-contained.
#
# Usage:
#   ./deploy.sh              Fast install (build-release.sh --skip-notarize).
#   ./deploy.sh --release    Full signed + notarized build (slower, distributable).
#   ./deploy.sh --no-build   Reuse the last /tmp build output; just (re)install.
#
# Prerequisites: Xcode command-line tools, XcodeGen (brew install xcodegen),
# and — for the default path — a "Developer ID Application" cert in the keychain
# (use --release on a machine that has notarization credentials configured).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR"

APP_NAME="RemoteDeploy"
BUNDLE_ID="com.remotedeploy.app"
PORT="8443"
INSTALL_DIR="/Applications"
INSTALLED_APP="$INSTALL_DIR/$APP_NAME.app"
BUILD_APP="/tmp/RemoteDeployRelease/Build/Products/Release/$APP_NAME.app"

PLIST_LABEL="com.remotedeploy.app"
PLIST_SRC="$PROJECT_DIR/LaunchAgent/$PLIST_LABEL.plist"
PLIST_DST="$HOME/Library/LaunchAgents/$PLIST_LABEL.plist"
GUI_DOMAIN="gui/$(id -u)"

MODE="fast"
DO_BUILD=true
for arg in "$@"; do
    case "$arg" in
        --release)  MODE="release" ;;
        --no-build) DO_BUILD=false ;;
        -h|--help)  grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "deploy.sh: unknown argument: $arg" >&2; exit 2 ;;
    esac
done

echo "=== RemoteDeploy deploy ($MODE) ==="

# --- 1. Build --------------------------------------------------------------
if $DO_BUILD; then
    if [[ "$MODE" == "release" ]]; then
        echo "--- Building (full signed + notarized) ---"
        "$SCRIPT_DIR/scripts/build-release.sh"
    else
        echo "--- Building (fast, skip notarization) ---"
        "$SCRIPT_DIR/scripts/build-release.sh" --skip-notarize
    fi
else
    echo "--- Skipping build (--no-build); reusing last output ---"
fi

if [[ ! -d "$BUILD_APP" ]]; then
    echo "ERROR: built app not found at $BUILD_APP" >&2
    echo "       (run without --no-build, or check the build output above)" >&2
    exit 1
fi
echo "Build artifact: $BUILD_APP"

# --- 2. Stop the LaunchAgent so KeepAlive won't relaunch the old binary -----
if launchctl print "$GUI_DOMAIN/$PLIST_LABEL" >/dev/null 2>&1; then
    echo "--- Stopping existing LaunchAgent ---"
    launchctl bootout "$GUI_DOMAIN/$PLIST_LABEL" 2>/dev/null || true
fi

# --- 3. Gracefully quit the running app ------------------------------------
echo "--- Quitting running $APP_NAME (if any) ---"
"$SCRIPT_DIR/scripts/graceful-relaunch.sh" "$APP_NAME" --port "$PORT" --no-relaunch

# --- 4. Install into /Applications -----------------------------------------
echo "--- Installing to $INSTALLED_APP ---"
rm -rf "$INSTALLED_APP"
ditto "$BUILD_APP" "$INSTALLED_APP"

# --- 5. Install / refresh the LaunchAgent ----------------------------------
echo "--- Installing LaunchAgent ---"
mkdir -p "$(dirname "$PLIST_DST")"
cp "$PLIST_SRC" "$PLIST_DST"

# --- 6. Drop the legacy Login Item (avoid double-launch with the agent) -----
echo "--- Removing legacy Login Item (if present) ---"
osascript -e "tell application \"System Events\" to delete login item \"$APP_NAME\"" 2>/dev/null || true

# --- 7. Start via launchd ---------------------------------------------------
echo "--- Starting $APP_NAME via launchd ---"
launchctl bootstrap "$GUI_DOMAIN" "$PLIST_DST"
launchctl kickstart -k "$GUI_DOMAIN/$PLIST_LABEL"

VERSION=$(defaults read "$INSTALLED_APP/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo "?")
BUILD=$(defaults read "$INSTALLED_APP/Contents/Info.plist" CFBundleVersion 2>/dev/null || echo "?")

echo ""
echo "=== Deployed RemoteDeploy v$VERSION (build $BUILD) ==="
echo "Installed:  $INSTALLED_APP"
echo "Autostart:  $PLIST_DST (RunAtLoad + crash restart)"
echo "Logs:       /tmp/remotedeploy.launchagent.log"
