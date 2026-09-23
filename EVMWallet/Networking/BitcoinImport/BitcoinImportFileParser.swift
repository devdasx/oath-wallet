import Foundation
import WalletCore

/// Local, all-or-nothing file parsing. Never searches arbitrary binary data for
/// apparent keys, and never forwards file contents to a provider or draft capture.
actor BitcoinImportFileParser {
    static let shared = BitcoinImportFileParser()
    static let maximumBytes = 64 * 1024 * 1024

    nonisolated static func isCollectionInput(_ text: String) -> Bool {
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return input.hasPrefix("{") || input.hasPrefix("[") || input.contains("(") || input.contains(":")
    }

    func byteCount(url: URL) -> Int? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
    }

    func read(url: URL, password: String? = nil) throws -> WalletImportDraft {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        var coordinationError: NSError?
        var snapshot: Result<Data, any Error>?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { coordinatedURL in
            snapshot = Result {
                let size = try coordinatedURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                guard size.isRegularFile == true, let count = size.fileSize, count <= Self.maximumBytes else {
                    throw BitcoinImportError.fileTooLarge
                }
                // Own an immutable in-memory snapshot. A provider replacing a
                // mapped file while it is decrypted must not invalidate its pages.
                return try Data(contentsOf: coordinatedURL)
            }
        }
        if let coordinationError { throw coordinationError }
        guard let snapshot else { throw BitcoinImportError.invalidFile }
        let data = try snapshot.get()
        return try parse(data, password: password).importDraft()
    }

    func parse(_ data: Data, password: String? = nil) throws -> BitcoinImportedWalletMaterial {
        guard !data.isEmpty, data.count <= Self.maximumBytes else { throw BitcoinImportError.fileTooLarge }
        try Task.checkCancellation()
        if data.starts(with: Data("SQLite format 3\0".utf8)) || data.count >= 512 && (
            (try? BitcoinBackupBytes(data).integer(at: 12, count: 4)) == 0x00053162 ||
            (try? BitcoinBackupBytes(data).integer(at: 12, count: 4)) == 0x62310500
        ) { return try BitcoinCoreBackupImporter.parse(data, password: password) }
        guard let text = String(data: data, encoding: .utf8), !text.contains("\0") else {
            throw BitcoinImportError.invalidFile
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let plaintext = try BitcoinElectrumFileCrypto.decryptStorage(trimmed, password: password) {
            guard let object = try BitcoinElectrumJSON.read(plaintext) else { throw BitcoinImportError.invalidFile }
            return try BitcoinElectrumFileImporter.parse(object, password: password)
        }
        if let object = try BitcoinElectrumJSON.read(data) {
            return try BitcoinElectrumFileImporter.parse(object, password: password)
        }
        if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
            return try parseJSON(data, password: password)
        }
        let lines = trimmed.components(separatedBy: .newlines)
        var sources: [BitcoinImportedWalletMaterial.Source] = []
        var csvKeyColumn: Int?
        var legacySeeds: [Data] = []
        var legacyScripts: [Data] = []
        var legacyCounters = [0, 0]
        for line in lines {
            try Task.checkCancellation()
            let line = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let fields = try csvFields(line)
            if let column = csvKeyColumn {
                guard fields.indices.contains(column) else { throw BitcoinImportError.invalidFile }
                sources += try Self.sources(for: fields[column], password: password)
            } else if fields.count > 1 {
                let names = fields.map { $0.lowercased().replacingOccurrences(of: " ", with: "_") }
                guard let column = names.firstIndex(where: { ["private_key", "privatekey", "wif", "descriptor", "key"].contains($0) }) else {
                    throw BitcoinImportError.invalidFile
                }
                csvKeyColumn = column
            } else {
                // Core dumpwallet: WIF timestamp metadata... # addr=...
                let value = line.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
                let metadata = line.split(whereSeparator: \.isWhitespace)
                if metadata.contains("script=1") {
                    guard let script = Data(hexString: value), script.count == 22, script.prefix(2) == Data([0, 20]) else {
                        throw BitcoinImportError.unsupportedScript
                    }
                    legacyScripts.append(script)
                    continue
                }
                sources += try Self.sources(for: value, password: password)
                if line.contains("hdseed=1") {
                    legacySeeds.append(try BitcoinImportKeyEncoding.wif(value).key)
                }
                if let marker = line.range(of: "hdkeypath=m/0'/") {
                    let suffix = line[marker.upperBound...].split(whereSeparator: \.isWhitespace).first ?? ""
                    let parts = suffix.split(separator: "/")
                    if parts.count == 2, let branch = Int(parts[0].replacingOccurrences(of: "'", with: "")),
                       (0...1).contains(branch), let index = Int(parts[1].replacingOccurrences(of: "'", with: "")),
                       (0..<0x8000_0000).contains(index) {
                        legacyCounters[branch] = max(legacyCounters[branch], index + 1)
                    }
                }
            }
            guard sources.count <= 100_000 else { throw BitcoinImportError.fileTooLarge }
        }
        if !legacyScripts.isEmpty {
            let keyHashes = try Set(sources.map { source -> Data in
                guard let key = PrivateKey(data: source.descriptor.key) else { throw BitcoinImportError.invalidKey }
                return Hash.sha256RIPEMD(data: key.getPublicKeySecp256k1(compressed: source.descriptor.compressed).data)
            })
            guard legacyScripts.allSatisfy({ keyHashes.contains(Data($0.suffix(20))) }) else {
                throw BitcoinImportError.unsupportedScript
            }
        }
        for seed in legacySeeds {
            sources += try BitcoinCoreBackupImporter.legacySeedSources(seed, external: legacyCounters[0], internalCount: legacyCounters[1])
        }
        return try BitcoinImportedWalletMaterial(sources: sources).validated()
    }

    static func sources(for text: String, password: String?) throws -> [BitcoinImportedWalletMaterial.Source] {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.contains(":") {
            return [try .init(descriptor: BitcoinImportKeyEncoding.electrumDescriptor(text))]
        }
        if text.contains("(") {
            return [try .init(descriptor: BitcoinPrivateDescriptor(text))]
        }
        if text.hasPrefix("xprv") || text.hasPrefix("yprv") || text.hasPrefix("zprv") {
            let node = try BitcoinImportPrivateNode(encoded: text)
            let root = try node.serialized()
            let purpose = text.hasPrefix("zprv") ? 84 : (text.hasPrefix("yprv") ? 49 : 44)
            let path: String
            switch node.depth {
            case 0: path = "\(purpose)'/0'/0'/"
            case 3: path = ""
            default: throw BitcoinImportError.invalidDescriptor
            }
            return try [0, 1].map { branch in
                let key = "\(root)/\(path)\(branch)/*"
                let desc = purpose == 84 ? "wpkh(\(key))" : (purpose == 49 ? "sh(wpkh(\(key)))" : "pkh(\(key))")
                return try .init(descriptor: BitcoinPrivateDescriptor(desc), internalBranch: branch == 1)
            }
        }
        let draft: WalletImportDraft
        if BitcoinBIP38.recognizes(text, network: .bitcoin) {
            guard let password else { throw BitcoinImportError.passwordRequired }
            do { draft = try BitcoinBIP38.decrypt(text, password: password) }
            catch BitcoinBIP38Error.incorrectPassword { throw BitcoinImportError.incorrectPassword }
        } else { draft = try PrivateKeyImportService.importKey(text, network: .bitcoin) }
        switch draft.secret {
        case let .privateKey(key, _, format):
            return try BitcoinImportedWalletMaterial.fixed(.init(key: key, compressed: format != .wifUncompressed))
        case let .bitcoinImportedWallet(material):
            return try material.validated().sources
        default:
            throw BitcoinImportError.invalidKey
        }
    }

    private func parseJSON(_ data: Data, password: String?) throws -> BitcoinImportedWalletMaterial {
        let object = try JSONSerialization.jsonObject(with: data)
        if let dictionary = object as? [String: Any],
           dictionary["sources"] != nil || dictionary["format"] != nil || dictionary["material"] != nil {
            return try BitcoinImportedWalletMaterial.decode(data)
        }
        let entries: [Any]
        if let dictionary = object as? [String: Any], let descriptors = dictionary["descriptors"] as? [Any] {
            entries = descriptors
        } else if let dictionary = object as? [String: Any], let keys = dictionary["keys"] as? [Any] {
            entries = keys
        } else if let array = object as? [Any] { entries = array }
        else if let dictionary = object as? [String: Any] { entries = [dictionary] }
        else { throw BitcoinImportError.invalidFile }
        guard entries.count <= 100_000 else { throw BitcoinImportError.fileTooLarge }
        var sources: [BitcoinImportedWalletMaterial.Source] = []
        for entry in entries {
            try Task.checkCancellation()
            if let text = entry as? String { sources += try Self.sources(for: text, password: password); continue }
            guard let fields = entry as? [String: Any] else { throw BitcoinImportError.invalidFile }
            if let descriptor = (fields["desc"] ?? fields["descriptor"]) as? String {
                let parsed = try BitcoinPrivateDescriptor(descriptor)
                var start = 0
                var end: Int? = nil
                if let bounds = fields["range"] as? [Int], bounds.count == 2 {
                    start = bounds[0]
                    guard bounds[1] >= start, bounds[1] < 0x8000_0000 else { throw BitcoinImportError.invalidDescriptor }
                    end = bounds[1] + 1
                } else if let bound = fields["range"] as? Int {
                    guard (0..<0x8000_0000).contains(bound) else { throw BitcoinImportError.invalidDescriptor }
                    end = bound + 1
                } else if fields["range"] != nil { throw BitcoinImportError.invalidDescriptor }
                sources.append(try .init(descriptor: parsed, rangeStart: start, rangeEnd: end,
                    nextIndex: fields["next"] as? Int ?? fields["next_index"] as? Int ?? start,
                    internalBranch: fields["internal"] as? Bool ?? false))
            } else if let key = (fields["private_key"] ?? fields["privateKey"] ?? fields["wif"] ?? fields["key"]) as? String {
                sources += try Self.sources(for: key, password: password)
            } else { throw BitcoinImportError.invalidFile }
        }
        return try BitcoinImportedWalletMaterial(sources: sources).validated()
    }

    private func csvFields(_ line: String) throws -> [String] {
        var fields: [String] = []
        var field = ""
        var quoted = false
        var iterator = line.makeIterator()
        var character = iterator.next()
        while let current = character {
            if current == "\"" {
                if quoted {
                    let next = iterator.next()
                    if next == "\"" { field.append("\""); character = iterator.next(); continue }
                    quoted = false; character = next; continue
                }
                guard field.isEmpty else { throw BitcoinImportError.invalidFile }
                quoted = true
            } else if current == ",", !quoted { fields.append(field); field = "" }
            else { field.append(current) }
            character = iterator.next()
        }
        guard !quoted else { throw BitcoinImportError.invalidFile }
        fields.append(field)
        return fields
    }
}
