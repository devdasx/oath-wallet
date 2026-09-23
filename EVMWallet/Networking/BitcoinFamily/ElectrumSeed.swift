import CryptoKit
import Foundation
import P256K
import WalletCore

enum ElectrumSeedKind: String, Codable, Sendable {
    case standard
    case segwit

    var addressType: BitcoinHDAddressType {
        switch self {
        case .standard: .bip44
        case .segwit: .bip84
        }
    }

    var accountPath: String {
        switch self {
        case .standard: "m"
        case .segwit: "m/0'"
        }
    }

    fileprivate var publicVersion: UInt32 {
        switch self {
        case .standard: 0x0488_B21E
        case .segwit: 0x04B2_4746
        }
    }
}

enum ElectrumSeedError: Error, Equatable {
    case invalidSeed
    case unsupportedTwoFactorSeed
    case invalidPassphrase
    case invalidChild
    case invalidExtendedPublicKey
}

enum ElectrumSeed {
    static func kind(of phrase: String) -> ElectrumSeedKind? {
        let version = versionDigest(for: phrase)
        if version.hasPrefix("100") { return .segwit }
        if version.hasPrefix("01") { return .standard }
        return nil
    }

    static func validatesAsUnsupportedTwoFactor(_ phrase: String) -> Bool {
        let version = versionDigest(for: phrase)
        return version.hasPrefix("101") || version.hasPrefix("102")
    }

    static func normalized(_ value: String) -> String {
        let decomposed = value.decomposedStringWithCompatibilityMapping
            .lowercased()
        let scalars = decomposed.unicodeScalars.filter {
            CharacterSet.nonBaseCharacters.contains($0) == false
        }
        let words = String(scalars)
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        guard !words.isEmpty else { return "" }

        var result = words.joined(separator: " ")
        let characters = Array(result)
        if characters.count > 1 {
            result = String(characters.enumerated().compactMap {
                index, character -> Character? in
                guard character.isWhitespace,
                      index > 0,
                      index + 1 < characters.count,
                      isCJK(characters[index - 1]),
                      isCJK(characters[index + 1]) else {
                    return character
                }
                return nil
            })
        }
        return result
    }

    static func seed(
        phrase: String,
        passphrase: String
    ) throws -> Data {
        let normalizedPhrase = normalized(phrase)
        guard !normalizedPhrase.isEmpty else {
            throw ElectrumSeedError.invalidSeed
        }
        let normalizedPassphrase = normalized(passphrase)
        let salt = Data(
            ("electrum" + normalizedPassphrase).utf8
        )
        return pbkdf2SHA512(
            password: Data(normalizedPhrase.utf8),
            salt: salt,
            iterations: 2_048,
            outputByteCount: 64
        )
    }

    private static func versionDigest(for phrase: String) -> String {
        let authentication = HMAC<SHA512>.authenticationCode(
            for: Data(normalized(phrase).utf8),
            using: SymmetricKey(data: Data("Seed version".utf8))
        )
        return authentication.map { String(format: "%02x", $0) }
            .joined()
    }

    private static func pbkdf2SHA512(
        password: Data,
        salt: Data,
        iterations: Int,
        outputByteCount: Int
    ) -> Data {
        precondition(iterations > 0 && outputByteCount > 0)
        let blockByteCount = SHA512.Digest.byteCount
        let blockCount = (outputByteCount + blockByteCount - 1)
            / blockByteCount
        let key = SymmetricKey(data: password)
        var output = Data()
        output.reserveCapacity(blockCount * blockByteCount)

        for blockIndex in 1...blockCount {
            var block = salt
            var bigEndian = UInt32(blockIndex).bigEndian
            Swift.withUnsafeBytes(of: &bigEndian) {
                block.append(contentsOf: $0)
            }
            var digest = Data(
                HMAC<SHA512>.authenticationCode(for: block, using: key)
            )
            var accumulated = [UInt8](digest)
            if iterations > 1 {
                for _ in 2...iterations {
                    digest = Data(
                        HMAC<SHA512>.authenticationCode(
                            for: digest,
                            using: key
                        )
                    )
                    for index in accumulated.indices {
                        accumulated[index] ^= digest[index]
                    }
                }
            }
            output.append(contentsOf: accumulated)
        }
        return Data(output.prefix(outputByteCount))
    }

    private static func isCJK(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 0x4E00...0x9FFF,
                 0x3400...0x4DBF,
                 0x20000...0x2A6DF,
                 0x2A700...0x2B73F,
                 0x2B740...0x2B81F,
                 0xF900...0xFAFF,
                 0x2F800...0x2FA1D,
                 0x3190...0x319F,
                 0x2E80...0x2EFF,
                 0x31C0...0x31EF,
                 0x2F00...0x2FDF,
                 0x2FF0...0x2FFF,
                 0x3100...0x312F,
                 0x31A0...0x31BF,
                 0x3040...0x309F,
                 0x30A0...0x30FF,
                 0x31F0...0x31FF,
                 0xAC00...0xD7AF,
                 0x1100...0x11FF,
                 0x3130...0x318F,
                 0xA960...0xA97F,
                 0xD7B0...0xD7FF:
                true
            default:
                false
            }
        }
    }
}

struct ElectrumBIP32Node: Sendable {
    let privateKey: Data?
    let publicKey: Data
    let chainCode: Data
    let depth: UInt8
    let parentFingerprint: UInt32
    let childNumber: UInt32

    static func master(seed: Data) throws -> Self {
        let digest = Data(
            HMAC<SHA512>.authenticationCode(
                for: seed,
                using: SymmetricKey(data: Data("Bitcoin seed".utf8))
            )
        )
        let privateKey = Data(digest.prefix(32))
        guard let key = try? P256K.Signing.PrivateKey(
            dataRepresentation: privateKey
        ) else {
            throw ElectrumSeedError.invalidSeed
        }
        return Self(
            privateKey: privateKey,
            publicKey: key.publicKey.dataRepresentation,
            chainCode: Data(digest.suffix(32)),
            depth: 0,
            parentFingerprint: 0,
            childNumber: 0
        )
    }

    static func extendedPublicKey(_ encoded: String) throws -> Self {
        let payload = try checkedPayload(encoded)
        guard payload.count == 78 else {
            throw ElectrumSeedError.invalidExtendedPublicKey
        }
        let depth = payload[4]
        let parentFingerprint = uint32(payload[5..<9])
        let childNumber = uint32(payload[9..<13])
        let chainCode = Data(payload[13..<45])
        let publicKey = Data(payload[45..<78])
        guard publicKey.count == 33,
              (try? P256K.Signing.PublicKey(
                dataRepresentation: publicKey,
                format: .compressed
              )) != nil else {
            throw ElectrumSeedError.invalidExtendedPublicKey
        }
        return Self(
            privateKey: nil,
            publicKey: publicKey,
            chainCode: chainCode,
            depth: depth,
            parentFingerprint: parentFingerprint,
            childNumber: childNumber
        )
    }

    func derived(at index: UInt32) throws -> Self {
        guard depth < UInt8.max else {
            throw ElectrumSeedError.invalidChild
        }
        let hardened = index >= 0x8000_0000
        var input = Data()
        if hardened {
            guard let privateKey else {
                throw ElectrumSeedError.invalidChild
            }
            input.append(0)
            input.append(privateKey)
        } else {
            input.append(publicKey)
        }
        var bigEndianIndex = index.bigEndian
        Swift.withUnsafeBytes(of: &bigEndianIndex) {
            input.append(contentsOf: $0)
        }
        let digest = Data(
            HMAC<SHA512>.authenticationCode(
                for: input,
                using: SymmetricKey(data: chainCode)
            )
        )
        let tweak = Data(digest.prefix(32))
        let childPrivate: Data?
        let childPublic: Data
        do {
            if let privateKey {
                let key = try P256K.Signing.PrivateKey(
                    dataRepresentation: privateKey
                ).add([UInt8](tweak))
                childPrivate = key.dataRepresentation
                childPublic = key.publicKey.dataRepresentation
            } else {
                let key = try P256K.Signing.PublicKey(
                    dataRepresentation: publicKey,
                    format: .compressed
                ).add([UInt8](tweak), format: .compressed)
                childPrivate = nil
                childPublic = key.dataRepresentation
            }
        } catch {
            throw ElectrumSeedError.invalidChild
        }
        return Self(
            privateKey: childPrivate,
            publicKey: childPublic,
            chainCode: Data(digest.suffix(32)),
            depth: depth + 1,
            parentFingerprint: fingerprint,
            childNumber: index
        )
    }

    func serializedPublicKey(version: UInt32) -> String {
        var payload = Data()
        payload.appendUInt32(version)
        payload.append(depth)
        payload.appendUInt32(parentFingerprint)
        payload.appendUInt32(childNumber)
        payload.append(chainCode)
        payload.append(publicKey)
        return Base58.encode(data: payload)
    }

    var fingerprint: UInt32 {
        Self.uint32(Hash.sha256RIPEMD(data: publicKey).prefix(4))
    }

    private static func checkedPayload(_ encoded: String) throws -> Data {
        if let decoded = Base58.decode(string: encoded),
           decoded.count == 78 {
            return decoded
        }
        guard let decoded = Base58.decodeNoCheck(string: encoded),
              decoded.count == 82 else {
            throw ElectrumSeedError.invalidExtendedPublicKey
        }
        let payload = Data(decoded.prefix(78))
        guard Hash.sha256SHA256(data: payload).prefix(4)
            .elementsEqual(decoded.suffix(4)) else {
            throw ElectrumSeedError.invalidExtendedPublicKey
        }
        return payload
    }

    private static func uint32<C: Collection>(_ bytes: C) -> UInt32
    where C.Element == UInt8 {
        bytes.reduce(0) { ($0 << 8) | UInt32($1) }
    }
}

struct ElectrumSeedDerivationService: Sendable {
    func accountDescriptor(
        credential: WalletRecoveryCredential
    ) throws -> BitcoinHDAccountDescriptor {
        guard let kind = credential.electrumKind else {
            throw BitcoinHDDerivationError.invalidWallet
        }
        var node = try rootNode(credential: credential)
        if kind == .segwit {
            node = try node.derived(at: 0x8000_0000)
        }
        return BitcoinHDAccountDescriptor(
            addressType: kind.addressType,
            accountIndex: 0,
            accountPath: kind.accountPath,
            extendedPublicKey: node.serializedPublicKey(
                version: kind.publicVersion
            )
        )
    }

    func deriveAddress(
        descriptor: BitcoinHDAccountDescriptor,
        branch: BitcoinHDAddressBranch,
        index: Int
    ) throws -> BitcoinHDDerivedAddress {
        guard index >= 0,
              index <= Int(UInt32.max),
              descriptor.isElectrum else {
            throw BitcoinHDDerivationError.invalidChild
        }
        let account = try ElectrumBIP32Node.extendedPublicKey(
            descriptor.extendedPublicKey
        )
        let branchNode = try account.derived(at: UInt32(branch.rawValue))
        let child = try branchNode.derived(at: UInt32(index))
        guard let publicKey = PublicKey(
            data: child.publicKey,
            type: .secp256k1
        ) else {
            throw BitcoinHDDerivationError.invalidChild
        }
        return try BitcoinHDDerivationService().derivedAddress(
            addressType: descriptor.addressType,
            branch: branch,
            index: index,
            publicKey: publicKey,
            explicitDerivationPath: descriptor.derivationPath(
                branch: branch,
                index: index
            )
        )
    }

    func privateKey(
        credential: WalletRecoveryCredential,
        addressType: BitcoinHDAddressType,
        branch: BitcoinHDAddressBranch,
        index: Int
    ) throws -> PrivateKey {
        guard let kind = credential.electrumKind,
              kind.addressType == addressType,
              index >= 0,
              index <= Int(UInt32.max) else {
            throw BitcoinHDDerivationError.invalidChild
        }
        var node = try rootNode(credential: credential)
        if kind == .segwit {
            node = try node.derived(at: 0x8000_0000)
        }
        node = try node.derived(at: UInt32(branch.rawValue))
        node = try node.derived(at: UInt32(index))
        guard let privateKey = node.privateKey,
              let result = PrivateKey(data: privateKey) else {
            throw BitcoinHDDerivationError.invalidChild
        }
        return result
    }

    private func rootNode(
        credential: WalletRecoveryCredential
    ) throws -> ElectrumBIP32Node {
        let seed = try ElectrumSeed.seed(
            phrase: credential.mnemonic,
            passphrase: credential.passphrase
        )
        return try ElectrumBIP32Node.master(seed: seed)
    }
}

extension BitcoinHDAccountDescriptor {
    var isElectrum: Bool {
        switch addressType {
        case .bip44: accountPath == ElectrumSeedKind.standard.accountPath
        case .bip84: accountPath == ElectrumSeedKind.segwit.accountPath
        case .bip49, .bip86, .brdLegacy, .brdSegwit: false
        }
    }

    func derivationPath(
        branch: BitcoinHDAddressBranch,
        index: Int
    ) -> String {
        "\(accountPath)/\(branch.rawValue)/\(index)"
    }

    static func isValidAccountPath(
        _ path: String,
        for addressType: BitcoinHDAddressType
    ) -> Bool {
        path == addressType.accountPath
            || (addressType == .bip44
                && path == ElectrumSeedKind.standard.accountPath)
            || (addressType == .bip84
                && path == ElectrumSeedKind.segwit.accountPath)
    }
}

private extension Data {
    mutating func appendUInt32(_ value: UInt32) {
        var bigEndian = value.bigEndian
        Swift.withUnsafeBytes(of: &bigEndian) {
            append(contentsOf: $0)
        }
    }
}
