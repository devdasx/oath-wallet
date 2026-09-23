import CryptoKit
import Foundation
import P256K
import WalletCore

/// Electrum's pre-BIP32 sequence. Retain the stretched master in Keychain so
/// every address does not repeat the 100,000-round seed stretch.
enum BitcoinElectrumOldDerivation {
    static func master(seed: String, publicKey: String) throws -> Data {
        guard !seed.isEmpty, seed.count <= 128, seed.count.isMultiple(of: 2),
              seed.utf8.allSatisfy({ "0123456789abcdefABCDEF".utf8.contains($0) }) else {
            throw BitcoinImportError.invalidFile
        }
        let input = Data(seed.utf8)
        var result = input
        for index in 0..<100_000 {
            if index.isMultiple(of: 1024) { try Task.checkCancellation() }
            result = Data(CryptoKit.SHA256.hash(data: result + input))
        }
        let scalar = try BitcoinElectrumFileCrypto.reducedScalar(result)
        guard let key = PrivateKey(data: scalar), let expected = Data(hexString: publicKey),
              key.getPublicKeySecp256k1(compressed: false).data.dropFirst() == expected else {
            throw BitcoinImportError.invalidFile
        }
        return scalar
    }

    static func privateKey(master: Data, branch: Int, index: Int) throws -> Data {
        guard (0...1).contains(branch), (0..<0x8000_0000).contains(index),
              let key = PrivateKey(data: master) else { throw BitcoinImportError.invalidKey }
        let mpk = key.getPublicKeySecp256k1(compressed: false).data.dropFirst()
        let digest = Hash.sha256SHA256(data: Data("\(index):\(branch):".utf8) + mpk)
        let tweak = try BitcoinElectrumFileCrypto.reducedScalar(digest, allowZero: true)
        let parent = try P256K.Signing.PrivateKey(dataRepresentation: master)
        return Data(try parent.add(Array(tweak)).dataRepresentation)
    }
}
