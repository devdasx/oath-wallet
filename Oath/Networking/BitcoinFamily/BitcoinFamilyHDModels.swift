import CryptoKit
import Foundation
import WalletCore

/// DOGE, LTC and BCH use independent account roots and discovery state.
/// Bitcoin keeps its existing derivation families and gap limit of twenty.
extension BitcoinFamilyChain {
    var supportsFamilyHD: Bool { self != .bitcoin }
    var familyHDTypes: [BitcoinHDAddressType] {
        switch self {
        case .litecoin: [.bip44, .bip49, .bip84]
        case .bitcoinCash, .dogecoin: [.bip44]
        case .bitcoin: []
        }
    }
    var familyHDDefaultType: BitcoinHDAddressType { self == .litecoin ? .bip84 : .bip44 }
    var familyHDCoinType: UInt32 { coin.rawValue }
}

struct BitcoinFamilyHDDescriptor: Sendable, Equatable {
    let chain: BitcoinFamilyChain
    let type: BitcoinHDAddressType
    let extendedPublicKey: String
    var accountPath: String { "m/\(type.purposeNumber)'/\(chain.familyHDCoinType)'/0'" }
    func path(branch: BitcoinHDAddressBranch, index: Int) -> String {
        "\(accountPath)/\(branch.rawValue)/\(index)"
    }
}

enum BitcoinFamilyHDDerivation {
    static let gapLimit = 5

    static func descriptors(credential: WalletRecoveryCredential, chain: BitcoinFamilyChain) throws
        -> [BitcoinFamilyHDDescriptor] {
        guard chain.supportsFamilyHD, credential.electrumKind == nil,
              let wallet = credential.makeHDWallet() else { throw BitcoinHDDerivationError.invalidWallet }
        return try chain.familyHDTypes.map { type in
            let extended = wallet.getExtendedPublicKeyAccount(purpose: type.purpose, coin: chain.coin,
                derivation: .default, version: .xpub, account: 0)
            guard !extended.isEmpty else { throw BitcoinHDDerivationError.invalidExtendedPublicKey }
            let descriptor = BitcoinFamilyHDDescriptor(chain: chain, type: type, extendedPublicKey: extended)
            let publicChild = try address(descriptor: descriptor, branch: .external, index: 0)
            guard let privateKey = wallet.getKey(coin: chain.coin, derivationPath: publicChild.derivationPath),
                  privateKey.getPublicKeySecp256k1(compressed: true).data == publicChild.publicKey
            else { throw BitcoinHDDerivationError.invalidExtendedPublicKey }
            return descriptor
        }
    }

    static func address(descriptor: BitcoinFamilyHDDescriptor, branch: BitcoinHDAddressBranch, index: Int) throws
        -> BitcoinHDDerivedAddress {
        guard descriptor.chain.familyHDTypes.contains(descriptor.type), (0..<0x8000_0000).contains(index),
              let key = HDWallet.getPublicKeyFromExtended(extended: descriptor.extendedPublicKey,
                coin: descriptor.chain.coin, derivationPath: descriptor.path(branch: branch, index: index))
        else { throw BitcoinHDDerivationError.invalidChild }
        return try address(chain: descriptor.chain, type: descriptor.type, branch: branch, index: index, publicKey: key)
    }

    static func address(chain: BitcoinFamilyChain, type: BitcoinHDAddressType,
                        branch: BitcoinHDAddressBranch, index: Int, publicKey: PublicKey) throws -> BitcoinHDDerivedAddress {
        guard chain.familyHDTypes.contains(type), (0..<0x8000_0000).contains(index) else {
            throw BitcoinHDDerivationError.invalidChild
        }
        let address: String
        switch (chain, type) {
        case (.litecoin, .bip84):
            address = SegwitAddress(hrp: .litecoin, publicKey: publicKey).description
        case (.litecoin, .bip49):
            let redeem = BitcoinScript.buildPayToWitnessPubkeyHash(hash: publicKey.bitcoinKeyHash).data
            address = Base58.encode(data: Data([0x32]) + Hash.sha256RIPEMD(data: redeem))
        case (.litecoin, .bip44):
            address = Base58.encode(data: Data([0x30]) + publicKey.bitcoinKeyHash)
        case (.dogecoin, .bip44):
            address = Base58.encode(data: Data([0x1e]) + publicKey.bitcoinKeyHash)
        case (.bitcoinCash, .bip44):
            guard let cash = BitcoinCashCashAddrEncoder.p2pkh(publicKeyHash: publicKey.bitcoinKeyHash) else {
                throw BitcoinHDDerivationError.invalidAddress
            }
            address = cash
        default: throw BitcoinHDDerivationError.invalidAddress
        }
        let script = BitcoinScript.lockScriptForAddress(address: address, coin: chain.coin).data
        guard chain.coin.validate(address: address), !script.isEmpty else { throw BitcoinHDDerivationError.invalidAddress }
        return BitcoinHDDerivedAddress(addressType: type, branch: branch, index: index,
            derivationPath: "m/\(type.purposeNumber)'/\(chain.familyHDCoinType)'/0'/\(branch.rawValue)/\(index)",
            address: address, publicKey: publicKey.data, scriptPubKey: script,
            scriptHash: Data(SHA256.hash(data: script)).reversed().map { String(format: "%02x", $0) }.joined())
    }

    static func privateKey(credential: WalletRecoveryCredential, chain: BitcoinFamilyChain,
                           owner: BitcoinHDDerivedAddress) throws -> PrivateKey {
        guard credential.electrumKind == nil, let wallet = credential.makeHDWallet(),
              chain.familyHDTypes.contains(owner.addressType),
              let key = wallet.getKey(coin: chain.coin, derivationPath: owner.derivationPath) else {
            throw BitcoinHDDerivationError.invalidChild
        }
        let derived = try address(chain: chain, type: owner.addressType, branch: owner.branch, index: owner.index,
                                  publicKey: key.getPublicKeySecp256k1(compressed: true))
        guard derived == owner else { throw BitcoinHDDerivationError.invalidChild }
        return key
    }
}
