// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "OathWalletHandoff", platforms: [.iOS(.v16), .macOS(.v13)],
    products: [.library(name: "OathWalletHandoff", targets: ["OathWalletHandoff"])],
    targets: [.target(name: "OathWalletHandoff"), .testTarget(name: "OathWalletHandoffTests", dependencies: ["OathWalletHandoff"])])
