// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "OathDatabase",
    platforms: [.iOS(.v17), .macOS("15.5")],
    products: [.library(name: "OathDatabase", targets: ["OathDatabase"])],
    // Upstream #1884 fixes SQLite WAL snapshot ordering: 7.11.1 can crash in
    // Debug and miss a committed observation value in Release. Pin the merged
    // repair until it is included in a tagged release; never follow a branch.
    dependencies: [.package(path: "../OathDiagnostics"), .package(url: "https://github.com/groue/GRDB.swift", revision: "533286eab041d826ed4a46c56b213fa3d2cebb7a"), .package(path: "../OathBitcoin"), .package(path: "../OathAnkr"), .package(path: "../OathTokenImages")],
    targets: [
        .target(name: "OathDatabase", dependencies: ["OathDiagnostics", .product(name: "GRDB", package: "GRDB.swift"), "OathBitcoin", "OathAnkr", .product(name: "OathArtworkSource", package: "OathTokenImages")]),
        .testTarget(name: "OathDatabaseTests", dependencies: ["OathDatabase"])
    ],
    swiftLanguageModes: [.v6]
)
