import Foundation
import WalletCore

enum BitcoinElectrumLegacyFile {
    static func upgraded(_ original: [String: Any]) throws -> [String: Any] {
        var object = original
        if let version = object["seed_version"] as? NSNumber {
            guard version.doubleValue == Double(version.intValue), version.intValue <= 71 else {
                throw BitcoinImportError.unsupportedDatabase
            }
        }
        if let accounts = object["accounts"] as? [String: Any], accounts.count > 1 {
            throw BitcoinImportError.incompleteBackup
        }
        if let imported = object["imported_keys"] as? [String: Any], !imported.isEmpty {
            throw BitcoinImportError.incompleteBackup
        }
        if object["keystore"] == nil {
            let type = object["wallet_type"] as? String
            if type == "old" || (object["seed_version"] as? Int == 4) ||
                (type == nil && (object["master_public_key"] as? String)?.count == 128) {
                object["keystore"] = ["type": "old", "seed": object["seed"] ?? NSNull(), "mpk": object["master_public_key"] ?? NSNull()]
                object["wallet_type"] = "standard"
            } else if ["standard", "xpub", "bip44"].contains(type ?? ""), object["key_type"] as? String != "imported" {
                let name = type == "bip44" ? "x/0'" : "x/"
                guard let publics = object["master_public_keys"] as? [String: String], publics.count == 1,
                      let pub = publics[name] else { throw BitcoinImportError.invalidFile }
                let privates = object["master_private_keys"] as? [String: String] ?? [:]
                object["keystore"] = ["type": "bip32", "xpub": pub, "xprv": (privates[name] as Any?) ?? NSNull()]
                object["wallet_type"] = "standard"
            } else if let accounts = object["accounts"] as? [String: Any],
                      let account = accounts["/x"] as? [String: Any], let imported = account["imported"] as? [String: [Any]] {
                var pairs: [String: String] = [:]
                var addresses: [String: Any] = [:]
                for (address, pair) in imported {
                    guard pair.count == 2, let pub = pair[0] as? String, let priv = pair[1] as? String else {
                        throw BitcoinImportError.privateKeyRequired
                    }
                    pairs[pub] = priv
                    addresses[address] = ["type": "p2pkh", "pubkey": pub]
                }
                object["keystore"] = ["type": "imported", "keypairs": pairs]
                object["addresses"] = addresses
                object["wallet_type"] = "imported"
            } else if object["key_type"] as? String == "imported" {
                object["keystore"] = ["type": "imported", "keypairs": object["keypairs"] ?? NSNull()]
            }
        }
        // Version 13 standard/imported wallets used a receiving-address array.
        if object["wallet_type"] as? String == "standard",
           let store = object["keystore"] as? [String: Any], store["type"] as? String == "imported",
           let pairs = store["keypairs"] as? [String: String] {
            let old = object["addresses"] as? [String: [String]]
            var addresses: [String: Any] = [:]
            for pub in pairs.keys {
                guard let bytes = Data(hexString: pub), let key = PublicKey(data: bytes, type: bytes.count == 65 ? .secp256k1Extended : .secp256k1),
                      [33, 65].contains(bytes.count) else { throw BitcoinImportError.invalidFile }
                let address = try BitcoinHDDerivationService().derivedAddress(addressType: .bip44,
                    branch: .external, index: 0, publicKey: key, explicitDerivationPath: "electrum-legacy-validation").address
                addresses[address] = ["type": "p2pkh", "pubkey": pub]
            }
            if let old {
                guard Set(old["receiving"] ?? []) == Set(addresses.keys), (old["change"] ?? []).isEmpty else {
                    throw BitcoinImportError.invalidFile
                }
            }
            object["addresses"] = addresses
            object["wallet_type"] = "imported"
        }
        return object
    }
}
