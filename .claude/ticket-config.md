# Ticket Workflow Config

- Stack: Swift / Xcode (macOS host + iOS companion)
- Tickets directory: tickets/
- ID prefix: TKT-

## Commands
- Test: xcodebuild test -project RemoteDeploy.xcodeproj -scheme RemoteDeploy -destination 'platform=macOS'
- Build: xcodebuild build -project RemoteDeploy.xcodeproj -scheme RemoteDeploy -destination 'platform=macOS'
- Deploy: scripts/build-release.sh
- Lint: (none)

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
