#!/bin/bash
# capture-screenshots.sh — Captures all iOS companion screenshots via XCUITest.
# Handles pairing credentials via UserDefaults before launching the test.
set -euo pipefail

SIM_NAME="iPhone 14 Plus"
SIM_ID=$(xcrun simctl list devices booted --json | python3 -c "
import sys,json
d=json.load(sys.stdin)
for rt in d['devices'].values():
  for dev in rt:
    if dev['state']=='Booted' and '$SIM_NAME' in dev['name']:
      print(dev['udid']); sys.exit(0)
print('')
" 2>/dev/null)

if [ -z "$SIM_ID" ]; then
  echo "No booted '$SIM_NAME' simulator found. Booting one..."
  SIM_ID=$(xcrun simctl list devices available --json | python3 -c "
import sys,json
d=json.load(sys.stdin)
for rt in d['devices'].values():
  for dev in rt:
    if '$SIM_NAME' in dev['name'] and dev['isAvailable']:
      print(dev['udid']); sys.exit(0)
")
  xcrun simctl boot "$SIM_ID"
  sleep 5
fi

echo "Using simulator: $SIM_ID ($SIM_NAME)"

# Clean output dir
rm -rf /tmp/rd-screenshots
mkdir -p /tmp/rd-screenshots

# Build first so the app is installed, then write defaults
echo "Building..."
xcodebuild build-for-testing \
  -project RemoteDeploy.xcodeproj \
  -scheme RemoteDeployCompanionUITests \
  -destination "platform=iOS Simulator,id=$SIM_ID" \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -3

# Install the app
APP_PATH=$(find ~/Library/Developer/Xcode/DerivedData/RemoteDeploy-*/Build/Products/Debug-iphonesimulator -name "RemoteDeployCompanion.app" -type d 2>/dev/null | head -1)
xcrun simctl install "$SIM_ID" "$APP_PATH" 2>/dev/null || true

# Now seed credentials AFTER the app is installed
xcrun simctl spawn "$SIM_ID" defaults write com.remotedeploy.companion RD_URL "http://localhost:8080"
xcrun simctl spawn "$SIM_ID" defaults write com.remotedeploy.companion RD_TOKEN "e2etest1"
xcrun simctl spawn "$SIM_ID" defaults write com.remotedeploy.companion RD_NAME "fubar's Mac mini"
echo "Pairing credentials seeded"

# Verify
xcrun simctl spawn "$SIM_ID" defaults read com.remotedeploy.companion RD_URL

# Run the screenshot tests (without rebuilding)
echo "Running screenshot tests..."
xcodebuild test-without-building \
  -project RemoteDeploy.xcodeproj \
  -scheme RemoteDeployCompanionUITests \
  -destination "platform=iOS Simulator,id=$SIM_ID" \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "Test Case|Saved|error:|📸"

echo ""
echo "Screenshots:"
ls -la /tmp/rd-screenshots/

# Copy to project
cp /tmp/rd-screenshots/*.png screenshots/ 2>/dev/null || true
echo ""
echo "Copied to screenshots/"
ls screenshots/*.png
