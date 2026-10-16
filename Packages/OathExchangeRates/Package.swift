// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "OathExchangeRates",
    platforms: [.iOS(.v17), .macOS("15.5")],
    products: [.library(name: "OathExchangeRates", targets: ["OathExchangeRates"])],
    dependencies: [.package(path: "../OathDiagnostics"), .package(path: "../OathDatabase")],
    targets: [
        .target(name: "OathExchangeRates", dependencies: ["OathDiagnostics", "OathDatabase"]),
        .testTarget(name: "OathExchangeRatesTests", dependencies: ["OathExchangeRates"])
    ],
    swiftLanguageModes: [.v6]
)
