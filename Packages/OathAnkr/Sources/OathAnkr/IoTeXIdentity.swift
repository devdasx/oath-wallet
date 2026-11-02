import Foundation
import OathArtworkSource

/// Both encodings contain the same 20-byte account, with no chain inference
/// from the key itself. Oath derives its EVM account at m/44'/60'/0'/0/0.
public enum IoTeXIdentity {
    public static func ethereum(_ value: String) throws -> String {
        if value.hasPrefix("0x") { return try IndexedEVMIdentity.address(value) }
        guard let address = IoTeXNativeAddress.ethereum(value) else { throw AnkrError.invalidAddress }
        return address
    }
    public static func native(_ ethereum: String) throws -> String {
        ThorchainSendCrypto.bech32(try TronIdentity.hex(IndexedEVMIdentity.address(ethereum)), prefix: "io")
    }
}
