#!/bin/bash
# build-release.sh — Builds, signs, notarizes, and packages RemoteDeploy for distribution.
#
# Usage:
#   ./scripts/build-release.sh
#   ./scripts/build-release.sh --skip-notarize   # Skip notarization (for local testing)
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
VERSION=$(grep CFBundleShortVersionString "$PROJECT_DIR/RemoteDeploy/Info.plist" -A1 | grep string | sed 's/.*<string>\(.*\)<\/string>/\1/')
APP_NAME="RemoteDeploy"
DMG_NAME="RemoteDeploy-v${VERSION}-macOS"
SIGNING_IDENTITY="${SIGNING_IDENTITY:-Developer ID Application}"
DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-RDJQ523WP4}"
NOTARIZE_PROFILE="${NOTARIZE_PROFILE:-RemoteDeploy-Notarize}"
SKIP_NOTARIZE=false

for arg in "$@"; do
    case $arg in
        --skip-notarize) SKIP_NOTARIZE=true ;;
    esac
done

echo "=== RemoteDeploy Release Build ==="
echo "Version: $VERSION"
echo "Signing: $SIGNING_IDENTITY"
echo "Notarize: $([[ $SKIP_NOTARIZE == true ]] && echo 'SKIP' || echo $NOTARIZE_PROFILE)"
echo ""

# Clean previous build
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# Step 1: Generate Xcode project
echo "--- Generating Xcode project ---"
cd "$PROJECT_DIR"
xcodegen generate

# Step 2: Build Release
# SYMROOT/OBJROOT are set explicitly so the build products land in $BUILD_DIR
# regardless of any "Custom" build location configured in Xcode's preferences
# (IDECustomBuildProductsPath). Without this, a relocated build folder -- e.g.
# DerivedData/products moved to an external volume -- overrides -derivedDataPath
# and the .app ends up somewhere this script doesn't look for it. Command-line
# build settings take precedence over the IDE preference, so this keeps the
# build self-contained under /tmp as intended.
echo "--- Building Release configuration ---"
xcodebuild build \
    -project RemoteDeploy.xcodeproj \
    -scheme RemoteDeploy \
    -configuration Release \
    -destination 'platform=macOS' \
    -derivedDataPath "$BUILD_DIR" \
    SYMROOT="$BUILD_DIR/Build/Products" \
    OBJROOT="$BUILD_DIR/Build/Intermediates.noindex" \
    CODE_SIGN_IDENTITY="-" \
    2>&1 | tail -5

APP_PATH="$BUILD_DIR/Build/Products/Release/${APP_NAME}.app"

if [[ ! -d "$APP_PATH" ]]; then
    echo "ERROR: Build failed — $APP_PATH not found"
    exit 1
fi

echo "Build succeeded: $APP_PATH"
echo "Size: $(du -sh "$APP_PATH" | cut -f1)"

# Step 3: Codesign the app bundle with Developer ID
echo "--- Code signing with: $SIGNING_IDENTITY ---"
codesign --deep --force --options runtime \
    --sign "$SIGNING_IDENTITY" \
    --timestamp \
    "$APP_PATH"
codesign --verify --deep --strict "$APP_PATH"
echo "Code signature valid"

# Step 4: Notarize (unless skipped)
if [[ $SKIP_NOTARIZE == false ]]; then
    echo "--- Notarizing ---"

    # Create a zip for notarization
    NOTARIZE_ZIP="$BUILD_DIR/${APP_NAME}-notarize.zip"
    ditto -c -k --keepParent "$APP_PATH" "$NOTARIZE_ZIP"

    echo "Submitting to Apple for notarization..."
    xcrun notarytool submit "$NOTARIZE_ZIP" \
        --keychain-profile "$NOTARIZE_PROFILE" \
        --wait

    echo "Stapling notarization ticket..."
    xcrun stapler staple "$APP_PATH"

    echo "Notarization complete"
else
    echo "--- Skipping notarization ---"
fi

# Step 5: Create DMG
echo "--- Creating DMG ---"
DMG_STAGING="$BUILD_DIR/dmg-staging"
DMG_PATH="$BUILD_DIR/${DMG_NAME}.dmg"

mkdir -p "$DMG_STAGING"
cp -R "$APP_PATH" "$DMG_STAGING/"

# Create a symlink to /Applications for drag-and-drop install
ln -s /Applications "$DMG_STAGING/Applications"

# Create the DMG
hdiutil create -volname "$APP_NAME" \
    -srcfolder "$DMG_STAGING" \
    -ov -format UDZO \
    "$DMG_PATH"

echo ""
echo "=== Release Build Complete ==="
echo "DMG: $DMG_PATH ($(du -sh "$DMG_PATH" | cut -f1))"

# Also create a zip for GitHub releases
ZIP_PATH="$BUILD_DIR/${DMG_NAME}.zip"
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"
echo "ZIP: $ZIP_PATH ($(du -sh "$ZIP_PATH" | cut -f1))"

echo ""
echo "To upload to GitHub:"
echo "  gh release create v${VERSION} '$DMG_PATH' '$ZIP_PATH' --title 'v${VERSION}'"
