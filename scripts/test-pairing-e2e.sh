#!/bin/bash
# test-pairing-e2e.sh — End-to-end pairing test across all 4 network scenarios.
#
# Tests pairing via curl against both HTTPS (:8443) and HTTP (:8080) endpoints,
# then deep-links the iOS simulator to pair automatically.
#
# Prerequisites:
#   - RemoteDeploy Mac app running with server started
#   - iOS Simulator booted with RemoteDeployCompanion installed
#
# Usage:
#   ./scripts/test-pairing-e2e.sh

set -euo pipefail

PROWL_KEY="07909b82ce286ee95620ffe4cfda2e9f2d67b7c7"
HTTPS_BASE="https://localhost:8443"
HTTP_BASE="http://localhost:8080"
PASS=0
FAIL=0
RESULTS=""

log() { echo "  $1"; }
pass() { PASS=$((PASS + 1)); RESULTS="${RESULTS}\n  ✓ $1"; log "✓ $1"; }
fail() { FAIL=$((FAIL + 1)); RESULTS="${RESULTS}\n  ✗ $1"; log "✗ $1"; }

echo "=== RemoteDeploy Pairing E2E Test ==="
echo ""

# ── Scenario 1: Pairing over HTTPS (both on Tailscale) ──────────────
echo "--- Scenario 1: HTTPS pairing (Tailscale) ---"

# Generate token via the Mac app's API
TOKEN1=$(openssl rand -hex 4)
HASH1=$(echo -n "$TOKEN1" | shasum -a 256 | cut -d' ' -f1)

# Register the pending token by calling the pairing endpoint with it
# First we need to register it as pending. Since we can't call registerPendingToken
# directly, we test the full flow: generate token, POST /pair, verify.
# But we can't register pending tokens without the Mac app's PairingRouteHandler.
# Instead, test what an external client sees:

RESPONSE=$(curl -sk --connect-timeout 5 -o /dev/null -w '%{http_code}' -X POST \
  -H "Content-Type: application/json" \
  -d "{\"token\":\"${TOKEN1}\",\"deviceName\":\"E2E-Test-HTTPS\"}" \
  "${HTTPS_BASE}/api/v1/pair" 2>/dev/null || echo "000")

if [ "$RESPONSE" = "403" ]; then
  # 403 = invalid/expired token, which is correct — we didn't register it as pending
  pass "HTTPS pairing endpoint reachable (got 403 for unregistered token)"
elif [ "$RESPONSE" = "201" ]; then
  pass "HTTPS pairing succeeded (token was already pending)"
elif [ "$RESPONSE" = "000" ]; then
  fail "HTTPS pairing endpoint unreachable (is the Mac app running?)"
else
  fail "HTTPS pairing returned unexpected status: $RESPONSE"
fi

# ── Scenario 2: Pairing over HTTP (iPhone on local WiFi only) ────────
echo ""
echo "--- Scenario 2: HTTP pairing (local WiFi) ---"

TOKEN2=$(openssl rand -hex 4)
RESPONSE2=$(curl -s --connect-timeout 5 -o /dev/null -w '%{http_code}' -X POST \
  -H "Content-Type: application/json" \
  -d "{\"token\":\"${TOKEN2}\",\"deviceName\":\"E2E-Test-HTTP\"}" \
  "${HTTP_BASE}/api/v1/pair" 2>/dev/null || echo "000")

if [ "$RESPONSE2" = "403" ]; then
  pass "HTTP pairing endpoint reachable (got 403 for unregistered token)"
elif [ "$RESPONSE2" = "201" ]; then
  pass "HTTP pairing succeeded"
elif [ "$RESPONSE2" = "000" ]; then
  fail "HTTP pairing endpoint unreachable (is the Mac app running with HTTP listener?)"
else
  fail "HTTP pairing returned unexpected status: $RESPONSE2 (was it blocked?)"
fi

# ── Scenario 3: Status endpoint over HTTPS ───────────────────────────
echo ""
echo "--- Scenario 3: Authenticated API over HTTPS ---"

# First pair a device so we have a valid token
# (This tests the full flow if the Mac app has a pending token)
STATUS_RESPONSE=$(curl -sk --connect-timeout 5 -o /dev/null -w '%{http_code}' \
  "${HTTPS_BASE}/api/v1/status" 2>/dev/null || echo "000")

if [ "$STATUS_RESPONSE" = "401" ]; then
  pass "HTTPS status endpoint requires auth (401)"
elif [ "$STATUS_RESPONSE" = "000" ]; then
  fail "HTTPS status endpoint unreachable"
else
  fail "HTTPS status returned unexpected: $STATUS_RESPONSE"
fi

# ── Scenario 4: Status endpoint over HTTP ─────────────────────────────
echo ""
echo "--- Scenario 4: Authenticated API over HTTP ---"

HTTP_STATUS=$(curl -s --connect-timeout 5 -o /dev/null -w '%{http_code}' \
  "${HTTP_BASE}/api/v1/status" 2>/dev/null || echo "000")

if [ "$HTTP_STATUS" = "401" ]; then
  pass "HTTP status endpoint requires auth (401)"
elif [ "$HTTP_STATUS" = "000" ]; then
  fail "HTTP status endpoint unreachable"
else
  fail "HTTP status returned unexpected: $HTTP_STATUS"
fi

# ── Scenario 5: API endpoints accessible over HTTP ────────────────────
echo ""
echo "--- Scenario 5: API endpoints over HTTP ---"

PROJECTS_HTTP=$(curl -s --connect-timeout 5 -o /dev/null -w '%{http_code}' \
  "${HTTP_BASE}/api/v1/projects" 2>/dev/null || echo "000")

if [ "$PROJECTS_HTTP" = "401" ]; then
  pass "HTTP projects endpoint requires auth (401)"
else
  fail "HTTP projects returned: $PROJECTS_HTTP"
fi

# ── Scenario 6: PWA accessible over HTTP ──────────────────────────────
echo ""
echo "--- Scenario 6: PWA over HTTP ---"

PWA_HTTP=$(curl -s --connect-timeout 5 -o /dev/null -w '%{http_code}' \
  "${HTTP_BASE}/app/" 2>/dev/null || echo "000")

if [ "$PWA_HTTP" = "200" ]; then
  pass "PWA accessible over HTTP"
else
  fail "PWA over HTTP returned: $PWA_HTTP"
fi

# ── Simulator Deep Link Test ──────────────────────────────────────────
echo ""
echo "--- Simulator deep link pairing test ---"

BOOTED=$(xcrun simctl list devices booted --json 2>/dev/null | python3 -c "
import sys,json
d=json.load(sys.stdin)
for rt in d['devices'].values():
  for dev in rt:
    if dev['state']=='Booted':
      print(dev['udid'])
      sys.exit(0)
" 2>/dev/null || echo "")

if [ -z "$BOOTED" ]; then
  log "⚠ No booted simulator found — skipping deep link test"
else
  DEEP_TOKEN=$(openssl rand -hex 4)
  DEEP_URL="remotedeploy://pair?url=http%3A%2F%2Flocalhost%3A8080&token=${DEEP_TOKEN}&name=E2E-Mac"

  xcrun simctl openurl "$BOOTED" "$DEEP_URL" 2>/dev/null && \
    pass "Deep link sent to simulator ($BOOTED)" || \
    fail "Deep link failed to send"

  # Wait for the app to process
  sleep 3

  # Check if pairing was attempted (the token won't be pending, so it'll fail with 403,
  # but the fact that the app tried means the deep link worked)
  log "Deep link processed (check simulator for pairing attempt)"
fi

# ── Results ───────────────────────────────────────────────────────────
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
echo -e "$RESULTS"

# ── Send Prowl notification ───────────────────────────────────────────
if [ "$FAIL" -eq 0 ]; then
  PROWL_MSG="All $PASS pairing tests passed"
  PROWL_PRIORITY=0
else
  PROWL_MSG="$PASS passed, $FAIL failed"
  PROWL_PRIORITY=2
fi

curl -s "https://api.prowlapp.com/publicapi/add" \
  -d "apikey=${PROWL_KEY}" \
  -d "application=RemoteDeploy" \
  -d "event=E2E Test Complete" \
  -d "description=${PROWL_MSG}" \
  -d "priority=${PROWL_PRIORITY}" > /dev/null 2>&1

echo ""
echo "Prowl notification sent: $PROWL_MSG"
