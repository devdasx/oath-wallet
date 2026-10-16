import OathDiagnostics
import Foundation
import WalletCore
import OathBitcoin

extension OathWalletEngine {
    /// Bounded decoding and address derivation run off MainActor. Invalid
    /// checksums, algorithms, network prefixes and keypair public halves fail.
    static func importedPrivateKey(_ input: String, choice: OathPrivateKeyChoice) throws -> OathImportedPrivateKey {
        try Task.checkCancellation()
        guard input.utf8.count <= 2_048, let chain = choice.networks.first,
              let canonical = OathPrivateKeyChoice.all.first(where: { $0.id == choice.id }),
              !choice.networks.isEmpty, Set(choice.networks).count == choice.networks.count,
              choice.networks.allSatisfy(canonical.networks.contains) else { throw OathWalletError.invalidPrivateKey }
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let network = UTXONetwork(rawValue: chain.id) {
            do {
                let parsed = try network.decodeImport(text)
                return .init(bytes: parsed.bytes, networks: [chain], compressed: parsed.compressed,
                             bitcoinExtendedKey: chain == .bitcoin ? parsed.extended : nil,
                             dogecoinExtendedKey: chain == .dogecoin ? parsed.extended : nil,
                             bitcoinCashExtendedKey: chain == .bitcoincash ? parsed.extended : nil,
                             litecoinExtendedKey: chain == .litecoin ? parsed.extended : nil)
            } catch { OathDiagnostics.record(error); throw OathWalletError.invalidPrivateKey }
        }
        var bytes: Data
        switch chain {
        case .bitcoin, .bitcoincash, .litecoin, .dogecoin:
            let prefix: UInt8 = chain == .litecoin ? 0xb0 : (chain == .dogecoin ? 0x9e : 0x80)
            guard var payload = Base58.decode(string: text) else { throw OathWalletError.invalidPrivateKey }
            defer { payload.resetBytes(in: 0..<payload.count) }
            // These accounts use compressed public keys; silently treating an
            // uncompressed WIF as compressed would produce a different wallet.
            guard payload.count == 34, payload.first == prefix, payload.last == 1 else {
                throw OathWalletError.invalidPrivateKey
            }
            bytes = Data(payload.dropFirst().dropLast())
        case .solana, .near:
            let encoded: String
            if chain == .near {
                guard text.hasPrefix("ed25519:") else { throw OathWalletError.invalidPrivateKey }
                encoded = String(text.dropFirst(8))
            } else { encoded = text }
            var pair: Data
            if chain == .solana, encoded.hasPrefix("[") {
                guard let array = try? JSONDecoder().decode([UInt8].self, from: Data(encoded.utf8)) else {
                    throw OathWalletError.invalidPrivateKey
                }
                pair = Data(array)
            } else {
                guard let decoded = Base58.decodeNoCheck(string: encoded) else { throw OathWalletError.invalidPrivateKey }
                pair = decoded
            }
            defer { pair.resetBytes(in: 0..<pair.count) }
            guard pair.count == 64, let key = PrivateKey(data: Data(pair.prefix(32))),
                  key.getPublicKeyEd25519().data == Data(pair.suffix(32)) else { throw OathWalletError.invalidPrivateKey }
            bytes = Data(pair.prefix(32))
        case .stellar:
            guard text.count == 56, text.hasPrefix("S"), var payload = Base32.decode(string: text) else {
                throw OathWalletError.invalidPrivateKey
            }
            defer { payload.resetBytes(in: 0..<payload.count) }
            guard payload.count == 35, payload.first == 144 else { throw OathWalletError.invalidPrivateKey }
            var crc: UInt16 = 0
            for byte in payload.dropLast(2) {
                crc ^= UInt16(byte) << 8
                for _ in 0..<8 { crc = (crc & 0x8000) != 0 ? (crc << 1) ^ 0x1021 : crc << 1 }
            }
            guard payload[33] == UInt8(truncatingIfNeeded: crc),
                  payload[34] == UInt8(truncatingIfNeeded: crc >> 8) else { throw OathWalletError.invalidPrivateKey }
            bytes = Data(payload.dropFirst().dropLast(2))
        case .sui:
            guard text.hasPrefix("suiprivkey1"), var payload = Bech32.decode(string: text) else {
                throw OathWalletError.invalidPrivateKey
            }
            defer { payload.resetBytes(in: 0..<payload.count) }
            guard payload.count == 33, payload.first == 0 else { throw OathWalletError.invalidPrivateKey }
            bytes = Data(payload.dropFirst())
        case .aptos:
            bytes = try privateKeyHex(text.hasPrefix("ed25519-priv-0x") ? String(text.dropFirst(15)) : text)
        case .xrpl:
            bytes = try privateKeyHex(text.count == 66 && text.hasPrefix("00") ? String(text.dropFirst(2)) : text)
        default:
            bytes = try privateKeyHex(text)
        }
        defer { bytes.resetBytes(in: 0..<bytes.count) }
        guard PrivateKey.isValid(data: bytes, curve: chain.walletCoin.curve) else { throw OathWalletError.invalidPrivateKey }
        try Task.checkCancellation()
        return OathImportedPrivateKey(bytes: bytes, networks: choice.networks)
    }

    static func imported(_ material: OathImportedPrivateKey, id: UUID = UUID()) throws -> OathWalletSecret {
        guard material.isValidStructure,
              material.networks.allSatisfy({ PrivateKey.isValid(data: material.bytes, curve: $0.walletCoin.curve) }) else {
            throw OathWalletError.invalidPrivateKey
        }
        return OathWalletSecret(id: id, mnemonic: "", language: "", createdAt: .now,
                                backedUp: true, imported: true, privateKey: material)
    }

    static func importedKeyProfile(for secret: OathWalletSecret, material: OathImportedPrivateKey) throws -> OathWalletProfile {
        guard material.isValidStructure, let key = PrivateKey(data: material.bytes) else { throw OathWalletError.invalidPrivateKey }
        let addresses = try material.networks.map { chain in
            if UTXONetwork(rawValue: chain.id) != nil {
                let descriptor = try material.bitcoinDescriptor()
                guard let branch = descriptor.branches.first(where: { $0.type == descriptor.defaultType && $0.change == 0 }) ?? descriptor.branches.first(where: { $0.type == descriptor.defaultType }) else { throw OathWalletError.derivationFailed }
                let address = try BitcoinKeys.addresses(branch: branch, range: 0..<1)[0]
                return OathWalletAddress(chain: chain, address: address.address, path: "imported")
            }
            guard PrivateKey.isValid(data: material.bytes, curve: chain.walletCoin.curve) else { throw OathWalletError.invalidPrivateKey }
            let address = chain.walletCoin.deriveAddress(privateKey: key)
            guard AnyAddress.isValid(string: address, coin: chain.walletCoin) else { throw OathWalletError.derivationFailed }
            return OathWalletAddress(chain: chain, address: address, path: "imported")
        }
        return .init(id: secret.id, addresses: addresses, createdAt: secret.createdAt, backedUp: secret.backedUp)
    }

    private static func privateKeyHex(_ value: String) throws -> Data {
        let text = value.hasPrefix("0x") || value.hasPrefix("0X") ? String(value.dropFirst(2)) : value
        let bytes = Array(text.utf8)
        guard bytes.count == 64, bytes.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else {
            throw OathWalletError.invalidPrivateKey
        }
        return Data(try stride(from: 0, to: 64, by: 2).map {
            guard let byte = UInt8(String(decoding: bytes[$0..<$0 + 2], as: UTF8.self), radix: 16) else {
                throw OathWalletError.invalidPrivateKey
            }
            return byte
        })
    }
}
