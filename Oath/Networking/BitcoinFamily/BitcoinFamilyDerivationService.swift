import Foundation
import WalletCore

enum BitcoinFamilyDerivationError: Error {
    case invalidSecret
    case addressDerivationFailed
}

struct BitcoinFamilyDerivationService: Sendable {
    func derive(
        mnemonic: String,
        passphrase: String = ""
    ) throws -> [BitcoinFamilyAccountMaterial] {
        let credential = try WalletRecoveryCredential(
            mnemonic: mnemonic,
            passphrase: passphrase
        )
        return try derive(credential: credential)
    }

    func derive(
        credential: WalletRecoveryCredential
    ) throws -> [BitcoinFamilyAccountMaterial] {
        guard let wallet = credential.makeHDWallet() else {
            throw BitcoinFamilyDerivationError.invalidSecret
        }
        return try derive(wallet: wallet)
    }

    func derive(
        wallet: HDWallet
    ) throws -> [BitcoinFamilyAccountMaterial] {
        return try BitcoinFamilyChain.allCases.map { chain in
            guard let key = wallet.getKey(
                coin: chain.coin,
                derivationPath: chain.derivationPath
            ) else {
                throw BitcoinFamilyDerivationError.invalidSecret
            }
            return try material(
                chain: chain,
                privateKey: key,
                derivationPath: chain.derivationPath
            )
        }
    }

    func derive(privateKey data: Data) throws -> [BitcoinFamilyAccountMaterial] {
        return try BitcoinFamilyChain.allCases.map {
            try derive(
                privateKey: data,
                chain: $0,
                format: .wifCompressed
            )
        }
    }

    func derive(
        privateKey data: Data,
        chain: BitcoinFamilyChain,
        format: PrivateKeyImportFormat,
        derivationPath: String? = nil
    ) throws -> BitcoinFamilyAccountMaterial {
        guard PrivateKey.isValid(
            data: data,
            curve: .secp256k1
        ),
        let key = PrivateKey(data: data) else {
            throw BitcoinFamilyDerivationError.invalidSecret
        }
        return try material(
            chain: chain,
            privateKey: key,
            format: format,
            derivationPath: derivationPath
        )
    }

    private func material(
        chain: BitcoinFamilyChain,
        privateKey: PrivateKey,
        format: PrivateKeyImportFormat = .extendedNativeSegwit,
        derivationPath: String?
    ) throws -> BitcoinFamilyAccountMaterial {
        let isUncompressed = format == .wifUncompressed
        let publicKey = privateKey.getPublicKeySecp256k1(
            compressed: !isUncompressed
        )
        let address: String
        switch chain {
        case .bitcoin:
            address = try bitcoinAddress(
                publicKey: publicKey,
                format: format
            )
        case .litecoin:
            address = try litecoinAddress(
                publicKey: publicKey,
                format: format
            )
        case .bitcoinCash:
            guard let cashAddress = BitcoinCashCashAddrEncoder.p2pkh(
                publicKeyHash: publicKey.bitcoinKeyHash
            ) else {
                throw BitcoinFamilyDerivationError.addressDerivationFailed
            }
            address = cashAddress
        case .dogecoin:
            var payload = Data([0x1e])
            payload.append(publicKey.bitcoinKeyHash)
            address = Base58.encode(data: payload)
        }
        guard chain.coin.validate(address: address) else {
            throw BitcoinFamilyDerivationError.addressDerivationFailed
        }
        let script = BitcoinScript.lockScriptForAddress(
            address: address,
            coin: chain.coin
        ).data
        guard !script.isEmpty else {
            throw BitcoinFamilyDerivationError.addressDerivationFailed
        }
        return BitcoinFamilyAccountMaterial(
            chain: chain,
            address: address,
            derivationPath: derivationPath,
            publicKey: publicKey.data.map { String(format: "%02x", $0) }.joined(),
            scriptPubKey: script
        )
    }

    private func bitcoinAddress(
        publicKey: PublicKey,
        format: PrivateKeyImportFormat
    ) throws -> String {
        switch format {
        case .wifCompressed, .extendedNativeSegwit,
             .rawSecp256k1:
            return SegwitAddress(
                hrp: .bitcoin,
                publicKey: publicKey
            ).description
        case .extendedNestedSegwit:
            return nestedSegwitAddress(
                publicKey: publicKey,
                scriptHashPrefix: 0x05
            )
        case .wifUncompressed, .extendedLegacy:
            return legacyAddress(
                publicKey: publicKey,
                publicKeyHashPrefix: 0x00
            )
        case .solanaSeed, .solanaKeypair, .rawEd25519:
            throw BitcoinFamilyDerivationError.invalidSecret
        }
    }

    private func litecoinAddress(
        publicKey: PublicKey,
        format: PrivateKeyImportFormat
    ) throws -> String {
        switch format {
        case .wifCompressed, .extendedNativeSegwit,
             .rawSecp256k1:
            return SegwitAddress(
                hrp: .litecoin,
                publicKey: publicKey
            ).description
        case .extendedNestedSegwit:
            return nestedSegwitAddress(
                publicKey: publicKey,
                scriptHashPrefix: 0x32
            )
        case .wifUncompressed, .extendedLegacy:
            return legacyAddress(
                publicKey: publicKey,
                publicKeyHashPrefix: 0x30
            )
        case .solanaSeed, .solanaKeypair, .rawEd25519:
            throw BitcoinFamilyDerivationError.invalidSecret
        }
    }

    private func legacyAddress(
        publicKey: PublicKey,
        publicKeyHashPrefix: UInt8
    ) -> String {
        var payload = Data([publicKeyHashPrefix])
        // Preserve the exact SEC encoding. In particular, a WIF beginning
        // with `5` owns HASH160(uncompressed-public-key), not the compressed
        // P2PKH address for the same scalar.
        payload.append(Hash.sha256RIPEMD(data: publicKey.data))
        return Base58.encode(data: payload)
    }

    private func nestedSegwitAddress(
        publicKey: PublicKey,
        scriptHashPrefix: UInt8
    ) -> String {
        let redeemScript = BitcoinScript
            .buildPayToWitnessPubkeyHash(
                hash: publicKey.bitcoinKeyHash
            )
        var payload = Data([scriptHashPrefix])
        payload.append(redeemScript.scriptHash)
        return Base58.encode(data: payload)
    }
}
