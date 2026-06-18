#!/bin/bash
#
# deploy.sh - build BOTH RemoteDeploy products from source and install them as
# self-starting apps on THIS Mac, with no runtime dependency on Xcode,
# DerivedData, or this repo. TKT-060 (Phase 6): two products now -
#   - RemoteDeployServer (headless backend; binds :8080/:8443; the LaunchAgent
#     that actually serves builds) -> installed + started FIRST.
#   - RemoteDeploy (menu bar client; binds nothing; talks to the server over
#     loopback) -> installed + started SECOND.
#
# What it does, in order, per product:
#   1. Build Release .apps (default: fast, signed-but-not-notarized).
#   2. Stop each LaunchAgent so it won't relaunch the old binary mid-swap.
#   3. Gracefully quit the running app and wait for its port to free.
#   4. Install the fresh .app into /Applications.
#   5. Install/refresh the LaunchAgent (auto-start at login + crash restart).
#   6. Start the new version via launchd (server before menu bar).
#
# The build happens entirely in /tmp - it never touches an external/relocated
# DerivedData volume. The installed apps in /Applications are self-contained.
#
# Usage:
#   ./deploy.sh              Fast install (build-release.sh --skip-notarize).
#   ./deploy.sh --release    Full signed + notarized build (slower, distributable).
#   ./deploy.sh --no-build   Reuse the last /tmp build output; just (re)install.
#
# Prerequisites: Xcode command-line tools, XcodeGen (brew install xcodegen),
# and - for the default path - a "Developer ID Application" cert in the keychain
# (use --release on a machine that has notarization credentials configured).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR"
INSTALL_DIR="/Applications"
BUILD_PRODUCTS="/tmp/RemoteDeployRelease/Build/Products/Release"
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

echo "=== RemoteDeploy deploy ($MODE) - server + menu bar ==="

# --- 1. Build both products ------------------------------------------------
if $DO_BUILD; then
    if [[ "$MODE" == "release" ]]; then
        echo "--- Building both products (full signed + notarized) ---"
        "$SCRIPT_DIR/scripts/build-release.sh"
    else
        echo "--- Building both products (fast, skip notarization) ---"
        "$SCRIPT_DIR/scripts/build-release.sh" --skip-notarize
    fi
else
    echo "--- Skipping build (--no-build); reusing last output ---"
fi

# install_product <app_name> <plist_label> <port-or-empty>
install_product() {
    local app_name="$1" plist_label="$2" port="$3"
    local built_app="$BUILD_PRODUCTS/$app_name.app"
    local installed_app="$INSTALL_DIR/$app_name.app"
    local plist_src="$PROJECT_DIR/LaunchAgent/$plist_label.plist"
    local plist_dst="$HOME/Library/LaunchAgents/$plist_label.plist"

    echo ""
    echo "=== Installing $app_name ==="
    if [[ ! -d "$built_app" ]]; then
        echo "ERROR: built app not found at $built_app" >&2
        echo "       (run without --no-build, or check the build output above)" >&2
        exit 1
    fi

    # Stop the agent so KeepAlive won't relaunch the old binary mid-swap.
    if launchctl print "$GUI_DOMAIN/$plist_label" >/dev/null 2>&1; then
        echo "--- Stopping LaunchAgent $plist_label ---"
        launchctl bootout "$GUI_DOMAIN/$plist_label" 2>/dev/null || true
    fi

    # Gracefully quit the running app and free its port (if it binds one).
    echo "--- Quitting running $app_name (if any) ---"
    if [[ -n "$port" ]]; then
        "$SCRIPT_DIR/scripts/graceful-relaunch.sh" "$app_name" --port "$port" --no-relaunch
    else
        "$SCRIPT_DIR/scripts/graceful-relaunch.sh" "$app_name" --no-relaunch
    fi

    echo "--- Installing to $installed_app ---"
    rm -rf "$installed_app"
    ditto "$built_app" "$installed_app"

    echo "--- Installing LaunchAgent $plist_label ---"
    mkdir -p "$(dirname "$plist_dst")"
    cp "$plist_src" "$plist_dst"

    echo "--- Starting $app_name via launchd ---"
    launchctl bootstrap "$GUI_DOMAIN" "$plist_dst"
    launchctl kickstart -k "$GUI_DOMAIN/$plist_label"

    local version build
    version=$(defaults read "$installed_app/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo "?")
    build=$(defaults read "$installed_app/Contents/Info.plist" CFBundleVersion 2>/dev/null || echo "?")
    echo "Deployed $app_name v$version (build $build) -> $installed_app"
}

# --- Drop the legacy single-app Login Item (avoid double-launch) -----------
echo "--- Removing legacy Login Item (if present) ---"
osascript -e 'tell application "System Events" to delete login item "RemoteDeploy"' 2>/dev/null || true

# --- Install the SERVER first (so it is up before the menu bar connects) ----
install_product "RemoteDeployServer" "com.remotedeploy.server" "8443"

# --- Then the MENU BAR client ----------------------------------------------
install_product "RemoteDeploy" "com.remotedeploy.app" ""

echo ""
echo "=== Deploy complete ==="
echo "Server logs:   /tmp/remotedeploy.server.log"
echo "Menu bar logs: /tmp/remotedeploy.launchagent.log"
