import Foundation
import WalletCore
import OathCloudBackup
import OathBitcoin

extension OathWalletEngine {
    /// Called by the vault actor after fresh authorization. Use the committed
    /// path, not a newly chosen default, and refuse a key/address mismatch.
    static func privateKey(for secret: OathWalletSecret, account: OathPrivateKeyAccount) throws -> OathPrivateKeyExport {
        try Task.checkCancellation()
        if let origin = account.utxo {
            guard let network = UTXONetwork(rawValue: account.chain.id),
                  origin.address.path == account.path, origin.address.address == account.address else { throw OathWalletError.derivationFailed }
            let source: BitcoinPrivateKeySource
            if let material = secret.privateKey {
                guard material.isValidStructure, material.networks == [account.chain] else { throw OathWalletError.derivationFailed }
                if let extended = try material.extendedKey(for: network) {
                    source = .extended(extended)
                }
                else { source = .single(material.bytes, compressed: material.compressed != false) }
            } else if let electrum = secret.electrum {
                guard network == .bitcoin, origin.accountIndex == 0, secret.hasValidMaterial else { throw OathWalletError.invalidPhrase }
                source = .electrum(electrum)
            } else if let aezeed = secret.aezeed {
                guard network == .bitcoin, secret.hasValidMaterial else { throw OathWalletError.derivationFailed }
                source = .aezeed(aezeed.entropy, account: origin.accountIndex)
            } else {
                let passphrase = try secret.bip39Passphrase
                guard OathMnemonicValidator.bundled?.verifiedPhrase(secret.mnemonic) != nil,
                      let wallet = HDWallet(mnemonic: secret.mnemonic, passphrase: passphrase, check: false) else { throw OathWalletError.derivationFailed }
                var seed = wallet.seed
                defer { seed.resetBytes(in: 0..<seed.count) }
                return .init(value: try network.privateKeyWIF(source: .seed(seed, account: origin.accountIndex), address: origin.address), format: "WIF")
            }
            return .init(value: try network.privateKeyWIF(source: source, address: origin.address), format: "WIF")
        }
        if let material = secret.privateKey {
            if let network = UTXONetwork(rawValue: account.chain.id) {
                let expected = try importedKeyProfile(for: secret, material: material)
                guard expected.addresses.contains(where: { $0.address == account.address && $0.path == account.path }) else { throw OathWalletError.derivationFailed }
                if let extended = try material.extendedKey(for: network) { return .init(value: extended, format: "BIP32") }
                return .init(value: try network.wif(bytes: material.bytes, compressed: material.compressed != false), format: "WIF")
            }
            guard material.isValidStructure,
                  (material.networks.contains(account.chain) || (account.chain.isEVM && material.isFullEVMScope)), account.path == "imported",
                  let key = PrivateKey(data: material.bytes),
                  account.chain.walletCoin.deriveAddress(privateKey: key) == account.address else {
                throw OathWalletError.derivationFailed
            }
            return try encodePrivateKey(key, chain: account.chain)
        }
        let passphrase = try secret.bip39Passphrase
        guard validExportPath(account.path),
              OathMnemonicValidator.bundled?.verifiedPhrase(secret.mnemonic) != nil,
              let wallet = HDWallet(mnemonic: secret.mnemonic, passphrase: passphrase, check: false),
              let key = wallet.getKey(coin: account.chain.walletCoin, derivationPath: account.path) else {
            throw OathWalletError.derivationFailed
        }
        let derived = account.chain.walletCoin.deriveAddress(privateKey: key)
        guard !derived.isEmpty, derived == account.address else { throw OathWalletError.derivationFailed }
        try Task.checkCancellation()
        return try encodePrivateKey(key, chain: account.chain)
    }

    private static func validExportPath(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.first == "m", (2...11).contains(parts.count) else { return false }
        return parts.dropFirst().allSatisfy { part in
            let digits = part.last == "'" ? part.dropLast() : part[...]
            return !digits.isEmpty && digits.utf8.allSatisfy { (48...57).contains($0) }
                && UInt32(digits).map { $0 < 0x80000000 } == true
        }
    }

    private static func encodePrivateKey(_ key: PrivateKey, chain: OathImportChain) throws -> OathPrivateKeyExport {
        var bytes = key.data
        defer { bytes.resetBytes(in: bytes.startIndex..<bytes.endIndex) }
        guard bytes.count == 32 else { throw OathWalletError.derivationFailed }
        switch chain {
        case .bitcoin, .bitcoincash, .litecoin, .dogecoin:
            let prefix: UInt8 = chain == .litecoin ? 0xb0 : (chain == .dogecoin ? 0x9e : 0x80)
            var payload = Data([prefix]) + bytes + Data([0x01])
            defer { payload.resetBytes(in: payload.startIndex..<payload.endIndex) }
            return .init(value: Base58.encode(data: payload), format: "WIF")
        case .solana, .near:
            // Both ecosystems encode the Ed25519 seed followed by its public
            // key, not just the 32-byte seed. NEAR adds the algorithm prefix.
            var pair = bytes + key.getPublicKeyEd25519().data
            defer { pair.resetBytes(in: pair.startIndex..<pair.endIndex) }
            let value = Base58.encodeNoCheck(data: pair)
            return .init(value: chain == .near ? "ed25519:" + value : value, format: "Ed25519 · Base58")
        case .stellar:
            // Stellar StrKey: secret-seed version 18<<3, CRC16-XModem in
            // little-endian order, then unpadded Base32 (SEP-0023).
            var payload = Data([18 << 3]) + bytes
            defer { payload.resetBytes(in: payload.startIndex..<payload.endIndex) }
            var crc: UInt16 = 0
            for byte in payload {
                crc ^= UInt16(byte) << 8
                for _ in 0..<8 { crc = (crc & 0x8000) != 0 ? (crc << 1) ^ 0x1021 : crc << 1 }
            }
            payload.append(UInt8(truncatingIfNeeded: crc))
            payload.append(UInt8(truncatingIfNeeded: crc >> 8))
            return .init(value: Base32.encode(data: payload), format: "StrKey")
        case .sui:
            // SIP-15: Bech32(flag || 32-byte key), flag 0 for Ed25519.
            var payload = Data([0]) + bytes
            defer { payload.resetBytes(in: payload.startIndex..<payload.endIndex) }
            return .init(value: Bech32.encode(hrp: "suiprivkey", data: payload), format: "Ed25519 · Bech32")
        case .aptos:
            return .init(value: "ed25519-priv-0x" + hex(bytes), format: "Ed25519 · AIP-80")
        case .xrpl:
            // XRPL's secp256k1 signing-key prefix. A BIP-32 key must never be
            // mislabeled as an XRPL family seed (which derives another key).
            return .init(value: "00" + hex(bytes).uppercased(), format: "secp256k1 · Hex")
        case .polkadot, .ton:
            return .init(value: hex(bytes), format: "Ed25519 · Hex")
        case .tron, .thorchain:
            return .init(value: hex(bytes), format: "secp256k1 · Hex")
        case .arbitrum, .arc, .avalanche, .base, .bnb, .ethereum, .fantom, .flare, .somnia, .story, .gnosis,
             .linea, .optimism, .polygon, .chiliz, .filecoin, .sei, .zerog, .iotex, .celo, .monad, .unichain, .hyperevm, .robinhood, .scroll, .taiko, .telos, .xlayer:
            return .init(value: "0x" + hex(bytes), format: "secp256k1 · Hex")
        }
    }

    private static func hex(_ bytes: Data) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}
