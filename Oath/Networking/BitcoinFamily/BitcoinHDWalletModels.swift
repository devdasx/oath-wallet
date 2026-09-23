import CryptoKit
import Foundation
import WalletCore

enum BitcoinHDAddressType: String, CaseIterable, Codable, Sendable {
    case bip44
    case bip49
    case bip84
    case bip86
    case brdLegacy
    case brdSegwit

    static let standardTypes: [Self] = [.bip44, .bip49, .bip84, .bip86]

    var isBRD: Bool { self == .brdLegacy || self == .brdSegwit }

    var purposeNumber: UInt32 {
        switch self {
        case .bip44: 44
        case .bip49: 49
        case .bip84: 84
        case .bip86: 86
        case .brdLegacy, .brdSegwit: 0
        }
    }

    var purpose: Purpose {
        switch self {
        case .bip44, .brdLegacy: .bip44
        case .bip49: .bip49
        case .bip84, .brdSegwit: .bip84
        case .bip86: .bip86
        }
    }

    var extendedPublicVersion: HDVersion {
        switch self {
        case .bip44, .bip86, .brdLegacy, .brdSegwit: .xpub
        case .bip49: .ypub
        case .bip84: .zpub
        }
    }

    var accountPath: String {
        isBRD ? "m/0'" : "m/\(purposeNumber)'/0'/0'"
    }

    var format: PrivateKeyImportFormat {
        switch self {
        case .bip44, .brdLegacy: .extendedLegacy
        case .bip49: .extendedNestedSegwit
        case .bip84, .bip86, .brdSegwit: .extendedNativeSegwit
        }
    }

    var localizationKey: String {
        "receive.bitcoin.address_type.\(rawValue)"
    }

    var localizedName: String {
        WalletLocalization.string(localizationKey)
    }

    static func location(
        for derivationPath: String
    ) -> BitcoinHDAddressLocation? {
        for addressType in standardTypes {
            let prefix = "\(addressType.accountPath)/"
            guard derivationPath.hasPrefix(prefix) else { continue }
            let suffix = derivationPath.dropFirst(prefix.count)
            let components = suffix.split(separator: "/")
            guard components.count == 2,
                  let branchValue = Int(components[0]),
                  let branch = BitcoinHDAddressBranch(
                      rawValue: branchValue
                  ),
                  let index = Int(components[1]),
                  index >= 0,
                  index < 0x8000_0000 else {
                return nil
            }
            return BitcoinHDAddressLocation(
                addressType: addressType,
                branch: branch,
                index: index
            )
        }
        let electrumPaths: [(String, BitcoinHDAddressType)] = [
            (ElectrumSeedKind.segwit.accountPath, .bip84),
            (ElectrumSeedKind.standard.accountPath, .bip44),
        ]
        for (accountPath, addressType) in electrumPaths {
            let prefix = "\(accountPath)/"
            guard derivationPath.hasPrefix(prefix) else { continue }
            let components = derivationPath.dropFirst(prefix.count)
                .split(separator: "/")
            guard components.count == 2,
                  let branchValue = Int(components[0]),
                  let branch = BitcoinHDAddressBranch(rawValue: branchValue),
                  let index = Int(components[1]),
                  index >= 0,
                  index < 0x8000_0000 else {
                return nil
            }
            return BitcoinHDAddressLocation(
                addressType: addressType,
                branch: branch,
                index: index
            )
        }
        return nil
    }
}

enum BitcoinHDAddressBranch: Int, Codable, Sendable {
    case external = 0
    case change = 1
}

struct BitcoinHDAddressLocation: Hashable, Sendable {
    let addressType: BitcoinHDAddressType
    let branch: BitcoinHDAddressBranch
    let index: Int
}

struct BitcoinHDAccountDescriptor: Hashable, Sendable {
    let addressType: BitcoinHDAddressType
    let accountIndex: Int
    let accountPath: String
    let extendedPublicKey: String
}

struct BitcoinHDDerivedAddress: Codable, Hashable, Sendable {
    let addressType: BitcoinHDAddressType
    let branch: BitcoinHDAddressBranch
    let index: Int
    let derivationPath: String
    let address: String
    let publicKey: Data
    let scriptPubKey: Data
    let scriptHash: String
}

struct BitcoinHDAddressState: Hashable, Sendable {
    let derived: BitcoinHDDerivedAddress
    let isUsed: Bool
    let isReserved: Bool
    let confirmedBalanceAtomic: BitcoinFamilyAtomicInteger
    let unconfirmedBalanceAtomic: BitcoinFamilyAtomicInteger

    var balanceAtomic: BitcoinFamilyAtomicInteger {
        confirmedBalanceAtomic.adding(unconfirmedBalanceAtomic)
    }
}

struct BitcoinHDChildKeyCacheEntry: Codable, Hashable, Sendable {
    let index: Int
    let derivationPath: String
    let address: String
    let wif: String
}

struct BitcoinHDChildKeyCache: Codable, Hashable, Sendable {
    static let currentVersion = 1

    let version: Int
    let walletID: String
    let addressType: BitcoinHDAddressType
    let branch: BitcoinHDAddressBranch
    let entries: [BitcoinHDChildKeyCacheEntry]

    var highestCachedIndex: Int? {
        entries.last?.index
    }

    func validated() throws -> Self {
        guard version == Self.currentVersion,
              !walletID.isEmpty,
              !entries.isEmpty else {
            throw BitcoinHDDerivationError.invalidChild
        }
        for (expectedIndex, entry) in entries.enumerated() {
            let privateKey = try BitcoinHDDerivationService.privateKey(
                fromBitcoinWIF: entry.wif
            )
            let derived = try BitcoinHDDerivationService().derivedAddress(
                addressType: addressType,
                branch: branch,
                index: expectedIndex,
                publicKey: privateKey.getPublicKeySecp256k1(
                    compressed: true
                )
            )
            guard entry.index == expectedIndex,
                  Self.validDerivationPath(
                    entry.derivationPath,
                    addressType: addressType,
                    branch: branch,
                    index: expectedIndex
                  ),
                  CoinType.bitcoin.validate(address: entry.address),
                  entry.address == derived.address else {
                throw BitcoinHDDerivationError.invalidChild
            }
        }
        return self
    }

    static func validDerivationPath(
        _ path: String,
        addressType: BitcoinHDAddressType,
        branch: BitcoinHDAddressBranch,
        index: Int
    ) -> Bool {
        let accountPaths = [
            addressType.accountPath,
            addressType == .bip44
                ? ElectrumSeedKind.standard.accountPath : nil,
            addressType == .bip84
                ? ElectrumSeedKind.segwit.accountPath : nil,
        ].compactMap { $0 }
        return accountPaths.contains {
            path == "\($0)/\(branch.rawValue)/\(index)"
        }
    }
}

enum BitcoinHDDerivationError: Error, Equatable {
    case invalidWallet
    case invalidExtendedPublicKey
    case invalidChild
    case invalidAddress
}

struct BitcoinHDDerivationService: Sendable {
    static let gapLimit = 20

    func accountDescriptors(
        credential: WalletRecoveryCredential
    ) throws -> [BitcoinHDAccountDescriptor] {
        if credential.electrumKind != nil {
            return [
                try ElectrumSeedDerivationService().accountDescriptor(
                    credential: credential
                )
            ]
        }
        guard let wallet = credential.makeHDWallet() else {
            throw BitcoinHDDerivationError.invalidWallet
        }
        return try accountDescriptors(wallet: wallet)
    }

    func accountDescriptors(
        wallet: HDWallet
    ) throws -> [BitcoinHDAccountDescriptor] {
        try BitcoinHDAddressType.allCases.map { addressType in
            if addressType.isBRD {
                return try BitcoinBRDDerivation.accountDescriptor(wallet: wallet, type: addressType)
            }
            let extendedPublicKey = wallet.getExtendedPublicKeyAccount(
                purpose: addressType.purpose,
                coin: .bitcoin,
                derivation: .default,
                version: addressType.extendedPublicVersion,
                account: 0
            )
            guard !extendedPublicKey.isEmpty else {
                throw BitcoinHDDerivationError.invalidExtendedPublicKey
            }
            let descriptor = BitcoinHDAccountDescriptor(
                addressType: addressType,
                accountIndex: 0,
                accountPath: addressType.accountPath,
                extendedPublicKey: extendedPublicKey
            )

            // Verify the public account root against the private derivation
            // before it is persisted. This catches a purpose/version mismatch
            // without ever storing a child private key.
            let publicChild = try deriveAddress(
                descriptor: descriptor,
                branch: .external,
                index: 0
            )
            let privateChild = try deriveAddress(
                wallet: wallet,
                addressType: addressType,
                branch: .external,
                index: 0
            )
            guard publicChild.address == privateChild.address,
                  publicChild.publicKey == privateChild.publicKey else {
                throw BitcoinHDDerivationError.invalidExtendedPublicKey
            }
            return descriptor
        }
    }

    func deriveAddress(
        descriptor: BitcoinHDAccountDescriptor,
        branch: BitcoinHDAddressBranch,
        index: Int
    ) throws -> BitcoinHDDerivedAddress {
        if descriptor.addressType.isBRD {
            return try BitcoinBRDDerivation.deriveAddress(descriptor: descriptor, branch: branch, index: index)
        }
        if descriptor.isElectrum {
            return try ElectrumSeedDerivationService().deriveAddress(
                descriptor: descriptor,
                branch: branch,
                index: index
            )
        }
        guard index >= 0,
              index < 0x8000_0000,
              descriptor.accountIndex == 0,
              descriptor.accountPath == descriptor.addressType.accountPath,
              let publicKey = HDWallet.getPublicKeyFromExtended(
                  extended: descriptor.extendedPublicKey,
                  coin: .bitcoin,
                  // Wallet Core reads the change and address slots from a
                  // complete BIP44-shaped path, even though derivation starts
                  // at the account-level extended public key.
                  derivationPath: derivationPath(
                      addressType: descriptor.addressType,
                      branch: branch,
                      index: index
                  )
              ) else {
            throw BitcoinHDDerivationError.invalidChild
        }
        return try derivedAddress(
            addressType: descriptor.addressType,
            branch: branch,
            index: index,
            publicKey: publicKey
        )
    }

    func deriveAddress(
        wallet: HDWallet,
        addressType: BitcoinHDAddressType,
        branch: BitcoinHDAddressBranch,
        index: Int
    ) throws -> BitcoinHDDerivedAddress {
        guard index >= 0,
              index < 0x8000_0000,
              let privateKey = wallet.getKey(
                  coin: .bitcoin,
                  derivationPath: derivationPath(
                      addressType: addressType,
                      branch: branch,
                      index: index
                  )
              ) else {
            throw BitcoinHDDerivationError.invalidChild
        }
        return try derivedAddress(
            addressType: addressType,
            branch: branch,
            index: index,
            publicKey: privateKey.getPublicKeySecp256k1(compressed: true)
        )
    }

    /// Derives every standard Bitcoin address encoding that the imported WIF
    /// can spend. A compressed WIF has one compressed secp256k1 public key and
    /// therefore owns P2PKH, nested SegWit, native SegWit, and Taproot scripts.
    /// An uncompressed WIF is intentionally restricted to legacy P2PKH.
    func singleKeyAddresses(
        privateKeyData: Data,
        format: PrivateKeyImportFormat
    ) throws -> [BitcoinHDDerivedAddress] {
        guard [.wifCompressed, .wifUncompressed].contains(format),
              let privateKey = PrivateKey(data: privateKeyData) else {
            throw BitcoinHDDerivationError.invalidChild
        }
        // Fixed single-key policy, matching BlueWallet 8.0.1's BIP38/WIF import.
        // Do not expand this when mnemonic/HD wallet policies gain new types.
        let addressTypes: [BitcoinHDAddressType] = format == .wifCompressed
            ? [.bip44, .bip49, .bip84, .bip86] : [.bip44]
        let publicKey = privateKey.getPublicKeySecp256k1(
            compressed: format == .wifCompressed
        )
        return try addressTypes.map { addressType in
            try derivedAddress(
                addressType: addressType,
                branch: .external,
                index: 0,
                publicKey: publicKey,
                explicitDerivationPath:
                    "\(format.accountMarker):\(addressType.rawValue)"
            )
        }
    }

    func privateKey(
        credential: WalletRecoveryCredential,
        addressType: BitcoinHDAddressType,
        branch: BitcoinHDAddressBranch,
        index: Int
    ) throws -> PrivateKey {
        if credential.electrumKind != nil {
            return try ElectrumSeedDerivationService().privateKey(
                credential: credential,
                addressType: addressType,
                branch: branch,
                index: index
            )
        }
        guard let wallet = credential.makeHDWallet() else {
            throw BitcoinHDDerivationError.invalidWallet
        }
        return try privateKey(
            wallet: wallet,
            addressType: addressType,
            branch: branch,
            index: index
        )
    }

    func deriveAddress(
        credential: WalletRecoveryCredential,
        addressType: BitcoinHDAddressType,
        branch: BitcoinHDAddressBranch,
        index: Int
    ) throws -> BitcoinHDDerivedAddress {
        if credential.electrumKind != nil {
            let descriptor = try ElectrumSeedDerivationService()
                .accountDescriptor(credential: credential)
            guard descriptor.addressType == addressType else {
                throw BitcoinHDDerivationError.invalidChild
            }
            return try ElectrumSeedDerivationService().deriveAddress(
                descriptor: descriptor,
                branch: branch,
                index: index
            )
        }
        guard let wallet = credential.makeHDWallet() else {
            throw BitcoinHDDerivationError.invalidWallet
        }
        return try deriveAddress(
            wallet: wallet,
            addressType: addressType,
            branch: branch,
            index: index
        )
    }

    func privateKey(
        wallet: HDWallet,
        addressType: BitcoinHDAddressType,
        branch: BitcoinHDAddressBranch,
        index: Int
    ) throws -> PrivateKey {
        guard index >= 0,
              index < 0x8000_0000,
              let privateKey = wallet.getKey(
                  coin: .bitcoin,
                  derivationPath: derivationPath(
                      addressType: addressType,
                      branch: branch,
                      index: index
                  )
              ) else {
            throw BitcoinHDDerivationError.invalidChild
        }
        return privateKey
    }

    func childKeyCacheEntry(
        credential: WalletRecoveryCredential,
        addressType: BitcoinHDAddressType,
        branch: BitcoinHDAddressBranch,
        index: Int
    ) throws -> BitcoinHDChildKeyCacheEntry {
        let privateKey = try privateKey(
            credential: credential,
            addressType: addressType,
            branch: branch,
            index: index
        )
        let derived = try deriveAddress(
            credential: credential,
            addressType: addressType,
            branch: branch,
            index: index
        )
        guard privateKey.getPublicKeySecp256k1(compressed: true).data
                == derived.publicKey else {
            throw BitcoinHDDerivationError.invalidChild
        }
        return BitcoinHDChildKeyCacheEntry(
            index: index,
            derivationPath: derived.derivationPath,
            address: derived.address,
            wif: Self.bitcoinWIF(privateKey: privateKey)
        )
    }

    func childKeyCacheEntry(
        wallet: HDWallet,
        addressType: BitcoinHDAddressType,
        branch: BitcoinHDAddressBranch,
        index: Int
    ) throws -> BitcoinHDChildKeyCacheEntry {
        let privateKey = try privateKey(
            wallet: wallet,
            addressType: addressType,
            branch: branch,
            index: index
        )
        let derived = try deriveAddress(
            wallet: wallet,
            addressType: addressType,
            branch: branch,
            index: index
        )
        guard privateKey.getPublicKeySecp256k1(compressed: true).data
                == derived.publicKey else {
            throw BitcoinHDDerivationError.invalidChild
        }
        return BitcoinHDChildKeyCacheEntry(
            index: index,
            derivationPath: derived.derivationPath,
            address: derived.address,
            wif: Self.bitcoinWIF(privateKey: privateKey)
        )
    }

    static func bitcoinWIF(privateKey: PrivateKey) -> String {
        var payload = Data([0x80])
        payload.append(privateKey.data)
        payload.append(0x01)
        return Base58.encode(data: payload)
    }

    static func privateKey(fromBitcoinWIF encoded: String) throws
        -> PrivateKey {
        let raw: Data
        if let checked = Base58.decode(string: encoded) {
            raw = checked
        } else if let decoded = Base58.decodeNoCheck(string: encoded),
                  decoded.count >= 4 {
            let payload = Data(decoded.dropLast(4))
            let checksum = Data(decoded.suffix(4))
            guard Hash.sha256SHA256(data: payload)
                .prefix(4).elementsEqual(checksum) else {
                throw BitcoinHDDerivationError.invalidChild
            }
            raw = payload
        } else {
            throw BitcoinHDDerivationError.invalidChild
        }
        guard raw.count == 34,
              raw.first == 0x80,
              raw.last == 0x01,
              let privateKey = PrivateKey(
                  data: Data(raw.dropFirst().dropLast())
              ) else {
            throw BitcoinHDDerivationError.invalidChild
        }
        return privateKey
    }

    func derivationPath(
        addressType: BitcoinHDAddressType,
        branch: BitcoinHDAddressBranch,
        index: Int
    ) -> String {
        "\(addressType.accountPath)/\(branch.rawValue)/\(index)"
    }

    func derivedAddress(
        addressType: BitcoinHDAddressType,
        branch: BitcoinHDAddressBranch,
        index: Int,
        publicKey: PublicKey,
        explicitDerivationPath: String? = nil
    ) throws -> BitcoinHDDerivedAddress {
        let address: String
        switch addressType {
        case .bip44, .brdLegacy:
            var payload = Data([0x00])
            // Wallet Core's `bitcoinKeyHash` normalizes secp256k1 keys to
            // their compressed encoding. That is correct for HD keys, but
            // would make an imported uncompressed WIF point at the wrong
            // legacy address. Hash the exact SEC bytes supplied here.
            payload.append(Hash.sha256RIPEMD(data: publicKey.data))
            address = Base58.encode(data: payload)
        case .bip49:
            let redeemScript = BitcoinScript
                .buildPayToWitnessPubkeyHash(
                    hash: publicKey.bitcoinKeyHash
                )
            var payload = Data([0x05])
            payload.append(redeemScript.scriptHash)
            address = Base58.encode(data: payload)
        case .bip84, .brdSegwit:
            address = SegwitAddress(
                hrp: .bitcoin,
                publicKey: publicKey
            ).description
        case .bip86:
            address = CoinType.bitcoin
                .deriveAddressFromPublicKeyAndDerivation(
                    publicKey: publicKey,
                    derivation: .bitcoinTaproot
                )
        }

        guard CoinType.bitcoin.validate(address: address) else {
            throw BitcoinHDDerivationError.invalidAddress
        }
        let script = BitcoinScript.lockScriptForAddress(
            address: address,
            coin: .bitcoin
        ).data
        guard !script.isEmpty else {
            throw BitcoinHDDerivationError.invalidAddress
        }
        let scriptHash = Data(SHA256.hash(data: script))
            .reversed()
            .map { String(format: "%02x", $0) }
            .joined()
        return BitcoinHDDerivedAddress(
            addressType: addressType,
            branch: branch,
            index: index,
            derivationPath: explicitDerivationPath ?? derivationPath(
                addressType: addressType,
                branch: branch,
                index: index
            ),
            address: address,
            publicKey: publicKey.data,
            scriptPubKey: script,
            scriptHash: scriptHash
        )
    }
}
