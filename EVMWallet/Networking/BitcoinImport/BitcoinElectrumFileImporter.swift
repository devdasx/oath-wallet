import Foundation
import WalletCore

/// Reads Electrum's saved node, not a guessed BIP39 account. The `derivation`
/// field describes where that node came from; it must never be applied twice.
enum BitcoinElectrumFileImporter {
    static func recognizes(_ object: [String: Any]) -> Bool {
        object["wallet_type"] != nil || object["keystore"] != nil || object["master_public_key"] != nil
    }

    static func parse(_ original: [String: Any], password: String?) throws -> BitcoinImportedWalletMaterial {
        let object = try BitcoinElectrumLegacyFile.upgraded(original)
        if let genesis = object["genesis_blockhash"] {
            guard let hash = genesis as? String,
                  hash == "000000000019d6689c085ae165831e934ff763ae46a2a6c172b3f1b60a8ce26f" else {
                throw BitcoinImportError.unsupportedNetwork
            }
        }
        guard let type = object["wallet_type"] as? String, ["standard", "imported"].contains(type),
              object["x1/"] == nil else { throw BitcoinImportError.unsupportedScript }
        if let channels = object["channels"] as? [String: Any], !channels.isEmpty {
            throw BitcoinImportError.unsupportedScript
        }
        guard let store = object["keystore"] as? [String: Any] else { throw BitcoinImportError.noPrivateKeys }
        let encrypted = object["use_encryption"] as? Bool ?? false
        let version = try integer(store["pw_hash_version"], fallback: 1)
        func secret(_ name: String) throws -> String {
            guard let value = store[name] as? String, !value.isEmpty else { throw BitcoinImportError.privateKeyRequired }
            return try BitcoinElectrumFileCrypto.decodeSecret(value, encrypted: encrypted, password: password, version: version)
        }
        let sources: [BitcoinImportedWalletMaterial.Source]
        switch store["type"] as? String {
        case "bip32":
            guard type == "standard" else { throw BitcoinImportError.invalidFile }
            let encoded = try secret("xprv")
            let node: BitcoinImportPrivateNode
            do { node = try BitcoinImportPrivateNode(encoded: encoded) }
            catch { if encrypted { throw BitcoinImportError.incorrectPassword }; throw error }
            guard let xpub = store["xpub"] as? String, let publicPayload = Base58.decode(string: xpub),
                  let privatePayload = Base58.decode(string: encoded), publicPayload.count == 78 else {
                throw BitcoinImportError.invalidFile
            }
            let version = BitcoinImportPrivateNode.integer(Data(privatePayload.prefix(4)))
            let script: String
            let publicVersion: UInt32
            switch version {
            case 0x0488ade4: script = "p2pkh"; publicVersion = 0x0488b21e
            case 0x049d7878: script = "p2wpkh-p2sh"; publicVersion = 0x049d7cb2
            case 0x04b2430c: script = "p2wpkh"; publicVersion = 0x04b24746
            default: throw BitcoinImportError.unsupportedScript
            }
            guard BitcoinImportPrivateNode.integer(Data(publicPayload.prefix(4))) == publicVersion,
                  publicPayload[4..<45] == privatePayload[4..<45],
                  Data(publicPayload.suffix(33)) == (try node.publicKey) else { throw BitcoinImportError.invalidFile }
            let root = try node.serialized()
            sources = try branches(object) { branch in
                try descriptor(script: script, key: "\(root)/\(branch)/*")
            }
        case "old":
            guard type == "standard", let mpk = store["mpk"] as? String else { throw BitcoinImportError.invalidFile }
            let master = try BitcoinElectrumOldDerivation.master(seed: secret("seed"), publicKey: mpk)
            sources = try branches(object) { try BitcoinPrivateDescriptor(electrumOldKey: master, branch: $0) }
        case "imported":
            sources = try imported(object, store: store, encrypted: encrypted, password: password, version: version)
        case "hardware": throw BitcoinImportError.privateKeyRequired
        default: throw BitcoinImportError.unsupportedScript
        }
        return try BitcoinImportedWalletMaterial(sources: sources).validated()
    }

    private static func branches(_ object: [String: Any], build: (Int) throws -> BitcoinPrivateDescriptor) throws -> [BitcoinImportedWalletMaterial.Source] {
        let accounts = object["accounts"] as? [String: Any]
        guard let addresses = (object["addresses"] as? [String: Any]) ?? (object["pubkeys"] as? [String: Any]) ?? (accounts?["0"] as? [String: Any]) else {
            throw BitcoinImportError.invalidFile
        }
        return try [0, 1].map { branch in
            let name = branch == 0 ? "receiving" : "change"
            guard let saved = (addresses[name] ?? addresses[String(branch)]) as? [String], saved.count <= 100_000 else { throw BitcoinImportError.invalidFile }
            let gap = try integer(object[branch == 0 ? "gap_limit" : "gap_limit_for_change"], fallback: branch == 0 ? 20 : 6)
            guard (1...100_000).contains(gap) else { throw BitcoinImportError.invalidFile }
            let desc = try build(branch)
            for (index, expected) in saved.enumerated() {
                try Task.checkCancellation()
                let derived = try desc.address(index: index)
                guard derived.address == expected || derived.publicKey.hexString == expected else { throw BitcoinImportError.invalidFile }
            }
            // Include every saved address, even beyond the normal gap. Preserve
            // the file's gap for subsequent discovery and future change outputs.
            return try .init(descriptor: desc, rangeEnd: max(saved.count, gap),
                internalBranch: branch == 1, discoveryGap: gap)
        }
    }

    private static func imported(_ object: [String: Any], store: [String: Any], encrypted: Bool,
                                 password: String?, version: Int) throws -> [BitcoinImportedWalletMaterial.Source] {
        guard let pairs = store["keypairs"] as? [String: String], !pairs.isEmpty,
              pairs.count <= 100_000, let addresses = object["addresses"] as? [String: Any] else {
            throw BitcoinImportError.noPrivateKeys
        }
        var keys: [String: String] = [:]
        for (pubkey, encoded) in pairs {
            try Task.checkCancellation()
            let value = try BitcoinElectrumFileCrypto.decodeSecret(encoded, encrypted: encrypted, password: password, version: version)
            // Electrum internally encodes the script in WIF's version byte. The
            // address map is authoritative: the same key may have several scripts.
            let raw = value.split(separator: ":").last.map(String.init) ?? value
            guard var payload = Base58.decode(string: raw), [33, 34].contains(payload.count),
                  [0x80, 0x81, 0x82].contains(payload[0]) else { throw BitcoinImportError.invalidKey }
            payload[0] = 0x80
            let wif = Base58.encode(data: payload)
            let key = try BitcoinImportKeyEncoding.wif(wif)
            guard let publicBytes = Data(hexString: pubkey) else { throw BitcoinImportError.invalidFile }
            try BitcoinCoreBackupCrypto.verify(key: key.key, publicKey: publicBytes)
            guard publicBytes.count == (key.compressed ? 33 : 65) else { throw BitcoinImportError.invalidFile }
            keys[pubkey] = wif
        }
        var result: [BitcoinImportedWalletMaterial.Source] = []
        var matched = Set<String>()
        for address in addresses.keys.sorted() {
            guard let entry = addresses[address] as? [String: Any], let pubkey = entry["pubkey"] as? String,
                  let key = keys[pubkey], let type = entry["type"] as? String else { throw BitcoinImportError.privateKeyRequired }
            let desc = try descriptor(script: type, key: key)
            guard try desc.address().address == address else { throw BitcoinImportError.invalidFile }
            result.append(try .init(descriptor: desc)); matched.insert(pubkey)
        }
        guard matched == Set(keys.keys) else { throw BitcoinImportError.incompleteBackup }
        return result
    }

    private static func descriptor(script: String, key: String) throws -> BitcoinPrivateDescriptor {
        switch script {
        case "p2pkh": try BitcoinPrivateDescriptor("pkh(\(key))")
        case "p2wpkh": try BitcoinPrivateDescriptor("wpkh(\(key))")
        case "p2wpkh-p2sh": try BitcoinPrivateDescriptor("sh(wpkh(\(key)))")
        default: throw BitcoinImportError.unsupportedScript
        }
    }

    private static func integer(_ value: Any?, fallback: Int) throws -> Int {
        guard let value else { return fallback }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              let result = Int(number.stringValue) else { throw BitcoinImportError.invalidFile }
        return result
    }

}
