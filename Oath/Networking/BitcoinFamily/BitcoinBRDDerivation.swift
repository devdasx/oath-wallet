import Foundation
import WalletCore

/// Breadwallet uses one BIP32 account m/0' for both script encodings.
/// The public root is serialized as xpub for both; it is not a BIP84 zpub account.
enum BitcoinBRDDerivation {
    static func accountDescriptor(
        wallet: HDWallet,
        type: BitcoinHDAddressType
    ) throws -> BitcoinHDAccountDescriptor {
        guard type.isBRD else { throw BitcoinHDDerivationError.invalidChild }
        let root = try ElectrumBIP32Node.master(seed: wallet.seed)
        let account = try root.derived(at: 0x8000_0000)
        // Wallet Core remains authoritative for every private account identity.
        guard let canonicalKey = wallet.getKey(coin: .bitcoin, derivationPath: "m/0'"),
              canonicalKey.getPublicKeySecp256k1(compressed: true).data == account.publicKey else {
            throw BitcoinHDDerivationError.invalidExtendedPublicKey
        }
        let descriptor = BitcoinHDAccountDescriptor(
            addressType: type, accountIndex: 0, accountPath: "m/0'",
            extendedPublicKey: account.serializedPublicKey(version: 0x0488_b21e)
        )
        for branch in [BitcoinHDAddressBranch.external, .change] {
            let publicChild = try deriveAddress(descriptor: descriptor, branch: branch, index: 0)
            let privateChild = try BitcoinHDDerivationService().deriveAddress(
                wallet: wallet, addressType: type, branch: branch, index: 0
            )
            guard publicChild == privateChild else {
                throw BitcoinHDDerivationError.invalidExtendedPublicKey
            }
        }
        return descriptor
    }

    static func deriveAddress(
        descriptor: BitcoinHDAccountDescriptor,
        branch: BitcoinHDAddressBranch,
        index: Int
    ) throws -> BitcoinHDDerivedAddress {
        guard descriptor.addressType.isBRD,
              descriptor.accountIndex == 0,
              descriptor.accountPath == "m/0'",
              index >= 0, index < 0x8000_0000,
              let payload = Base58.decode(string: descriptor.extendedPublicKey),
              payload.count == 78,
              payload.prefix(4).elementsEqual([0x04, 0x88, 0xb2, 0x1e]) else {
            throw BitcoinHDDerivationError.invalidExtendedPublicKey
        }
        let account = try ElectrumBIP32Node.extendedPublicKey(descriptor.extendedPublicKey)
        guard account.depth == 1, account.childNumber == 0x8000_0000 else {
            throw BitcoinHDDerivationError.invalidExtendedPublicKey
        }
        let child = try account.derived(at: UInt32(branch.rawValue)).derived(at: UInt32(index))
        guard let publicKey = PublicKey(data: child.publicKey, type: .secp256k1) else {
            throw BitcoinHDDerivationError.invalidChild
        }
        return try BitcoinHDDerivationService().derivedAddress(
            addressType: descriptor.addressType, branch: branch, index: index, publicKey: publicKey
        )
    }
}

extension BitcoinHDAddressType {
    /// A path alone cannot distinguish BRD Legacy, BRD SegWit and Electrum SegWit.
    static func location(
        for path: String,
        addressType: BitcoinHDAddressType
    ) -> BitcoinHDAddressLocation? {
        let components = path.split(separator: "/")
        guard components.count >= 3,
              let branchValue = Int(components[components.count - 2]),
              let branch = BitcoinHDAddressBranch(rawValue: branchValue),
              let index = Int(components[components.count - 1]),
              index >= 0, index < 0x8000_0000,
              BitcoinHDChildKeyCache.validDerivationPath(
                  path, addressType: addressType, branch: branch, index: index
              ) else { return nil }
        return BitcoinHDAddressLocation(addressType: addressType, branch: branch, index: index)
    }

    static func location(
        for path: String,
        address: String,
        credential: WalletRecoveryCredential
    ) -> BitcoinHDAddressLocation? {
        if let kind = credential.electrumKind {
            return location(for: path, addressType: kind.addressType)
        }
        if path.hasPrefix("m/0'/") {
            let type: Self
            if address.hasPrefix("1") { type = .brdLegacy }
            else if address.lowercased().hasPrefix("bc1q") { type = .brdSegwit }
            else { return nil }
            return location(for: path, addressType: type)
        }
        return location(for: path)
    }
}
