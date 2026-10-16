// swift-tools-version: 6.1
import PackageDescription
let package = Package(name:"OathSecp256k1",platforms:[.iOS(.v17),.macOS(.v14)],
    products:[.library(name:"OathSecp256k1",type:.dynamic,targets:["OathSecp256k1"])],
    dependencies:[.package(url:"https://github.com/21-DOT-DEV/swift-secp256k1",exact:"0.23.2")],
    targets:[.target(name:"OathSecp256k1",dependencies:[.product(name:"libsecp256k1",package:"swift-secp256k1")],
        linkerSettings:[.unsafeFlags(["-Xlinker","-unexported_symbol","-Xlinker","_secp256k1*"])])],swiftLanguageModes:[.v6])
