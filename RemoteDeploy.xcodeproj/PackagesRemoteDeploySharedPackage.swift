// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "RemoteDeployShared",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(
            name: "RemoteDeployShared",
            targets: ["RemoteDeployShared"]
        ),
    ],
    targets: [
        .target(
            name: "RemoteDeployShared"
        ),
    ]
)
