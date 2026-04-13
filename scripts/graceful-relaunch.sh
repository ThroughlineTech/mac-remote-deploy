#!/usr/bin/env bash
# graceful-relaunch.sh — Gracefully quit and optionally relaunch a macOS app.
#
# Usage:
#   scripts/graceful-relaunch.sh <AppName> [--port PORT] [--timeout SECS] [--no-relaunch]
#
# Examples:
#   # Quit RemoteDeploy, wait for port 8443 to be free, then relaunch:
#   scripts/graceful-relaunch.sh RemoteDeploy --port 8443
#
#   # Quit RemoteDeploy without relaunching (caller handles launch):
#   scripts/graceful-relaunch.sh RemoteDeploy --port 8443 --no-relaunch
#
#   # Quit ClaudeDash with a 10-second grace period before force-kill:
#   scripts/graceful-relaunch.sh ClaudeDash --port 8787 --timeout 10
#
#   # Just quit any app gracefully:
#   scripts/graceful-relaunch.sh SomeApp --no-relaunch
#
# Arguments:
#   $1              App name (required, e.g. "RemoteDeploy" or "ClaudeDash")
#   --port PORT     Optional port to wait for release before returning
#   --timeout SECS  Grace period before force-kill (default: 5)
#   --no-relaunch   Just quit; don't relaunch the app after stopping

set -euo pipefail

APP_NAME="${1:-}"
if [[ -z "$APP_NAME" ]]; then
  echo "Usage: graceful-relaunch.sh <AppName> [--port PORT] [--timeout SECS] [--no-relaunch]" >&2
  exit 1
fi
shift

PORT=""
TIMEOUT=5
RELAUNCH=true

while [[ $# -gt 0 ]]; do
  case "$1" in
    --port)   PORT="$2"; shift 2 ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    --no-relaunch) RELAUNCH=false; shift ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

# 1. Check if the app is running. If not, nothing to do.
PID=$(pgrep -x "$APP_NAME" 2>/dev/null || true)
if [[ -z "$PID" ]]; then
  echo "$APP_NAME is not running."
  exit 0
fi

echo "Sending graceful quit to $APP_NAME (PID $PID)..."

# 2. Send graceful quit via AppleScript (triggers NSApplication.terminate).
osascript -e "tell application \"$APP_NAME\" to quit" 2>/dev/null || true

# 3. Poll for process exit up to TIMEOUT seconds (0.5s intervals).
ELAPSED=0
while [[ $ELAPSED -lt $TIMEOUT ]]; do
  if ! pgrep -x "$APP_NAME" >/dev/null 2>&1; then
    echo "$APP_NAME quit gracefully."
    break
  fi
  sleep 0.5
  ELAPSED=$((ELAPSED + 1))
done

# 4. If still alive after timeout, force-kill.
if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
  echo "$APP_NAME did not quit within ${TIMEOUT}s — force-killing (PID $PID)."
  kill -9 "$PID" 2>/dev/null || true
  sleep 0.5
fi

# 5. If --port given, wait for the port to be free (up to 5 more seconds).
if [[ -n "$PORT" ]]; then
  echo "Waiting for port $PORT to be released..."
  PORT_WAIT=0
  while [[ $PORT_WAIT -lt 10 ]]; do
    if ! lsof -i :"$PORT" >/dev/null 2>&1; then
      echo "Port $PORT is free."
      break
    fi
    sleep 0.5
    PORT_WAIT=$((PORT_WAIT + 1))
  done
  if lsof -i :"$PORT" >/dev/null 2>&1; then
    echo "Warning: port $PORT still in use after waiting." >&2
  fi
fi

# 6. Relaunch unless --no-relaunch was passed.
if [[ "$RELAUNCH" == true ]]; then
  echo "Relaunching $APP_NAME..."
  open -a "$APP_NAME"
fi

exit 0
