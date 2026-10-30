// swift-tools-version:5.3
import PackageDescription

let package = Package(
    name: "WalletCore",
    platforms: [.iOS(.v13)],
    products: [
        .library(name: "WalletCore", targets: ["WalletCore"]),
        .library(name: "WalletCoreSwiftProtobuf", targets: ["WalletCoreSwiftProtobuf"])
    ],
    dependencies: [],
    targets: [
        .binaryTarget(
            name: "WalletCore",
            url: "https://github.com/trustwallet/wallet-core/releases/download/4.8.4/WalletCore.xcframework.zip",
            checksum: "3d70d9d988c253e13e65c6fa9947f5ed7c9e31ca55ff719d055646f11dd0287a"
        ),
        .binaryTarget(
            name: "WalletCoreSwiftProtobuf",
            url: "https://github.com/trustwallet/wallet-core/releases/download/4.8.4/WalletCoreSwiftProtobuf.xcframework.zip",
            checksum: "387fa8e0aad9470ce50efc17d3b9e736a747ded225b9e190385ad13636a0d300"
        )
    ]
)
