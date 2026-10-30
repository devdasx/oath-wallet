// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OathNativeRefresh",
    platforms: [.iOS(.v17)],
    products: [.library(name: "OathNativeRefresh", targets: ["OathNativeRefresh"])],
    dependencies: [.package(path: "../OathDiagnostics")],
    targets: [.target(name: "OathNativeRefresh", dependencies: ["OathDiagnostics"])]
)
