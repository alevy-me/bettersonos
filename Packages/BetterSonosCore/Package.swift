// swift-tools-version: 5.10
// Shared models, networking and stores for the iOS and watchOS apps.
// Tools 5.10 keeps the Swift 5 language mode, matching the app targets.

import PackageDescription

let package = Package(
    name: "BetterSonosCore",
    platforms: [
        .iOS(.v17),
        .watchOS(.v10),
    ],
    products: [
        .library(name: "BetterSonosCore", targets: ["BetterSonosCore"]),
    ],
    targets: [
        .target(name: "BetterSonosCore"),
    ]
)
