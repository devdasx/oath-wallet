import Foundation
import WalletCore

/// Secret restoration material. Encoded only for the Keychain vault, encrypted
/// backups, and server-encrypted secret drafts, never for WalletDatabase rows.
struct BitcoinImportedWalletMaterial: Codable, Equatable, Sendable {
    static let accountMarker = "bitcoin-imported-collection:v1"
    var sources: [Source]

    struct Source: Codable, Equatable, Sendable {
        let descriptor: BitcoinPrivateDescriptor
        let rangeStart: Int
        let rangeEnd: Int
        let nextIndex: Int
        let internalBranch: Bool
        let discoveryGap: Int?

        init(descriptor: BitcoinPrivateDescriptor, rangeStart: Int = 0, rangeEnd: Int? = nil,
             nextIndex: Int = 0, internalBranch: Bool = false, discoveryGap: Int? = nil) throws {
            guard discoveryGap == nil || (1...100_000).contains(discoveryGap!) else { throw BitcoinImportError.invalidFile }
            self.discoveryGap = discoveryGap
            let end = rangeEnd ?? (descriptor.isRanged ? 20 : 1)
            guard rangeStart >= 0, end > rangeStart, end <= 0x8000_0000,
                  nextIndex >= rangeStart, nextIndex <= end,
                  descriptor.isRanged || (rangeStart == 0 && end == 1 && nextIndex <= 1) else {
                throw BitcoinImportError.invalidDescriptor
            }
            self.descriptor = descriptor; self.rangeStart = rangeStart; self.rangeEnd = end
            self.nextIndex = nextIndex; self.internalBranch = internalBranch
        }
    }

    func validated() throws -> Self {
        guard !sources.isEmpty, sources.count <= 100_000 else { throw BitcoinImportError.noPrivateKeys }
        for source in sources {
            try Task.checkCancellation()
            try source.descriptor.validate()
            _ = try Source(descriptor: source.descriptor, rangeStart: source.rangeStart,
                           rangeEnd: source.rangeEnd, nextIndex: source.nextIndex,
                           internalBranch: source.internalBranch, discoveryGap: source.discoveryGap)
            for branch in 0..<source.descriptor.branchCount {
                _ = try source.descriptor.address(branch: branch, index: source.rangeStart)
            }
        }
        return self
    }

    func primaryAddress() throws -> BitcoinHDDerivedAddress {
        guard let index = sources.firstIndex(where: { !$0.internalBranch }) ?? sources.indices.first else {
            throw BitcoinImportError.noPrivateKeys
        }
        let source = sources[index]
        return try source.descriptor.address(index: source.rangeStart, sourceID: String(index))
    }

    func importDraft() throws -> WalletImportDraft {
        let material = try validated()
        let primary = try material.primaryAddress()
        return WalletImportDraft(secret: .bitcoinImportedWallet(material), address: primary.address,
            normalizedAddress: primary.address.lowercased(), derivationPath: Self.accountMarker,
            publicKey: primary.publicKey.hexString)
    }

    func bitcoinFamilyChain() throws -> BitcoinFamilyChain {
        let primary = try primaryAddress()
        if BitcoinFamilyChain.bitcoin.coin.validate(address: primary.address) {
            return .bitcoin
        }
        if BitcoinFamilyChain.bitcoinCash.coin.validate(address: primary.address) {
            return .bitcoinCash
        }
        if BitcoinFamilyChain.litecoin.coin.validate(address: primary.address) {
            return .litecoin
        }
        if BitcoinFamilyChain.dogecoin.coin.validate(address: primary.address) {
            return .dogecoin
        }
        throw BitcoinImportError.invalidFile
    }

    func encoded() throws -> Data { try JSONEncoder().encode(validated()) }
    static func decode(_ data: Data) throws -> Self {
        guard data.count <= 64 * 1024 * 1024 else { throw BitcoinImportError.fileTooLarge }
        return try JSONDecoder().decode(ImportDocument.self, from: data).material.validated()
    }

    /// Accept the original material and the versioned import document. An
    /// unrecognized envelope must never fall back to interpreting its inner keys.
    /// `encoded()` deliberately keeps the existing Keychain/backup representation.
    private struct ImportDocument: Decodable {
        let material: BitcoinImportedWalletMaterial

        private enum CodingKeys: String, CodingKey {
            case format, version, material, sources
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if container.contains(.format) || container.contains(.version) || container.contains(.material) {
                guard try container.decode(String.self, forKey: .format) == "bitcoinImportedWallet",
                      try container.decode(Int.self, forKey: .version) == 1,
                      !container.contains(.sources) else { throw BitcoinImportError.invalidFile }
                material = try container.decode(BitcoinImportedWalletMaterial.self, forKey: .material)
            } else {
                material = try BitcoinImportedWalletMaterial(from: decoder)
            }
        }
    }

    func privateKey(path: String) throws -> Data {
        let parts = path.split(separator: ":")
        guard parts.count == 4, parts[0] == "bitcoin-import", let source = Int(parts[1]),
              sources.indices.contains(source), let branch = Int(parts[2]), let index = Int(parts[3]) else {
            throw BitcoinImportError.invalidDescriptor
        }
        return try sources[source].descriptor.privateKey(branch: branch, index: index)
    }

    static func fixed(_ key: BitcoinImportKeyEncoding.Key, includingRawTaproot: Bool = false) throws -> [Source] {
        guard !includingRawTaproot || key.compressed else { throw BitcoinImportError.invalidKey }
        let wif = try BitcoinImportKeyEncoding.encode(key)
        var formats = key.compressed ? ["wpkh(\(wif))", "pkh(\(wif))", "sh(wpkh(\(wif)))", "tr(\(wif))"] : ["pkh(\(wif))"]
        if includingRawTaproot { formats.append("rawtr(\(wif))") }
        return try formats.map { try Source(descriptor: BitcoinPrivateDescriptor($0)) }
    }
}
