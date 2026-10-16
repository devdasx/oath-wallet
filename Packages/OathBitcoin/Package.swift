// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "OathBitcoin",
    platforms: [.iOS(.v17), .macOS("15.5")],
    products: [.library(name: "OathBitcoin", type: .dynamic, targets: ["OathBitcoin"])],
    dependencies: [.package(path: "../OathDiagnostics"), 
        .package(url: "https://github.com/bitcoindevkit/bdk-swift", exact: "3.1.1"),
        .package(path: "../OathSecp256k1")
    ],
    targets: [
        // BDK bundles its own SQLite. Keep it private to this dynamic image;
        // GRDB must bind exclusively to Apple's SQLite (including snapshots).
        .target(name: "OathBitcoin", dependencies: ["OathDiagnostics", 
            .product(name: "BitcoinDevKit", package: "bdk-swift"),
            "OathSecp256k1"
        ], linkerSettings: [.unsafeFlags(["-Xlinker", "-unexported_symbol", "-Xlinker", "_sqlite3*",
                                         "-Xlinker", "-unexported_symbol", "-Xlinker", "_secp256k1*"])]),
        .testTarget(name: "OathBitcoinTests", dependencies: ["OathBitcoin"], resources: [.process("Fixtures")])
    ],
    swiftLanguageModes: [.v6]
)
