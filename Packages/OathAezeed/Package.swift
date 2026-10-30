// swift-tools-version: 6.1
import PackageDescription
let package = Package(name: "OathAezeed", platforms: [.iOS(.v17), .macOS("15.5")],
    products: [.library(name: "OathAezeed", targets: ["OathAezeed"])],
    targets: [
        .binaryTarget(name: "OathAezeedCore", path: "OathAezeedCore.xcframework"),
        .target(name: "OathAezeed", dependencies: ["OathAezeedCore"], resources: [.process("Resources")],
                linkerSettings: [.linkedLibrary("resolv")]),
        .testTarget(name: "OathAezeedTests", dependencies: ["OathAezeed"], resources: [.process("Fixtures")])
    ], swiftLanguageModes: [.v6])
