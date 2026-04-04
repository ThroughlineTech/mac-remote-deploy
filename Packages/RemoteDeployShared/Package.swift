// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "RemoteDeployShared",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(
            name: "RemoteDeployShared",
            targets: ["RemoteDeployShared"]
        ),
    ],
    targets: [
        .target(
            name: "RemoteDeployShared",
            path: "Sources/RemoteDeployShared"
        ),
    ]
)
