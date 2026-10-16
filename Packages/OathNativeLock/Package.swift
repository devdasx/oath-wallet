// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OathNativeLock",
    platforms: [.iOS(.v17)],
    products: [.library(name: "OathNativeLock", targets: ["OathNativeLock"])],
    targets: [.target(name: "OathNativeLock")]
)
