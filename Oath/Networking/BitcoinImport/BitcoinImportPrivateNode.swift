import CryptoKit
import Foundation
import P256K
import WalletCore

/// BIP32 node used by imported descriptors. Serialized only inside Keychain material.
struct BitcoinImportPrivateNode: Codable, Equatable, Sendable {
    let privateKey: Data
    let chainCode: Data
    let depth: UInt8
    let parentFingerprint: Data
    let childNumber: UInt32

    init(encoded: String) throws {
        guard let payload = Base58.decode(string: encoded), payload.count == 78 else {
            throw BitcoinImportError.invalidKey
        }
        let version = Self.integer(Data(payload.prefix(4)))
        guard [UInt32(0x0488ade4), 0x049d7878, 0x04b2430c].contains(version) else {
            throw BitcoinImportError.unsupportedNetwork
        }
        guard payload[45] == 0 else { throw BitcoinImportError.privateKeyRequired }
        self.init(privateKey: Data(payload[46..<78]), chainCode: Data(payload[13..<45]),
                  depth: payload[4], parentFingerprint: Data(payload[5..<9]),
                  childNumber: Self.integer(Data(payload[9..<13])))
        try validate()
    }

    init(privateKey: Data, chainCode: Data, depth: UInt8, parentFingerprint: Data, childNumber: UInt32) {
        self.privateKey = privateKey
        self.chainCode = chainCode
        self.depth = depth
        self.parentFingerprint = parentFingerprint
        self.childNumber = childNumber
    }

    func validate() throws {
        guard chainCode.count == 32, parentFingerprint.count == 4,
              PrivateKey.isValid(data: privateKey, curve: .secp256k1),
              depth != 0 || (childNumber == 0 && parentFingerprint.allSatisfy { $0 == 0 }) else {
            throw BitcoinImportError.invalidKey
        }
    }

    var publicKey: Data {
        get throws {
            try validate()
            guard let key = PrivateKey(data: privateKey) else { throw BitcoinImportError.invalidKey }
            return key.getPublicKeySecp256k1(compressed: true).data
        }
    }

    func derived(at index: UInt32) throws -> Self {
        try validate()
        guard depth < 255 else { throw BitcoinImportError.invalidDescriptor }
        let publicKey = try self.publicKey
        var input = index & 0x8000_0000 != 0 ? Data([0]) + privateKey : publicKey
        input.append(Self.bytes(index))
        let digest = Data(HMAC<SHA512>.authenticationCode(for: input, using: SymmetricKey(data: chainCode)))
        let tweak = Data(digest.prefix(32))
        guard tweak.allSatisfy({ $0 == 0 }) || PrivateKey.isValid(data: tweak, curve: .secp256k1) else { throw BitcoinImportError.invalidKey }
        let parent = try P256K.Signing.PrivateKey(dataRepresentation: privateKey)
        let child = try parent.add(Array(tweak))
        let result = Self(privateKey: Data(child.dataRepresentation), chainCode: Data(digest.suffix(32)),
                          depth: depth + 1, parentFingerprint: Data(Hash.sha256RIPEMD(data: publicKey).prefix(4)),
                          childNumber: index)
        try result.validate()
        return result
    }

    func serialized(publicOnly: Bool = false) throws -> String {
        try validate()
        var data = Self.bytes(publicOnly ? 0x0488b21e : 0x0488ade4)
        data.append(depth)
        data.append(parentFingerprint)
        data.append(Self.bytes(childNumber))
        data.append(chainCode)
        data.append(publicOnly ? try publicKey : Data([0]) + privateKey)
        return Base58.encode(data: data)
    }

    static func integer(_ bytes: Data) -> UInt32 { bytes.reduce(0) { ($0 << 8) | UInt32($1) } }
    static func bytes(_ value: UInt32) -> Data {
        Data([UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16),
              UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)])
    }
}
