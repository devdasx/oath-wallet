import CryptoKit
import Foundation
import WalletCore

enum BitcoinExtendedPrivateKeyError: Error {
    case invalidEncoding
    case unsupportedVersion
    case invalidDepth
    case invalidChild
}

struct BitcoinExtendedPrivateKey: Sendable {
    let privateKeyData: Data
    let format: PrivateKeyImportFormat
    let derivationPath: String

    init(
        encoded: String,
        chain: BitcoinFamilyChain
    ) throws {
        let payload = try Self.decodeCheckedPayload(encoded)
        guard payload.count == 78 else {
            throw BitcoinExtendedPrivateKeyError.invalidEncoding
        }

        let versionValue = Self.uint32(payload.prefix(4))
        guard let version = HDVersion(rawValue: versionValue),
              version.isPrivate
        else {
            throw BitcoinExtendedPrivateKeyError.unsupportedVersion
        }

        let depth = Int(payload[payload.startIndex + 4])
        let childNumber = Self.uint32(
            payload[
                (payload.startIndex + 9)..<(payload.startIndex + 13)
            ]
        )
        let chainCode = Data(
            payload[
                (payload.startIndex + 13)..<(payload.startIndex + 45)
            ]
        )
        let keyData = Data(
            payload[
                (payload.startIndex + 45)..<(payload.startIndex + 78)
            ]
        )
        guard keyData.count == 33,
              keyData.first == 0,
              PrivateKey.isValid(
                data: keyData.dropFirst(),
                curve: .secp256k1
              )
        else {
            throw BitcoinExtendedPrivateKeyError.invalidEncoding
        }

        let configuration = try Self.configuration(
            version: version,
            chain: chain,
            depth: depth
        )
        guard depth <= configuration.indices.count else {
            throw BitcoinExtendedPrivateKeyError.invalidDepth
        }
        if depth > 0 {
            guard childNumber == configuration.indices[depth - 1] else {
                throw BitcoinExtendedPrivateKeyError.invalidDepth
            }
        }

        var node = Node(
            privateKey: Data(keyData.dropFirst()),
            chainCode: chainCode
        )
        for index in configuration.indices.dropFirst(depth) {
            node = try node.derived(at: index)
        }

        privateKeyData = node.privateKey
        format = configuration.format
        derivationPath = configuration.path
    }

    private struct Configuration {
        let indices: [UInt32]
        let path: String
        let format: PrivateKeyImportFormat
    }

    private struct Node {
        let privateKey: Data
        let chainCode: Data

        func derived(at index: UInt32) throws -> Node {
            var input = Data()
            if index >= Self.hardenedOffset {
                input.append(0)
                input.append(privateKey)
            } else {
                guard let key = PrivateKey(data: privateKey) else {
                    throw BitcoinExtendedPrivateKeyError.invalidChild
                }
                input.append(
                    key.getPublicKeySecp256k1(compressed: true).data
                )
            }
            var bigEndianIndex = index.bigEndian
            withUnsafeBytes(of: &bigEndianIndex) {
                input.append(contentsOf: $0)
            }

            let authentication = HMAC<SHA512>.authenticationCode(
                for: input,
                using: SymmetricKey(data: chainCode)
            )
            let digest = Data(authentication)
            let left = Data(digest.prefix(32))
            let right = Data(digest.suffix(32))
            guard Self.isValidScalar(left),
                  let child = Self.addScalars(left, privateKey),
                  Self.isValidScalar(child)
            else {
                throw BitcoinExtendedPrivateKeyError.invalidChild
            }
            return Node(privateKey: child, chainCode: right)
        }

        private static let hardenedOffset: UInt32 = 0x8000_0000
        private static let curveOrder = Data([
            0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
            0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xfe,
            0xba, 0xae, 0xdc, 0xe6, 0xaf, 0x48, 0xa0, 0x3b,
            0xbf, 0xd2, 0x5e, 0x8c, 0xd0, 0x36, 0x41, 0x41
        ])

        private static func isValidScalar(_ data: Data) -> Bool {
            data.count == 32
                && data.contains(where: { $0 != 0 })
                && compare(data, curveOrder) == .orderedAscending
        }

        private static func addScalars(
            _ lhs: Data,
            _ rhs: Data
        ) -> Data? {
            guard lhs.count == 32, rhs.count == 32 else {
                return nil
            }
            let left = [UInt8](lhs)
            let right = [UInt8](rhs)
            var result = [UInt8](repeating: 0, count: 33)
            var carry = 0
            for index in stride(from: 31, through: 0, by: -1) {
                let sum = Int(left[index])
                    + Int(right[index])
                    + carry
                result[index + 1] = UInt8(sum & 0xff)
                carry = sum >> 8
            }
            result[0] = UInt8(carry)

            let extendedOrder = [UInt8(0)] + [UInt8](curveOrder)
            if compare(result, extendedOrder) != .orderedAscending {
                result = subtract(result, extendedOrder)
            }
            let scalar = Data(result.suffix(32))
            return scalar.contains(where: { $0 != 0 }) ? scalar : nil
        }

        private static func subtract(
            _ lhs: [UInt8],
            _ rhs: [UInt8]
        ) -> [UInt8] {
            var result = lhs
            var borrow = 0
            for index in stride(
                from: lhs.count - 1,
                through: 0,
                by: -1
            ) {
                var value = Int(lhs[index]) - Int(rhs[index]) - borrow
                if value < 0 {
                    value += 256
                    borrow = 1
                } else {
                    borrow = 0
                }
                result[index] = UInt8(value)
            }
            return result
        }

        private static func compare(
            _ lhs: Data,
            _ rhs: Data
        ) -> ComparisonResult {
            compare([UInt8](lhs), [UInt8](rhs))
        }

        private static func compare(
            _ lhs: [UInt8],
            _ rhs: [UInt8]
        ) -> ComparisonResult {
            guard lhs.count == rhs.count else {
                return lhs.count < rhs.count
                    ? .orderedAscending : .orderedDescending
            }
            for (left, right) in zip(lhs, rhs) where left != right {
                return left < right
                    ? .orderedAscending : .orderedDescending
            }
            return .orderedSame
        }
    }

    private static func configuration(
        version: HDVersion,
        chain: BitcoinFamilyChain,
        depth: Int
    ) throws -> Configuration {
        let purpose: UInt32
        let format: PrivateKeyImportFormat
        switch (chain, version) {
        case (.bitcoin, .xprv):
            purpose = 44
            format = .extendedLegacy
        case (.bitcoin, .yprv):
            purpose = 49
            format = .extendedNestedSegwit
        case (.bitcoin, .zprv):
            purpose = 84
            format = .extendedNativeSegwit
        case (.litecoin, .ltpv):
            purpose = 44
            format = .extendedLegacy
        case (.litecoin, .mtpv):
            purpose = 49
            format = .extendedNestedSegwit
        case (.dogecoin, .dgpv):
            purpose = 44
            format = .extendedLegacy
        case (.bitcoinCash, .xprv):
            purpose = 44
            format = .extendedLegacy
        case (.litecoin, .xprv),
             (.dogecoin, .xprv):
            guard depth == 0 else {
                throw BitcoinExtendedPrivateKeyError
                    .unsupportedVersion
            }
            purpose = 44
            format = .extendedLegacy
        default:
            throw BitcoinExtendedPrivateKeyError.unsupportedVersion
        }

        let coinType: UInt32
        switch chain {
        case .bitcoin:
            coinType = 0
        case .litecoin:
            coinType = 2
        case .dogecoin:
            coinType = 3
        case .bitcoinCash:
            coinType = 145
        }
        let hardened: (UInt32) -> UInt32 = { $0 | 0x8000_0000 }
        let indices = [
            hardened(purpose),
            hardened(coinType),
            hardened(0),
            0,
            0
        ]
        return Configuration(
            indices: indices,
            path: "m/\(purpose)'/\(coinType)'/0'/0/0",
            format: format
        )
    }

    private static func decodeCheckedPayload(
        _ encoded: String
    ) throws -> Data {
        if let decoded = Base58.decode(string: encoded),
           decoded.count == 78 {
            return decoded
        }
        guard let raw = Base58.decodeNoCheck(string: encoded),
              raw.count == 82
        else {
            throw BitcoinExtendedPrivateKeyError.invalidEncoding
        }
        let payload = Data(raw.prefix(78))
        let checksum = Data(raw.suffix(4))
        guard Hash.sha256SHA256(data: payload).prefix(4)
            .elementsEqual(checksum)
        else {
            throw BitcoinExtendedPrivateKeyError.invalidEncoding
        }
        return payload
    }

    private static func uint32<C: Collection>(
        _ bytes: C
    ) -> UInt32 where C.Element == UInt8 {
        bytes.reduce(0) { ($0 << 8) | UInt32($1) }
    }
}
