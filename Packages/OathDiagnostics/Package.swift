// swift-tools-version: 6.1
import PackageDescription
let package = Package(name: "OathDiagnostics", platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "OathDiagnostics", type: .dynamic, targets: ["OathDiagnostics"])],
    targets: [.target(name: "OathDiagnostics", resources: [.process("Resources")]),
              .testTarget(name: "OathDiagnosticsTests", dependencies: ["OathDiagnostics"])],
    swiftLanguageModes: [.v6])
