import CryptoKit
import Foundation
import P256K

enum MuunRecoveryCode {
    private static let currentAlphabet = Array(
        "ABCDEFHJKLMNPQRSTUVWXYZ2345789"
    )
    private static let legacyAlphabet = Set(
        "ABCDEFHJKMNPQRSTUVWXYZ2345789"
    )
    private static let kdfKey = Data("muun:rc".utf8)

    static func canonical(_ input: String) throws -> String {
        let characters = input.uppercased(with: Locale(identifier: "en_US_POSIX"))
            .unicodeScalars.filter {
                $0.value != 0x2D
                    && CharacterSet.whitespacesAndNewlines.contains($0) == false
            }
        guard characters.count == 32,
              characters.allSatisfy({ $0.isASCII }) else {
            throw MuunRecoveryError.invalidRecoveryCode
        }
        let raw = characters.map(Character.init)
        let grouped = stride(from: 0, to: raw.count, by: 4).map {
            String(raw[$0..<min($0 + 4, raw.count)])
        }.joined(separator: "-")
        _ = try version(ofCanonicalCode: grouped)
        return grouped
    }

    static func version(of input: String) throws -> Int {
        try version(ofCanonicalCode: canonical(input))
    }

    static func challengePrivateKey(
        code input: String,
        legacySalt: Data
    ) throws -> Data {
        let code = try canonical(input)
        let version = try version(ofCanonicalCode: code)
        let candidate: Data
        switch version {
        case 1:
            candidate = MuunRecoveryScrypt.derive(
                password: Data(code.utf8),
                salt: legacySalt
            )
        case 2:
            candidate = Data(
                HMAC<CryptoKit.SHA256>.authenticationCode(
                    for: Data(code.utf8),
                    using: SymmetricKey(data: kdfKey)
                )
            )
        default:
            throw MuunRecoveryError.unsupportedRecoveryCodeVersion
        }
        return try MuunSecp256k1Scalar.reduced(candidate)
    }

    static func challengePublicKeyChecksum(
        code: String,
        legacySalt: Data
    ) throws -> String {
        let privateKey = try challengePrivateKey(
            code: code,
            legacySalt: legacySalt
        )
        return try challengePublicKeyChecksum(privateKey: privateKey)
    }

    static func challengePublicKeyChecksum(
        privateKey: Data
    ) throws -> String {
        let signingKey: P256K.Signing.PrivateKey
        do {
            signingKey = try P256K.Signing.PrivateKey(
                dataRepresentation: privateKey
            )
        } catch {
            throw MuunRecoveryError.invalidKeyMaterial
        }
        let digest = Data(CryptoKit.SHA256.hash(
            data: signingKey.publicKey.dataRepresentation
        ))
        return Data(digest.suffix(8)).hexString
    }

    private static func version(ofCanonicalCode code: String) throws -> Int {
        guard code.utf8.count == 39 else {
            throw MuunRecoveryError.invalidRecoveryCode
        }
        let blocks = code.split(separator: "-", omittingEmptySubsequences: false)
        guard blocks.count == 8,
              blocks.allSatisfy({ $0.utf8.count == 4 }),
              let first = code.first else {
            throw MuunRecoveryError.invalidRecoveryCode
        }
        if first == "L" {
            guard let second = code.dropFirst().first,
                  let versionIndex = currentAlphabet.firstIndex(of: second) else {
                throw MuunRecoveryError.invalidRecoveryCode
            }
            let version = versionIndex + 2
            guard version <= 2 else {
                throw MuunRecoveryError.unsupportedRecoveryCodeVersion
            }
            let allowed = Set(currentAlphabet)
            guard blocks.joined().allSatisfy(allowed.contains) else {
                throw MuunRecoveryError.invalidRecoveryCode
            }
            return version
        }
        guard blocks.joined().allSatisfy(legacyAlphabet.contains) else {
            throw MuunRecoveryError.invalidRecoveryCode
        }
        return 1
    }
}

enum MuunSecp256k1Scalar {
    private static let order = Data([
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xfe,
        0xba, 0xae, 0xdc, 0xe6, 0xaf, 0x48, 0xa0, 0x3b,
        0xbf, 0xd2, 0x5e, 0x8c, 0xd0, 0x36, 0x41, 0x41,
    ])

    static func reduced(_ candidate: Data) throws -> Data {
        guard candidate.count == 32 else {
            throw MuunRecoveryError.invalidKeyMaterial
        }
        var bytes = Array(candidate)
        if lexicographicallyGreaterThanOrEqual(candidate, order) {
            var borrow = 0
            let modulus = Array(order)
            for index in stride(from: bytes.count - 1, through: 0, by: -1) {
                let difference = Int(bytes[index]) - Int(modulus[index]) - borrow
                if difference < 0 {
                    bytes[index] = UInt8(difference + 256)
                    borrow = 1
                } else {
                    bytes[index] = UInt8(difference)
                    borrow = 0
                }
            }
        }
        guard bytes.contains(where: { $0 != 0 }) else {
            throw MuunRecoveryError.invalidKeyMaterial
        }
        return Data(bytes)
    }

    private static func lexicographicallyGreaterThanOrEqual(
        _ lhs: Data,
        _ rhs: Data
    ) -> Bool {
        for (left, right) in zip(lhs, rhs) {
            if left != right { return left > right }
        }
        return true
    }
}

private enum MuunRecoveryScrypt {
    private static let cost = 512
    private static let blockSize = 8
    private static let parallelization = 1

    static func derive(password: Data, salt: Data) -> Data {
        let initial = pbkdf2(
            password: password,
            salt: salt,
            outputByteCount: 128 * blockSize * parallelization
        )
        var mixed = Data()
        mixed.reserveCapacity(initial.count)
        let laneByteCount = 128 * blockSize
        for lane in 0..<parallelization {
            let lower = lane * laneByteCount
            let upper = lower + laneByteCount
            mixed.append(romix(Data(initial[lower..<upper])))
        }
        return pbkdf2(
            password: password,
            salt: mixed,
            outputByteCount: 32
        )
    }

    private static func romix(_ input: Data) -> Data {
        var x = words(fromLittleEndian: input)
        let wordCount = x.count
        var memory = [UInt32](
            repeating: 0,
            count: cost * wordCount
        )
        for iteration in 0..<cost {
            memory.replaceSubrange(
                (iteration * wordCount)..<((iteration + 1) * wordCount),
                with: x
            )
            x = blockMix(x)
        }
        for _ in 0..<cost {
            let offset = (2 * blockSize - 1) * 16
            let integer = UInt64(x[offset]) | UInt64(x[offset + 1]) << 32
            let selected = Int(integer & UInt64(cost - 1)) * wordCount
            for index in x.indices {
                x[index] ^= memory[selected + index]
            }
            x = blockMix(x)
        }
        return littleEndianData(from: x)
    }

    private static func blockMix(_ input: [UInt32]) -> [UInt32] {
        var x = Array(input.suffix(16))
        var intermediate = [UInt32](repeating: 0, count: input.count)
        for block in 0..<(2 * blockSize) {
            let start = block * 16
            for index in 0..<16 {
                x[index] ^= input[start + index]
            }
            salsa208(&x)
            intermediate.replaceSubrange(start..<(start + 16), with: x)
        }
        var output = [UInt32](repeating: 0, count: input.count)
        for block in 0..<blockSize {
            output.replaceSubrange(
                (block * 16)..<((block + 1) * 16),
                with: intermediate[(block * 32)..<(block * 32 + 16)]
            )
            let oddDestination = (block + blockSize) * 16
            let oddSource = block * 32 + 16
            output.replaceSubrange(
                oddDestination..<(oddDestination + 16),
                with: intermediate[oddSource..<(oddSource + 16)]
            )
        }
        return output
    }

    private static func salsa208(_ words: inout [UInt32]) {
        let original = words
        for _ in 0..<4 {
            words[4] ^= rotate(words[0] &+ words[12], 7)
            words[8] ^= rotate(words[4] &+ words[0], 9)
            words[12] ^= rotate(words[8] &+ words[4], 13)
            words[0] ^= rotate(words[12] &+ words[8], 18)
            words[9] ^= rotate(words[5] &+ words[1], 7)
            words[13] ^= rotate(words[9] &+ words[5], 9)
            words[1] ^= rotate(words[13] &+ words[9], 13)
            words[5] ^= rotate(words[1] &+ words[13], 18)
            words[14] ^= rotate(words[10] &+ words[6], 7)
            words[2] ^= rotate(words[14] &+ words[10], 9)
            words[6] ^= rotate(words[2] &+ words[14], 13)
            words[10] ^= rotate(words[6] &+ words[2], 18)
            words[3] ^= rotate(words[15] &+ words[11], 7)
            words[7] ^= rotate(words[3] &+ words[15], 9)
            words[11] ^= rotate(words[7] &+ words[3], 13)
            words[15] ^= rotate(words[11] &+ words[7], 18)

            words[1] ^= rotate(words[0] &+ words[3], 7)
            words[2] ^= rotate(words[1] &+ words[0], 9)
            words[3] ^= rotate(words[2] &+ words[1], 13)
            words[0] ^= rotate(words[3] &+ words[2], 18)
            words[6] ^= rotate(words[5] &+ words[4], 7)
            words[7] ^= rotate(words[6] &+ words[5], 9)
            words[4] ^= rotate(words[7] &+ words[6], 13)
            words[5] ^= rotate(words[4] &+ words[7], 18)
            words[11] ^= rotate(words[10] &+ words[9], 7)
            words[8] ^= rotate(words[11] &+ words[10], 9)
            words[9] ^= rotate(words[8] &+ words[11], 13)
            words[10] ^= rotate(words[9] &+ words[8], 18)
            words[12] ^= rotate(words[15] &+ words[14], 7)
            words[13] ^= rotate(words[12] &+ words[15], 9)
            words[14] ^= rotate(words[13] &+ words[12], 13)
            words[15] ^= rotate(words[14] &+ words[13], 18)
        }
        for index in words.indices {
            words[index] &+= original[index]
        }
    }

    private static func rotate(_ value: UInt32, _ count: UInt32) -> UInt32 {
        value << count | value >> (32 - count)
    }

    private static func words(fromLittleEndian data: Data) -> [UInt32] {
        stride(from: 0, to: data.count, by: 4).map { offset in
            let byte0 = UInt32(data[offset])
            let byte1 = UInt32(data[offset + 1]) << 8
            let byte2 = UInt32(data[offset + 2]) << 16
            let byte3 = UInt32(data[offset + 3]) << 24
            return byte0 | byte1 | byte2 | byte3
        }
    }

    private static func littleEndianData(from words: [UInt32]) -> Data {
        var result = Data()
        result.reserveCapacity(words.count * 4)
        for word in words {
            result.append(UInt8(truncatingIfNeeded: word))
            result.append(UInt8(truncatingIfNeeded: word >> 8))
            result.append(UInt8(truncatingIfNeeded: word >> 16))
            result.append(UInt8(truncatingIfNeeded: word >> 24))
        }
        return result
    }

    private static func pbkdf2(
        password: Data,
        salt: Data,
        outputByteCount: Int
    ) -> Data {
        let key = SymmetricKey(data: password)
        let blockCount = (outputByteCount + CryptoKit.SHA256.Digest.byteCount - 1)
            / CryptoKit.SHA256.Digest.byteCount
        var result = Data()
        result.reserveCapacity(blockCount * CryptoKit.SHA256.Digest.byteCount)
        for blockIndex in 1...blockCount {
            var input = salt
            var bigEndian = UInt32(blockIndex).bigEndian
            Swift.withUnsafeBytes(of: &bigEndian) {
                input.append(contentsOf: $0)
            }
            result.append(contentsOf: HMAC<CryptoKit.SHA256>.authenticationCode(
                for: input,
                using: key
            ))
        }
        return Data(result.prefix(outputByteCount))
    }
}
