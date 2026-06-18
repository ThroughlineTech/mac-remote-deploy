#!/bin/bash
# build-release.sh - Builds, signs, notarizes, and packages RemoteDeploy for
# distribution. TKT-060 (Phase 6): there are now TWO products - the headless
# backend (RemoteDeployServer) and the menu bar client (RemoteDeploy). By default
# this builds BOTH; pass --product to build just one.
#
# Usage:
#   ./scripts/build-release.sh                    # build + notarize BOTH products
#   ./scripts/build-release.sh --skip-notarize    # skip notarization (local testing)
#   ./scripts/build-release.sh --product server   # just the headless backend
#   ./scripts/build-release.sh --product menubar  # just the menu bar client
#   ./scripts/build-release.sh --product all      # both (default)
#
# Prerequisites:
#   - Xcode and xcodebuild
#   - XcodeGen (brew install xcodegen)
#   - A Developer ID Application certificate in your keychain
#   - An app-specific password stored in keychain for notarization
#
# To set up notarization credentials (one-time):
#   xcrun notarytool store-credentials "RemoteDeploy-Notarize" \
#     --apple-id "your@email.com" \
#     --team-id "ABCDE12345" \
#     --password "your-app-specific-password"
#
# Settings stored in ~/Library/Application Support/RemoteDeploy/ are never touched.

set -euo pipefail

# xcodebuild requires a full Xcode; the bare Command Line Tools cannot build the
# project. If the active developer directory (or an inherited $DEVELOPER_DIR)
# doesn't point at an Xcode, locate one and export DEVELOPER_DIR -- so deploy.sh
# works from a plain shell without the caller pre-exporting it. An explicit,
# valid DEVELOPER_DIR / xcode-select Xcode is respected and not overridden.
ensure_xcode() {
    local active xcb app
    active="${DEVELOPER_DIR:-$(xcode-select -p 2>/dev/null || true)}"
    if [[ -n "$active" && "$active" != *CommandLineTools* && -x "$active/usr/bin/xcodebuild" ]]; then
        export DEVELOPER_DIR="$active"
        return 0
    fi
    for app in \
        $(mdfind 'kMDItemCFBundleIdentifier == "com.apple.dt.Xcode"' 2>/dev/null) \
        /Applications/Xcode.app \
        /Applications/Xcode-beta.app; do
        xcb="$app/Contents/Developer/usr/bin/xcodebuild"
        if [[ -x "$xcb" ]]; then
            export DEVELOPER_DIR="$app/Contents/Developer"
            echo "--- Using Xcode: $app ---"
            return 0
        fi
    done
    echo "ERROR: xcodebuild needs a full Xcode, but none was found." >&2
    echo "       Active developer dir: ${active:-<unset>} (Command Line Tools cannot build)." >&2
    echo "       Fix: install Xcode and 'sudo xcode-select -s /Applications/Xcode.app'," >&2
    echo "       or export DEVELOPER_DIR=/path/to/Xcode.app/Contents/Developer." >&2
    exit 1
}
ensure_xcode

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="/tmp/RemoteDeployRelease"
SIGNING_IDENTITY="${SIGNING_IDENTITY:-Developer ID Application}"
DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-RDJQ523WP4}"
NOTARIZE_PROFILE="${NOTARIZE_PROFILE:-RemoteDeploy-Notarize}"
SKIP_NOTARIZE=false
PRODUCT="all"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --skip-notarize) SKIP_NOTARIZE=true ;;
        --product) shift; PRODUCT="${1:-all}" ;;
        --product=*) PRODUCT="${1#*=}" ;;
        *) echo "build-release: unknown argument: $1" >&2; exit 2 ;;
    esac
    shift
done

case "$PRODUCT" in
    all|server|menubar) ;;
    *) echo "build-release: --product must be all|server|menubar (got '$PRODUCT')" >&2; exit 2 ;;
esac

# Reads CFBundleShortVersionString from a product's Info.plist.
read_version() {
    grep CFBundleShortVersionString "$PROJECT_DIR/$1" -A1 | grep string \
        | sed 's/.*<string>\(.*\)<\/string>/\1/'
}

# build_product <scheme> <app_name> <info_plist_relpath>
# Builds Release, code signs, notarizes (unless skipped), and packages a DMG+zip.
build_product() {
    local scheme="$1" app_name="$2" info_plist="$3"
    local version; version="$(read_version "$info_plist")"
    local app_path="$BUILD_DIR/Build/Products/Release/${app_name}.app"
    local dmg_name="${app_name}-v${version}-macOS"

    echo ""
    echo "=== Building $app_name (scheme $scheme, v$version) ==="

    # SYMROOT/OBJROOT are set explicitly so products land in $BUILD_DIR regardless
    # of any "Custom" build location in Xcode prefs (command-line settings win).
    xcodebuild build \
        -project RemoteDeploy.xcodeproj \
        -scheme "$scheme" \
        -configuration Release \
        -destination 'platform=macOS' \
        -derivedDataPath "$BUILD_DIR" \
        SYMROOT="$BUILD_DIR/Build/Products" \
        OBJROOT="$BUILD_DIR/Build/Intermediates.noindex" \
        CODE_SIGN_IDENTITY="-" \
        2>&1 | tail -5

    if [[ ! -d "$app_path" ]]; then
        echo "ERROR: Build failed - $app_path not found" >&2
        exit 1
    fi
    echo "Build succeeded: $app_path ($(du -sh "$app_path" | cut -f1))"

    echo "--- Code signing with: $SIGNING_IDENTITY ---"
    codesign --deep --force --options runtime \
        --sign "$SIGNING_IDENTITY" \
        --timestamp \
        "$app_path"
    codesign --verify --deep --strict "$app_path"
    echo "Code signature valid"

    if [[ $SKIP_NOTARIZE == false ]]; then
        echo "--- Notarizing $app_name ---"
        local notarize_zip="$BUILD_DIR/${app_name}-notarize.zip"
        ditto -c -k --keepParent "$app_path" "$notarize_zip"
        echo "Submitting to Apple for notarization..."
        xcrun notarytool submit "$notarize_zip" \
            --keychain-profile "$NOTARIZE_PROFILE" \
            --wait
        echo "Stapling notarization ticket..."
        xcrun stapler staple "$app_path"
        echo "Notarization complete"
    else
        echo "--- Skipping notarization for $app_name ---"
    fi

    echo "--- Creating DMG for $app_name ---"
    local dmg_staging="$BUILD_DIR/dmg-staging-${app_name}"
    local dmg_path="$BUILD_DIR/${dmg_name}.dmg"
    rm -rf "$dmg_staging"
    mkdir -p "$dmg_staging"
    cp -R "$app_path" "$dmg_staging/"
    ln -s /Applications "$dmg_staging/Applications"
    hdiutil create -volname "$app_name" \
        -srcfolder "$dmg_staging" \
        -ov -format UDZO \
        "$dmg_path"
    echo "DMG: $dmg_path ($(du -sh "$dmg_path" | cut -f1))"

    local zip_path="$BUILD_DIR/${dmg_name}.zip"
    ditto -c -k --keepParent "$app_path" "$zip_path"
    echo "ZIP: $zip_path ($(du -sh "$zip_path" | cut -f1))"
}

echo "=== RemoteDeploy Release Build ==="
echo "Product:  $PRODUCT"
echo "Signing:  $SIGNING_IDENTITY"
echo "Notarize: $([[ $SKIP_NOTARIZE == true ]] && echo 'SKIP' || echo "$NOTARIZE_PROFILE")"

# Clean once, generate the project once, then build the requested product(s).
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
echo "--- Generating Xcode project ---"
cd "$PROJECT_DIR"
xcodegen generate

if [[ "$PRODUCT" == "all" || "$PRODUCT" == "server" ]]; then
    build_product "RemoteDeployServer" "RemoteDeployServer" "RemoteDeployServer/Info.plist"
fi
if [[ "$PRODUCT" == "all" || "$PRODUCT" == "menubar" ]]; then
    build_product "RemoteDeploy" "RemoteDeploy" "RemoteDeploy/Info.plist"
fi

echo ""
echo "=== Release Build Complete ($PRODUCT) ==="
ls -1 "$BUILD_DIR"/*.dmg 2>/dev/null || true
