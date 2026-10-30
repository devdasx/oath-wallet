// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "OathCloudBackup",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "OathCloudBackup", targets: ["OathCloudBackup"])],
    dependencies: [.package(path: "../OathDiagnostics")],
    targets: [.target(name: "OathCloudBackup", dependencies: ["OathDiagnostics"]),
              .testTarget(name: "OathCloudBackupTests", dependencies: ["OathCloudBackup"])],
    swiftLanguageModes: [.v6]
)
