// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "LiquidGlassBubble",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "LiquidGlassBubble",
            targets: ["LiquidGlassBubble"]
        )
    ],
    targets: [
        .target(name: "LiquidGlassBubble"),
        .testTarget(
            name: "LiquidGlassBubbleTests",
            dependencies: ["LiquidGlassBubble"]
        )
    ]
)
