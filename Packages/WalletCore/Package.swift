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
            url: "https://github.com/devdasx/oath-wallet-security-review/releases/download/review-4.1.15-build100-progress19/WalletCoreSwiftProtobuf.xcframework.zip",
            checksum: "c63dbf567c42d83c4939ca06c85249ce17fb3d7762fba778971c35f160098f9f"
        )
    ]
)
