// swift-tools-version:5.3
import PackageDescription

let package = Package(
    name: "WalletCore",
    platforms: [.iOS("15.0")],
    products: [
        .library(name: "WalletCore", targets: ["WalletCore"]),
        .library(name: "WalletCoreSwiftProtobuf", targets: ["WalletCoreSwiftProtobuf"])
    ],
    dependencies: [],
    targets: [
        .binaryTarget(
            name: "WalletCore",
            url: "https://github.com/devdasx/oath-wallet-security-review/releases/download/review-4.1.15-build100-progress19/WalletCore.xcframework.zip",
            checksum: "2f11aff95cbaaf0890e7584fbeefc6a4e747e83846a9393bed9d2dbe235a7fa6"
        ),
        .binaryTarget(
            name: "WalletCoreSwiftProtobuf",
            url: "https://github.com/devdasx/oath-wallet/releases/download/v5.0.0-build102/WalletCoreSwiftProtobuf-resources1.xcframework.zip",
            checksum: "149e3ceccd7bf6da09c6fd69cc57f6ee41e9dbc2045793a412fe8d06b833ec3d"
        )
    ]
)
