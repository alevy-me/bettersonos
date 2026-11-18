// swift-tools-version: 6.2
// Shared models, networking and stores for the iOS and watchOS apps.

import PackageDescription

let package = Package(
    name: "BetterSonosCore",
    platforms: [
        .iOS(.v26),
        .watchOS(.v26),
    ],
    products: [
        .library(name: "BetterSonosCore", targets: ["BetterSonosCore"]),
    ],
    targets: [
        .target(name: "BetterSonosCore"),
    ],
    // Swift 5 language mode, matching the app targets.
    swiftLanguageModes: [.v5]
)
