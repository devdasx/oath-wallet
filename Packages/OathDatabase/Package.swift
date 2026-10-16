// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "OathDatabase",
    platforms: [.iOS(.v17), .macOS("15.5")],
    products: [.library(name: "OathDatabase", targets: ["OathDatabase"])],
    dependencies: [.package(path: "../OathDiagnostics"), .package(url: "https://github.com/groue/GRDB.swift", exact: "7.11.1"), .package(path: "../OathBitcoin"), .package(path: "../OathAnkr"), .package(path: "../OathTokenImages")],
    targets: [
        .target(name: "OathDatabase", dependencies: ["OathDiagnostics", .product(name: "GRDB", package: "GRDB.swift"), "OathBitcoin", "OathAnkr", .product(name: "OathArtworkSource", package: "OathTokenImages")]),
        .testTarget(name: "OathDatabaseTests", dependencies: ["OathDatabase"])
    ],
    swiftLanguageModes: [.v6]
)
