// swift-tools-version: 6.1
import PackageDescription
let package = Package(name: "OathAnkr", platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "OathAnkr", targets: ["OathAnkr"])],
    dependencies: [.package(path: "../OathDiagnostics"), .package(path: "../OathTokenImages"),
                   .package(path: "../OathSecp256k1")],
    targets: [.target(name: "OathAnkr", dependencies: ["OathDiagnostics", .product(name: "OathArtworkSource", package: "OathTokenImages"),
                                                     "OathSecp256k1"], resources: [.copy("Resources/ArcCatalog.json"), .copy("Resources/TonWalletV4R2.b64")]), .testTarget(name: "OathAnkrTests", dependencies: ["OathAnkr"], resources: [.copy("Fixtures")])],
    swiftLanguageModes: [.v6])
