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
            url: "https://github.com/OathWallet/oath-wallet-security-review/releases/download/walletcore-4.8.4-swift-paths-1/WalletCore.xcframework.zip",
            checksum: "f077f7c36df0d0ed5131ec70d335a5d5e9a09143b77a734c4890fec2c2bbe4bd"
        ),
        .binaryTarget(
            name: "WalletCoreSwiftProtobuf",
            url: "https://github.com/OathWallet/oath-wallet-security-review/releases/download/walletcore-4.8.4-swift-paths-1/WalletCoreSwiftProtobuf-1.29.0-packaging.xcframework.zip",
            checksum: "e628aaf3cca1fa351971ab2b3bced283f8422ea524d15014c449fd1def6f079c"
        )
    ]
)
