import Foundation
import WalletCore

enum PrivateKeyImportError: Error {
    case empty
    case invalidEncoding
    case unsupportedFormat
    case invalidPrivateKey
    case invalidAddress
    case publicKeyMismatch
}

enum PrivateKeyImportService {
    static func importKey(
        _ encoded: String,
        network: PrivateKeyImportNetwork
    ) throws -> WalletImportDraft {
        let normalized = encoded.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !normalized.isEmpty else {
            throw PrivateKeyImportError.empty
        }

        if network == .bitcoin {
            if normalized.hasPrefix("{") {
                return try BitcoinImportedWalletMaterial.decode(Data(normalized.utf8)).importDraft()
            }
            if normalized.contains(":") {
                let descriptor = try BitcoinImportKeyEncoding.electrumDescriptor(normalized)
                return try BitcoinImportedWalletMaterial(sources: [.init(descriptor: descriptor)]).importDraft()
            }
            if normalized.contains("(") {
                return try BitcoinImportedWalletMaterial(sources: [.init(descriptor: BitcoinPrivateDescriptor(normalized))]).importDraft()
            }
            if let key = try? BitcoinImportKeyEncoding.base64(normalized) {
                // Bare Base64 has no script metadata and can contain an already
                // tweaked Taproot output key. Retain rawtr as well as the standard
                // single-key scripts, so discovery and signing use the same policy.
                return try BitcoinImportedWalletMaterial(
                    sources: BitcoinImportedWalletMaterial.fixed(key, includingRawTaproot: true)
                ).importDraft()
            }
            if normalized.hasPrefix("S") {
                let key = try BitcoinImportKeyEncoding.mini(normalized)
                return try revalidate(privateKeyData: key.key, network: .bitcoin, format: .wifUncompressed)
            }
        }

        switch network {
        case .aptos:
            return try aptosDraft(
                data: try hexadecimalPrivateKey(normalized),
                format: .rawEd25519
            )
        case .stellar:
            return try stellarDraft(
                data: try hexadecimalPrivateKey(normalized),
                format: .rawEd25519
            )
        case .evm:
            return try secpDraft(
                data: try hexadecimalPrivateKey(normalized),
                network: network,
                format: .rawSecp256k1,
                coin: .ethereum
            )
        case .tron:
            return try secpDraft(
                data: try hexadecimalPrivateKey(normalized),
                network: network,
                format: .rawSecp256k1,
                coin: .tron
            )
        case .solana:
            return try solanaDraft(normalized)
        case .ton:
            return try tonDraft(
                data: try hexadecimalPrivateKey(normalized),
                format: .rawEd25519
            )
        case .sui:
            return try suiDraft(
                data: try hexadecimalPrivateKey(normalized),
                format: .rawEd25519
            )
        case .near:
            return try nearDraft(
                data: try hexadecimalPrivateKey(normalized),
                format: .rawEd25519
            )
        case .xrp:
            return try secpDraft(
                data: try hexadecimalPrivateKey(normalized),
                network: network,
                format: .rawSecp256k1,
                coin: .xrp
            )
        case .bitcoin, .litecoin, .dogecoin, .bitcoinCash:
            guard let chain = network.bitcoinFamilyChain else {
                throw PrivateKeyImportError.unsupportedFormat
            }
            return try bitcoinFamilyDraft(
                normalized,
                network: network,
                chain: chain
            )
        }
    }

    static func revalidate(
        privateKeyData: Data,
        network: PrivateKeyImportNetwork,
        format: PrivateKeyImportFormat
    ) throws -> WalletImportDraft {
        switch network {
        case .aptos:
            return try aptosDraft(
                data: privateKeyData,
                format: format
            )
        case .stellar:
            return try stellarDraft(data: privateKeyData, format: format)
        case .evm:
            return try secpDraft(
                data: privateKeyData,
                network: network,
                format: format,
                coin: .ethereum
            )
        case .tron:
            return try secpDraft(
                data: privateKeyData,
                network: network,
                format: format,
                coin: .tron
            )
        case .solana:
            return try solanaDraft(
                seed: privateKeyData,
                format: format
            )
        case .ton:
            return try tonDraft(
                data: privateKeyData,
                format: format
            )
        case .sui:
            return try suiDraft(
                data: privateKeyData,
                format: format
            )
        case .near:
            return try nearDraft(
                data: privateKeyData,
                format: format
            )
        case .xrp:
            return try secpDraft(
                data: privateKeyData,
                network: network,
                format: format,
                coin: .xrp
            )
        case .bitcoin, .litecoin, .dogecoin, .bitcoinCash:
            guard let chain = network.bitcoinFamilyChain else {
                throw PrivateKeyImportError.unsupportedFormat
            }
            let material = try BitcoinFamilyDerivationService()
                .derive(
                    privateKey: privateKeyData,
                    chain: chain,
                    format: format
                )
            return draft(
                privateKeyData: privateKeyData,
                network: network,
                format: format,
                address: material.address,
                normalizedAddress: material.address.lowercased(),
                derivationPath: format.accountMarker,
                publicKey: material.publicKey
            )
        }
    }

    static func isValid(
        _ encoded: String,
        network: PrivateKeyImportNetwork
    ) -> Bool {
        (try? importKey(encoded, network: network)) != nil
    }

    private static func bitcoinFamilyDraft(
        _ encoded: String,
        network: PrivateKeyImportNetwork,
        chain: BitcoinFamilyChain
    ) throws -> WalletImportDraft {
        let keyData: Data
        let format: PrivateKeyImportFormat
        let derivationPath: String?

        if chain == .bitcoin, let hexadecimal = try? hexadecimalPrivateKey(encoded) {
            guard PrivateKey.isValid(data: hexadecimal, curve: .secp256k1) else {
                throw PrivateKeyImportError.invalidPrivateKey
            }
            keyData = hexadecimal
            // HEX has no compression marker. Normalize to the existing compressed
            // WIF identity so persistence, discovery, receive and signing agree.
            format = .wifCompressed
            derivationPath = nil
        } else if let wif = try? decodeWIF(encoded, chain: chain) {
            keyData = wif.data
            format = wif.compressed
                ? .wifCompressed : .wifUncompressed
            derivationPath = nil
        } else {
            let extended: BitcoinExtendedPrivateKey
            do {
                extended = try BitcoinExtendedPrivateKey(
                    encoded: encoded,
                    chain: chain
                )
            } catch {
                throw PrivateKeyImportError.unsupportedFormat
            }
            keyData = extended.privateKeyData
            format = extended.format
            derivationPath = extended.derivationPath
        }

        let material = try BitcoinFamilyDerivationService().derive(
            privateKey: keyData,
            chain: chain,
            format: format,
            derivationPath: derivationPath
        )
        return draft(
            privateKeyData: keyData,
            network: network,
            format: format,
            address: material.address,
            normalizedAddress: material.address.lowercased(),
            derivationPath: format.accountMarker,
            publicKey: material.publicKey
        )
    }

    private static func secpDraft(
        data: Data,
        network: PrivateKeyImportNetwork,
        format: PrivateKeyImportFormat,
        coin: CoinType
    ) throws -> WalletImportDraft {
        guard PrivateKey.isValid(data: data, curve: .secp256k1),
              let privateKey = PrivateKey(data: data)
        else {
            throw PrivateKeyImportError.invalidPrivateKey
        }
        let address = coin.deriveAddress(privateKey: privateKey)
        guard coin.validate(address: address) else {
            throw PrivateKeyImportError.invalidAddress
        }
        return draft(
            privateKeyData: data,
            network: network,
            format: format,
            address: address,
            normalizedAddress: network == .evm
                ? address.lowercased() : address,
            derivationPath: format.accountMarker,
            publicKey: privateKey
                .getPublicKeySecp256k1(compressed: false)
                .description
        )
    }

    private static func solanaDraft(
        _ encoded: String
    ) throws -> WalletImportDraft {
        let bytes: Data
        let format: PrivateKeyImportFormat

        if encoded.first == "[",
           let data = encoded.data(using: .utf8),
           let values = try? JSONDecoder().decode([UInt8].self, from: data) {
            bytes = Data(values)
            format = values.count == 64
                ? .solanaKeypair : .solanaSeed
        } else if let decoded = Base58.decodeNoCheck(string: encoded),
                  [32, 64].contains(decoded.count) {
            bytes = decoded
            format = decoded.count == 64
                ? .solanaKeypair : .solanaSeed
        } else if let hexadecimal = try? hexadecimalPrivateKey(encoded) {
            bytes = hexadecimal
            format = .solanaSeed
        } else {
            throw PrivateKeyImportError.invalidEncoding
        }

        let seed: Data
        if bytes.count == 64 {
            seed = Data(bytes.prefix(32))
            guard let privateKey = PrivateKey(data: seed),
                  privateKey.getPublicKeyEd25519().data
                    .elementsEqual(bytes.suffix(32))
            else {
                throw PrivateKeyImportError.publicKeyMismatch
            }
        } else if bytes.count == 32 {
            seed = bytes
        } else {
            throw PrivateKeyImportError.invalidEncoding
        }
        return try solanaDraft(seed: seed, format: format)
    }

    private static func tonDraft(
        data: Data,
        format: PrivateKeyImportFormat
    ) throws -> WalletImportDraft {
        guard data.count == 32,
              let privateKey = PrivateKey(data: data)
        else {
            throw PrivateKeyImportError.invalidPrivateKey
        }
        let material: TONAccountMaterial
        do {
            material = try TONAddress.material(
                privateKey: privateKey,
                derivationPath: format.accountMarker
            )
        } catch {
            throw PrivateKeyImportError.invalidAddress
        }
        return draft(
            privateKeyData: data,
            network: .ton,
            format: format,
            address: material.address,
            normalizedAddress: material.rawAddress,
            derivationPath: format.accountMarker,
            publicKey: material.publicKey
        )
    }

    private static func suiDraft(
        data: Data,
        format: PrivateKeyImportFormat
    ) throws -> WalletImportDraft {
        guard data.count == 32,
              let privateKey = PrivateKey(data: data)
        else {
            throw PrivateKeyImportError.invalidPrivateKey
        }
        let address = CoinType.sui.deriveAddress(privateKey: privateKey)
        guard let canonical = SuiCoinType.validatedAccountAddress(address)
        else {
            throw PrivateKeyImportError.invalidAddress
        }
        return draft(
            privateKeyData: data,
            network: .sui,
            format: format,
            address: canonical,
            normalizedAddress: canonical,
            derivationPath: format.accountMarker,
            publicKey: privateKey.getPublicKeyEd25519().description
        )
    }

    private static func nearDraft(
        data: Data,
        format: PrivateKeyImportFormat
    ) throws -> WalletImportDraft {
        guard data.count == 32,
              let privateKey = PrivateKey(data: data)
        else {
            throw PrivateKeyImportError.invalidPrivateKey
        }
        let material: NEARAccountMaterial
        do {
            material = try NEARAddress.material(
                privateKey: privateKey,
                derivationPath: format.accountMarker
            )
        } catch {
            throw PrivateKeyImportError.invalidAddress
        }
        return draft(
            privateKeyData: data,
            network: .near,
            format: format,
            address: material.address,
            normalizedAddress: material.address,
            derivationPath: format.accountMarker,
            publicKey: material.publicKey
        )
    }

    private static func aptosDraft(
        data: Data,
        format: PrivateKeyImportFormat
    ) throws -> WalletImportDraft {
        guard data.count == 32,
              let privateKey = PrivateKey(data: data)
        else {
            throw PrivateKeyImportError.invalidPrivateKey
        }
        let material: AptosAccountMaterial
        do {
            material = try AptosAddress.material(
                privateKey: privateKey,
                derivationPath: format.accountMarker
            )
        } catch {
            throw PrivateKeyImportError.invalidAddress
        }
        return draft(
            privateKeyData: data,
            network: .aptos,
            format: format,
            address: material.address,
            normalizedAddress: material.address,
            derivationPath: format.accountMarker,
            publicKey: material.publicKey
        )
    }

    private static func stellarDraft(
        data: Data,
        format: PrivateKeyImportFormat
    ) throws -> WalletImportDraft {
        guard data.count == 32, let privateKey = PrivateKey(data: data) else {
            throw PrivateKeyImportError.invalidPrivateKey
        }
        let material: StellarAccountMaterial
        do {
            material = try StellarAddress.material(
                privateKey: privateKey,
                derivationPath: format.accountMarker
            )
        } catch {
            throw PrivateKeyImportError.invalidAddress
        }
        return draft(
            privateKeyData: data,
            network: .stellar,
            format: format,
            address: material.address,
            normalizedAddress: material.address,
            derivationPath: format.accountMarker,
            publicKey: material.publicKey
        )
    }

    private static func solanaDraft(
        seed: Data,
        format: PrivateKeyImportFormat
    ) throws -> WalletImportDraft {
        guard seed.count == 32,
              let privateKey = PrivateKey(data: seed)
        else {
            throw PrivateKeyImportError.invalidPrivateKey
        }
        let address = CoinType.solana.deriveAddress(
            privateKey: privateKey
        )
        guard CoinType.solana.validate(address: address) else {
            throw PrivateKeyImportError.invalidAddress
        }
        return draft(
            privateKeyData: seed,
            network: .solana,
            format: format,
            address: address,
            normalizedAddress: address,
            derivationPath: format.accountMarker,
            publicKey: privateKey.getPublicKeyEd25519()
                .data.base64EncodedString()
        )
    }

    private static func decodeWIF(
        _ encoded: String,
        chain: BitcoinFamilyChain
    ) throws -> (data: Data, compressed: Bool) {
        let raw: Data
        if let checked = Base58.decode(string: encoded) {
            raw = checked
        } else if let decoded = Base58.decodeNoCheck(string: encoded),
                  decoded.count >= 4 {
            let payload = Data(decoded.dropLast(4))
            let checksum = Data(decoded.suffix(4))
            guard Hash.sha256SHA256(data: payload)
                .prefix(4).elementsEqual(checksum)
            else {
                throw PrivateKeyImportError.invalidEncoding
            }
            raw = payload
        } else {
            throw PrivateKeyImportError.invalidEncoding
        }

        let expectedPrefix: UInt8
        switch chain {
        case .bitcoin, .bitcoinCash:
            expectedPrefix = 0x80
        case .litecoin:
            expectedPrefix = 0xb0
        case .dogecoin:
            expectedPrefix = 0x9e
        }
        guard raw.first == expectedPrefix else {
            throw PrivateKeyImportError.unsupportedFormat
        }

        let compressed: Bool
        let data: Data
        switch raw.count {
        case 33:
            compressed = false
            data = Data(raw.dropFirst())
        case 34 where raw.last == 0x01:
            compressed = true
            data = Data(raw.dropFirst().dropLast())
        default:
            throw PrivateKeyImportError.invalidEncoding
        }
        guard PrivateKey.isValid(data: data, curve: .secp256k1) else {
            throw PrivateKeyImportError.invalidPrivateKey
        }
        return (data, compressed)
    }

    private static func hexadecimalPrivateKey(
        _ encoded: String
    ) throws -> Data {
        var normalized = encoded
        if normalized.hasPrefix("0x")
            || normalized.hasPrefix("0X") {
            normalized.removeFirst(2)
        }
        guard normalized.utf8.count == 64,
              normalized.unicodeScalars.allSatisfy({
                  switch $0.value {
                  case 48...57, 65...70, 97...102:
                      true
                  default:
                      false
                  }
              }),
              let data = Data(hexString: normalized),
              data.count == 32
        else {
            throw PrivateKeyImportError.invalidEncoding
        }
        return data
    }

    private static func draft(
        privateKeyData: Data,
        network: PrivateKeyImportNetwork,
        format: PrivateKeyImportFormat,
        address: String,
        normalizedAddress: String,
        derivationPath: String?,
        publicKey: String
    ) -> WalletImportDraft {
        WalletImportDraft(
            secret: .privateKey(
                data: privateKeyData,
                network: network,
                format: format
            ),
            address: address,
            normalizedAddress: normalizedAddress,
            derivationPath: derivationPath,
            publicKey: publicKey
        )
    }
}
