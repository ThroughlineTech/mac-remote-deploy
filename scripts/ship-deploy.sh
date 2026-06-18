#!/bin/bash
# ship-deploy.sh — dispatches to build-release.sh only when the most recent
# commit (HEAD, typically the ticket's --no-ff merge commit) touched host code.
# Saves Apple notarization quota on companion-only and docs-only ships.
# TKT-029.
#
# Usage:
#   scripts/ship-deploy.sh               — auto-detect whether to build HEAD
#   scripts/ship-deploy.sh --force       — always build (ignore the gate)
#   scripts/ship-deploy.sh --dry-run     — report the decision without building
#   SHIP_DEPLOY_REF=<sha> scripts/ship-deploy.sh --dry-run
#                                         — test the decision against an
#                                           arbitrary commit (for CI / testing)
#
# Wired into .claude/ticket-config.md as the Deploy command so /ticket-ship
# automatically makes the right call on each ship.
#
# Allowlist of host-relevant git pathspec patterns below. If any file touched
# by the ref matches one of these, we run the full release build. Otherwise
# we skip the build (but still exit 0 — the ship itself is not a failure).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REF="${SHIP_DEPLOY_REF:-HEAD}"
DRY_RUN=false
FORCE=false

for arg in "$@"; do
    case "$arg" in
        --force)   FORCE=true ;;
        --dry-run) DRY_RUN=true ;;
        *)         echo "ship-deploy: unknown argument: $arg" >&2; exit 2 ;;
    esac
done

# --force bypasses the gate and always runs the release build.
if $FORCE; then
    echo "ship-deploy: --force requested, running full release build"
    if $DRY_RUN; then
        echo "ship-deploy: (dry run — not actually building)"
        exit 0
    fi
    exec "$SCRIPT_DIR/build-release.sh"
fi

# List files touched by the current ref (HEAD by default). For a ship,
# HEAD is the merge commit created by /ticket-ship phase 3
# (`git merge --no-ff`), which carries the full ticket diff regardless
# of how many underlying commits were on the feature branch.
#
# --pretty=format: gives an empty line we filter out; -m makes merge
# commits behave like diffs against their first parent (main), which is
# exactly what we want for a --no-ff merge.
changed=$(git show --name-only --pretty=format: -m --first-parent "$REF" 2>/dev/null | grep -v '^$' || true)

if [[ -z "$changed" ]]; then
    echo "ship-deploy: no files changed in $REF (unexpected), running full release build"
    if $DRY_RUN; then
        echo "ship-deploy: (dry run — not actually building)"
        exit 0
    fi
    exec "$SCRIPT_DIR/build-release.sh"
fi

# Allowlist of host-relevant path patterns. Any match = we need a new DMG.
# Patterns are extended regex, anchored to the start of the path.
host_patterns=(
    '^RemoteDeploy/'
    '^RemoteDeployServer/'
    '^Packages/'
    '^RemoteDeploy\.xcodeproj/'
    '^project\.yml$'
    '^scripts/build-release\.sh$'
    'Info\.plist$'
)

needs_deploy=false
matched_file=""
while IFS= read -r file; do
    [[ -z "$file" ]] && continue
    for pat in "${host_patterns[@]}"; do
        if echo "$file" | grep -qE "$pat"; then
            needs_deploy=true
            matched_file="$file"
            break 2
        fi
    done
done <<< "$changed"

if $needs_deploy; then
    echo "ship-deploy: host code changed (first match: $matched_file), running full release build"
    if $DRY_RUN; then
        echo "ship-deploy: (dry run — not actually building)"
        exit 0
    fi
    exec "$SCRIPT_DIR/build-release.sh"
else
    echo "ship-deploy: no host code changes in $REF, skipping release build"
    echo "  (pass --force to build anyway)"
    echo "  inspected files:"
    while IFS= read -r file; do
        [[ -z "$file" ]] || echo "    $file"
    done <<< "$changed"
    exit 0
fi
