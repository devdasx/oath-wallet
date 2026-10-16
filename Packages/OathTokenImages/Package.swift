// swift-tools-version: 6.1
import PackageDescription

let package = Package(name: "OathTokenImages", platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "OathTokenImages", targets: ["OathTokenImages"]),
               .library(name: "OathArtworkSource", targets: ["OathArtworkSource"])],
    dependencies: [.package(path: "../OathDiagnostics"), .package(url: "https://github.com/swhitty/SwiftDraw.git", exact: "0.29.0")],
    targets: [
        .target(name: "OathArtworkSource"),
        .target(name: "OathTokenImages", dependencies: ["OathDiagnostics", "SwiftDraw", "OathArtworkSource"]),
        .testTarget(name: "OathTokenImagesTests", dependencies: ["OathTokenImages"], resources: [.copy("Fixtures")])
    ], swiftLanguageModes: [.v6])
