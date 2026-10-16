// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "OathMarketData",
    platforms: [.iOS(.v17), .macOS("15.5")],
    products: [.library(name: "OathMarketData", targets: ["OathMarketData"])],
    dependencies: [.package(path: "../OathDiagnostics"), .package(path: "../OathDatabase"), .package(path: "../OathAnkr"), .package(path: "../OathTokenImages")],
    targets: [
        .target(name: "OathMarketData", dependencies: ["OathDiagnostics", "OathDatabase", "OathAnkr", "OathTokenImages"]),
        .testTarget(name: "OathMarketDataTests", dependencies: ["OathMarketData"])
    ], swiftLanguageModes: [.v6]
)
