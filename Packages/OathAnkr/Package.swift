// swift-tools-version: 6.1
import PackageDescription
let package = Package(name: "OathAnkr", platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "OathAnkr", targets: ["OathAnkr"])],
    dependencies: [.package(path: "../OathDiagnostics"), .package(path: "../OathTokenImages"),
                   .package(path: "../OathSecp256k1"), .package(url: "https://github.com/Soneso/stellar-ios-mac-sdk.git", exact: "3.12.0")],
    targets: [.target(name: "OathAnkr", dependencies: ["OathDiagnostics", .product(name: "OathArtworkSource", package: "OathTokenImages"), .product(name: "OathTokenImages", package: "OathTokenImages"),
                                                     "OathSecp256k1", .product(name: "stellarsdk", package: "stellar-ios-mac-sdk")], resources: [.copy("Resources/XrplCodec.js"), .copy("Resources/NearMultisig2.wasm"), .copy("Resources/StoryVerifiedCatalog.json"), .copy("Resources/ArcCatalog.json"), .copy("Resources/TonWalletV4R2.b64"), .copy("Resources/TonMultisigV1.b64"), .copy("Resources/TokenDiscoverySeed.json"), .copy("Resources/TokenDiscoveryDetails.json")]), .testTarget(name: "OathAnkrTests", dependencies: ["OathAnkr"], resources: [.copy("Fixtures")])],
    swiftLanguageModes: [.v6])
