# Ticket Workflow Config

- Stack: Swift / Xcode (macOS host + iOS companion)
- Tickets directory: tickets/
- ID prefix: TKT-

## Commands
- Test: xcodebuild test -project RemoteDeploy.xcodeproj -scheme RemoteDeploy -destination 'platform=macOS'
- Build: xcodebuild build -project RemoteDeploy.xcodeproj -scheme RemoteDeploy -destination 'platform=macOS'
- Deploy: scripts/ship-deploy.sh
- Lint: (none)

### About the Deploy command

`scripts/ship-deploy.sh` is a dispatch wrapper (TKT-029) that inspects the
ticket's merge commit and only runs the full `scripts/build-release.sh`
pipeline when the ticket actually touched host code. Companion-only and
docs-only ships automatically skip the notarized release build — saving
Apple notarization quota on changes that can't possibly affect the host DMG.

The allowlist of host-relevant paths (RemoteDeploy/, Packages/, project.yml,
build-release.sh itself, Info.plist, and the xcodeproj) lives in the script.
If you need to force a build anyway (e.g., after editing the allowlist
itself), pass `--force`:

    scripts/ship-deploy.sh --force

For testing the decision without actually building:

    scripts/ship-deploy.sh --dry-run
    SHIP_DEPLOY_REF=<some-sha> scripts/ship-deploy.sh --dry-run

## Preview settings
- Preview mode: individual
- Preview port base: 3000

## Preview profiles

### macos  (atomic, default)
- Command: pkill -x RemoteDeploy 2>/dev/null; sleep 1; xcodegen generate && xcodebuild build -project RemoteDeploy.xcodeproj -scheme RemoteDeploy -destination 'platform=macOS' -configuration Debug -derivedDataPath /tmp/RemoteDeployPreview && open /tmp/RemoteDeployPreview/Build/Products/Debug/RemoteDeploy.app
- Port offset: 0
- Ready when: command-exit
- Sequential: true

## Key source locations
- RemoteDeploy/ — macOS host app (SwiftUI, NIO server, Bonjour advertiser)
- RemoteDeployCompanion/ — iOS companion app (SwiftUI, Bonjour browser)
- Packages/RemoteDeployShared/ — shared Swift package
- RemoteDeployTests/ — host unit tests
- RemoteDeployIntegrationTests/ — HTTP server integration tests
- RemoteDeployCompanionUITests/ — companion UI tests
- scripts/ — build-release.sh, capture-screenshots.sh, test-pairing-e2e.sh
- project.yml — XcodeGen project spec

## Context docs
- README.md
