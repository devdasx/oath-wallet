import Foundation
import WalletCore

/// Single-key output descriptors. Keeps the source node and derivation branches;
/// a ranged descriptor is never converted into only its first private key.
struct BitcoinPrivateDescriptor: Codable, Equatable, Sendable {
    enum Script: String, Codable, Sendable {
        case pkh, wpkh, shWpkh, tr, rawtr
        var addressType: BitcoinHDAddressType {
            switch self {
            case .pkh: .bip44
            case .wpkh: .bip84
            case .shWpkh: .bip49
            case .tr, .rawtr: .bip86
            }
        }
    }
    enum Component: Codable, Equatable, Sendable {
        case child(UInt32)
        case alternatives([UInt32])
        case wildcard(hardened: Bool)
    }
    let script: Script
    let key: Data
    let compressed: Bool
    let node: BitcoinImportPrivateNode?
    let origin: String?
    let path: [Component]
    let electrumOldBranch: Int?

    var isRanged: Bool { electrumOldBranch != nil || path.contains { if case .wildcard = $0 { return true }; return false } }
    var branchCount: Int {
        path.compactMap { if case let .alternatives(values) = $0 { return values.count }; return nil }.first ?? 1
    }

    init(_ encoded: String) throws {
        electrumOldBranch = nil
        let body = try BitcoinDescriptorChecksum.validatedBody(encoded.trimmingCharacters(in: .whitespacesAndNewlines))
        var expression: String
        if body.hasPrefix("sh(wpkh("), body.hasSuffix("))") {
            script = .shWpkh; expression = String(body.dropFirst(8).dropLast(2))
        } else if body.hasPrefix("pkh("), body.hasSuffix(")") {
            script = .pkh; expression = String(body.dropFirst(4).dropLast())
        } else if body.hasPrefix("wpkh("), body.hasSuffix(")") {
            script = .wpkh; expression = String(body.dropFirst(5).dropLast())
        } else if body.hasPrefix("rawtr("), body.hasSuffix(")") {
            script = .rawtr; expression = String(body.dropFirst(6).dropLast())
        } else if body.hasPrefix("tr("), body.hasSuffix(")") {
            script = .tr; expression = String(body.dropFirst(3).dropLast())
        } else { throw BitcoinImportError.unsupportedScript }
        guard !expression.contains(where: { "(),{}".contains($0) || $0.isWhitespace }) else {
            throw BitcoinImportError.unsupportedScript
        }
        if expression.hasPrefix("[") {
            guard let end = expression.firstIndex(of: "]") else { throw BitcoinImportError.invalidDescriptor }
            let text = String(expression[expression.index(after: expression.startIndex)..<end])
            let parts = text.split(separator: "/", omittingEmptySubsequences: false)
            guard let fingerprint = parts.first, fingerprint.utf8.count == 8,
                  fingerprint.utf8.allSatisfy({ Self.hex.contains($0) }) else { throw BitcoinImportError.invalidDescriptor }
            for part in parts.dropFirst() { _ = try Self.child(String(part)) }
            origin = text
            expression = String(expression[expression.index(after: end)...])
        } else { origin = nil }
        let parts = expression.split(separator: "/", omittingEmptySubsequences: false)
        guard let first = parts.first, !first.isEmpty else { throw BitcoinImportError.invalidDescriptor }
        let encodedKey = String(first)
        if encodedKey.hasPrefix("xprv") || encodedKey.hasPrefix("yprv") || encodedKey.hasPrefix("zprv") {
            let parsed = try BitcoinImportPrivateNode(encoded: encodedKey)
            node = parsed; key = parsed.privateKey; compressed = true
        } else {
            let parsed = try BitcoinImportKeyEncoding.wif(encodedKey)
            node = nil; key = parsed.key; compressed = parsed.compressed
        }
        guard compressed || script == .pkh else { throw BitcoinImportError.invalidDescriptor }
        guard parts.count == 1 || node != nil else { throw BitcoinImportError.invalidDescriptor }
        var components: [Component] = []
        var alternativesCount: Int?
        for (offset, part) in parts.dropFirst().enumerated() {
            let text = String(part)
            if text == "*" || text == "*'" || text == "*h" {
                guard offset == parts.count - 2 else { throw BitcoinImportError.invalidDescriptor }
                components.append(.wildcard(hardened: text != "*"))
            } else if text.hasPrefix("<"), text.hasSuffix(">") {
                let values = try text.dropFirst().dropLast().split(separator: ";", omittingEmptySubsequences: false)
                    .map { try Self.child(String($0)) }
                guard (2...16).contains(values.count), Set(values).count == values.count,
                      alternativesCount == nil || alternativesCount == values.count else {
                    throw BitcoinImportError.invalidDescriptor
                }
                alternativesCount = values.count
                components.append(.alternatives(values))
            } else { components.append(.child(try Self.child(text))) }
        }
        path = components
        guard Int(node?.depth ?? 0) + path.count <= 255 else { throw BitcoinImportError.invalidDescriptor }
    }

    init(electrumOldKey: Data, branch: Int) throws {
        script = .pkh; key = electrumOldKey; compressed = false
        node = nil; origin = nil; path = []; electrumOldBranch = branch
        try validate()
    }

    func validate() throws {
        if let branch = electrumOldBranch {
            guard (0...1).contains(branch), script == .pkh, !compressed, node == nil, path.isEmpty else {
                throw BitcoinImportError.invalidDescriptor
            }
        }
        guard PrivateKey.isValid(data: key, curve: .secp256k1), compressed || script == .pkh,
              node != nil || path.isEmpty, Int(node?.depth ?? 0) + path.count <= 255 else {
            throw BitcoinImportError.invalidDescriptor
        }
        if let node { try node.validate(); guard node.privateKey == key, compressed else { throw BitcoinImportError.invalidDescriptor } }
        for (index, component) in path.enumerated() {
            switch component {
            case .child: break
            case .wildcard:
                guard index == path.count - 1 else { throw BitcoinImportError.invalidDescriptor }
            case let .alternatives(values):
                guard (2...16).contains(values.count), values.count == branchCount,
                      Set(values).count == values.count else { throw BitcoinImportError.invalidDescriptor }
            }
        }
    }

    func privateKey(branch: Int = 0, index: Int = 0) throws -> Data {
        try validate()
        guard (0..<branchCount).contains(branch), (0..<0x8000_0000).contains(index),
              isRanged || index == 0 else { throw BitcoinImportError.invalidDescriptor }
        if let oldBranch = electrumOldBranch {
            return try BitcoinElectrumOldDerivation.privateKey(master: key, branch: oldBranch, index: index)
        }
        guard var current = node else { return key }
        for component in path {
            let child: UInt32
            switch component {
            case let .child(value): child = value
            case let .alternatives(values): child = values[branch]
            case let .wildcard(hardened): child = UInt32(index) | (hardened ? 0x8000_0000 : 0)
            }
            current = try current.derived(at: child)
        }
        return current.privateKey
    }

    func address(branch: Int = 0, index: Int = 0, sourceID: String = "descriptor") throws -> BitcoinHDDerivedAddress {
        let bytes = try privateKey(branch: branch, index: index)
        guard PrivateKey.isValid(data: bytes, curve: .secp256k1), let key = PrivateKey(data: bytes) else {
            throw BitcoinImportError.invalidKey
        }
        if script == .rawtr {
            // rawtr contains the final output key; BIP86's TapTweak must not be applied.
            let publicKey = key.getPublicKeySecp256k1(compressed: true).data
            let scriptPubKey = Data([0x51, 0x20]) + publicKey.dropFirst()
            guard let address = BitcoinFamilyScriptAddress.address(from: scriptPubKey, chain: .bitcoin),
                  BitcoinScript.lockScriptForAddress(address: address, coin: .bitcoin).data == scriptPubKey else {
                throw BitcoinImportError.invalidDescriptor
            }
            return BitcoinHDDerivedAddress(
                addressType: .bip86, branch: branch == 0 ? .external : .change,
                index: index, derivationPath: "bitcoin-import:\(sourceID):\(branch):\(index)",
                address: address, publicKey: publicKey, scriptPubKey: scriptPubKey,
                scriptHash: Data(Hash.sha256(data: scriptPubKey).reversed()).hexString
            )
        }
        return try BitcoinHDDerivationService().derivedAddress(
            addressType: script.addressType, branch: branch == 0 ? .external : .change,
            index: index, publicKey: key.getPublicKeySecp256k1(compressed: compressed),
            explicitDerivationPath: "bitcoin-import:\(sourceID):\(branch):\(index)"
        )
    }

    private static let hex = Set("0123456789abcdefABCDEF".utf8)
    private static func child(_ text: String) throws -> UInt32 {
        let hardened = text.hasSuffix("'") || text.hasSuffix("h")
        let value = hardened ? String(text.dropLast()) : text
        guard !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }),
              let index = UInt32(value), index < 0x8000_0000 else { throw BitcoinImportError.invalidDescriptor }
        return index | (hardened ? 0x8000_0000 : 0)
    }
}
