import CryptoKit
import Foundation
import WalletCore

enum BitcoinCoreBackupImporter {
    private struct Record {
        let type: String
        let suffix: Data
        let value: Data
    }
    private struct StoredKey {
        let publicKey: Data
        let privateKey: Data
        let descriptorID: Data?
    }

    static func parse(_ data: Data, password: String? = nil) throws -> BitcoinImportedWalletMaterial {
        let raw: [BitcoinBackupRecord]
        if data.prefix(16) == Data("SQLite format 3\0".utf8) {
            raw = try BitcoinSQLiteBackupReader(data: data).records()
        } else { raw = try BitcoinBerkeleyBackupReader(data: data).records() }
        let records = try raw.map { record in
            var reader = BitcoinBackupBytes(record.key)
            let type = try reader.string(limit: 128)
            return Record(type: type, suffix: try reader.take(reader.remaining), value: record.value)
        }
        let encrypted = records.contains { ["ckey", "walletdescriptorckey"].contains($0.type) }
        var masterKeys: [Data] = []
        defer { for index in masterKeys.indices { masterKeys[index].resetBytes(in: 0..<masterKeys[index].count) } }
        if encrypted {
            guard let password else { throw BitcoinImportError.passwordRequired }
            for record in records where record.type == "mkey" {
                do { masterKeys.append(try BitcoinCoreBackupCrypto.masterKey(record: record.value, password: password)) }
                catch BitcoinImportError.incorrectPassword { continue }
            }
            guard !masterKeys.isEmpty else { throw BitcoinImportError.incorrectPassword }
        }
        var keys: [StoredKey] = []
        for record in records where ["key", "wkey", "ckey", "walletdescriptorkey", "walletdescriptorckey"].contains(record.type) {
            try Task.checkCancellation()
            var suffix = BitcoinBackupBytes(record.suffix)
            let id = record.type.hasPrefix("walletdescriptor") ? try suffix.take(32) : nil
            let publicKey = try suffix.vector(limit: 65)
            guard suffix.remaining == 0 else { throw BitcoinImportError.invalidFile }
            var value = BitcoinBackupBytes(record.value)
            let serialized = try value.vector(limit: 1024)
            let privateKey: Data
            if record.type == "ckey" || record.type == "walletdescriptorckey" {
                if record.type == "ckey", value.remaining == 32 {
                    guard try value.take(32) == Hash.sha256SHA256(data: serialized) else {
                        throw BitcoinImportError.invalidFile
                    }
                }
                guard value.remaining == 0 else { throw BitcoinImportError.invalidFile }
                var decrypted: Data?
                for master in masterKeys {
                    if let candidate = try? BitcoinCoreBackupCrypto.privateKey(
                        encrypted: serialized, publicKey: publicKey, masterKey: master
                    ) { decrypted = candidate; break }
                }
                guard let decrypted else { throw BitcoinImportError.incorrectPassword }
                privateKey = decrypted
            } else {
                privateKey = try BitcoinCoreBackupCrypto.derPrivateKey(serialized, publicKey: publicKey)
                if record.type == "wkey" {
                    _ = try value.integer(8); _ = try value.integer(8); _ = try value.string()
                } else if value.remaining == 32 {
                    let expected = try value.take(32)
                    guard Hash.sha256SHA256(data: publicKey + serialized) == expected else {
                        throw BitcoinImportError.invalidFile
                    }
                }
                guard value.remaining == 0 else { throw BitcoinImportError.invalidFile }
            }
            keys.append(StoredKey(publicKey: publicKey, privateKey: privateKey, descriptorID: id))
        }
        guard !keys.isEmpty else { throw BitcoinImportError.noPrivateKeys }
        var sources: [BitcoinImportedWalletMaterial.Source] = []
        var representedKeys = Set<Data>()
        let descriptors = records.filter { $0.type == "walletdescriptor" }
        for record in descriptors {
            guard record.suffix.count == 32 else { throw BitcoinImportError.invalidFile }
            var value = BitcoinBackupBytes(record.value)
            let original = try value.string()
            _ = try value.integer(8) // creation timestamp
            let next = Int(try value.integer(4))
            let start = Int(try value.integer(4))
            let end = Int(try value.integer(4))
            guard value.remaining == 0 else { throw BitcoinImportError.invalidFile }
            let candidates = keys.filter { $0.descriptorID == record.suffix }
            let converted = try privateDescriptor(original, keys: candidates)
            for key in candidates { representedKeys.insert(key.publicKey) }
            let internalBranch = records.contains {
                $0.type == "activeinternalspk" && $0.value == record.suffix
            }
            sources.append(try .init(descriptor: converted, rangeStart: start, rangeEnd: end,
                                     nextIndex: next, internalBranch: internalBranch))
        }
        // Watch-only scripts cannot be restored as a spendable private-key wallet.
        // Reject explicitly rather than silently dropping their monitored funds.
        if records.contains(where: { $0.type == "watchs" }) { throw BitcoinImportError.privateKeyRequired }
        if descriptors.isEmpty {
            for record in records where record.type == "hdchain" {
                sources.append(contentsOf: try legacyHD(record.value, keys: keys))
            }
            for record in records where record.type == "cscript" {
                var value = BitcoinBackupBytes(record.value)
                let script = try value.vector()
                // Legacy Core's ordinary nested SegWit redeem scripts are recreated
                // from their keys. Other scripts require a different signing policy.
                guard value.remaining == 0, script.count == 22, script.prefix(2) == Data([0, 20]),
                      keys.contains(where: { Hash.sha256RIPEMD(data: $0.publicKey) == script.suffix(20) }) else {
                    throw BitcoinImportError.unsupportedScript
                }
            }
        }
        for key in keys where !representedKeys.contains(key.publicKey) {
            guard key.descriptorID == nil else { throw BitcoinImportError.incompleteBackup }
            sources.append(contentsOf: try BitcoinImportedWalletMaterial.fixed(.init(
                key: key.privateKey, compressed: key.publicKey.count == 33
            )))
        }
        return try BitcoinImportedWalletMaterial(sources: sources).validated()
    }

    private static func privateDescriptor(_ text: String, keys: [StoredKey]) throws -> BitcoinPrivateDescriptor {
        var body = try BitcoinDescriptorChecksum.validatedBody(text)
        // Replace public extended nodes using the matching recorded SEC key.
        // This retains depth, parent fingerprint, child number and chain code.
        let expression = try NSRegularExpression(pattern: "xpub[1-9A-HJ-NP-Za-km-z]+")
        let matches = expression.matches(in: body, range: NSRange(body.startIndex..., in: body)).reversed()
        for match in matches {
            guard let range = Range(match.range, in: body),
                  let payload = Base58.decode(string: String(body[range])), payload.count == 78,
                  payload.prefix(4) == Data([0x04, 0x88, 0xb2, 0x1e]),
                  let key = keys.first(where: { $0.publicKey == Data(payload.suffix(33)) }) else {
                throw BitcoinImportError.privateKeyRequired
            }
            let node = BitcoinImportPrivateNode(privateKey: key.privateKey, chainCode: Data(payload[13..<45]),
                depth: payload[4], parentFingerprint: Data(payload[5..<9]),
                childNumber: BitcoinImportPrivateNode.integer(Data(payload[9..<13])))
            body.replaceSubrange(range, with: try node.serialized())
        }
        // Fixed public-key descriptors also keep their exact compression policy.
        for key in keys {
            let wif = try BitcoinImportKeyEncoding.encode(.init(key: key.privateKey, compressed: key.publicKey.count == 33))
            body = body.replacingOccurrences(of: key.publicKey.hexString, with: wif)
            if body.hasPrefix("tr("), key.publicKey.count == 33 {
                body = body.replacingOccurrences(of: Data(key.publicKey.dropFirst()).hexString, with: wif)
            }
        }
        return try BitcoinPrivateDescriptor(body)
    }

    private static func legacyHD(_ data: Data, keys: [StoredKey]) throws -> [BitcoinImportedWalletMaterial.Source] {
        var value = BitcoinBackupBytes(data)
        let version = try value.integer(4)
        guard version == 1 || version == 2 else { throw BitcoinImportError.unsupportedDatabase }
        let external = Int(try value.integer(4))
        let seedID = try value.take(20)
        let internalCount = version == 2 ? Int(try value.integer(4)) : 0
        guard value.remaining == 0,
              let seed = keys.first(where: { Hash.sha256RIPEMD(data: $0.publicKey) == seedID }) else {
            throw BitcoinImportError.incompleteBackup
        }
        return try legacySeedSources(seed.privateKey, external: external, internalCount: internalCount, split: version == 2)
    }

    static func legacySeedSources(_ seed: Data, external: Int = 0, internalCount: Int = 0,
                                  split: Bool = true) throws -> [BitcoinImportedWalletMaterial.Source] {
        let digest = Data(HMAC<SHA512>.authenticationCode(for: seed, using: SymmetricKey(data: Data("Bitcoin seed".utf8))))
        let root = BitcoinImportPrivateNode(privateKey: Data(digest.prefix(32)), chainCode: Data(digest.suffix(32)),
                                           depth: 0, parentFingerprint: Data(repeating: 0, count: 4), childNumber: 0)
        let encoded = try root.serialized()
        var sources: [BitcoinImportedWalletMaterial.Source] = []
        for branch in 0..<(split ? 2 : 1) {
            let key = "\(encoded)/0'/\(branch)'/*'"
            for descriptor in ["pkh(\(key))", "wpkh(\(key))", "sh(wpkh(\(key)))"] {
                let count = branch == 0 ? external : internalCount
                sources.append(try .init(descriptor: BitcoinPrivateDescriptor(descriptor),
                                         rangeEnd: max(20, count), nextIndex: count, internalBranch: branch == 1))
            }
        }
        return sources
    }
}
