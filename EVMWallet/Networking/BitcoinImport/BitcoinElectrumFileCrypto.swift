import CommonCrypto
import CryptoKit
import Foundation
import P256K
import WalletCore
import zlib

/// Electrum 4.8.1 storage.py / crypto.py wire compatibility. All work stays local.
/// See BitcoinImportLicense.txt for the Electrum MIT notice.
enum BitcoinElectrumFileCrypto {
    static func decryptStorage(_ encoded: String, password: String?) throws -> Data? {
        guard let envelope = Data(base64Encoded: encoded), envelope.count >= 4 else { return nil }
        let magic = envelope.prefix(4)
        guard magic == Data("BIE1".utf8) || magic == Data("BIE2".utf8) else { return nil }
        guard magic == Data("BIE1".utf8) else { throw BitcoinImportError.unsupportedEncryption }
        guard envelope.count >= 85, (envelope.count - 69).isMultiple(of: 16) else {
            throw BitcoinImportError.invalidFile
        }
        guard let password else { throw BitcoinImportError.passwordRequired }
        let passwordBytes = Array(password.utf8)
        var stretched = Data(count: 64)
        let status = stretched.withUnsafeMutableBytes { output in
            passwordBytes.withUnsafeBytes { input in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), input.baseAddress?.assumingMemoryBound(to: Int8.self),
                    passwordBytes.count, nil, 0, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA512), 1024,
                    output.baseAddress!.assumingMemoryBound(to: UInt8.self), 64)
            }
        }
        defer { stretched.resetBytes(in: 0..<stretched.count) }
        guard status == kCCSuccess else { throw BitcoinImportError.invalidFile }
        let secret = try reducedScalar(stretched)
        let publicKey: P256K.KeyAgreement.PublicKey
        do {
            publicKey = try .init(dataRepresentation: Data(envelope[4..<37]), format: .compressed)
        } catch { throw BitcoinImportError.invalidFile }
        let privateKey = try P256K.KeyAgreement.PrivateKey(dataRepresentation: secret)
        let shared = privateKey.sharedSecretFromKeyAgreement(with: publicKey)
        let point = shared.withUnsafeBytes { Data($0) }
        guard point.count == 33 else { throw BitcoinImportError.invalidFile }
        let key = Data(SHA512.hash(data: point))
        guard HMAC<CryptoKit.SHA256>.isValidAuthenticationCode(envelope.suffix(32),
            authenticating: envelope.dropLast(32), using: SymmetricKey(data: key.suffix(32))) else {
            throw BitcoinImportError.incorrectPassword
        }
        let compressed = try decryptAES(Data(envelope[37..<(envelope.count - 32)]),
            key: Data(key[16..<32]), iv: Data(key.prefix(16)))
        return try inflate(compressed)
    }

    static func decodeSecret(_ encoded: String, encrypted: Bool, password: String?, version: Int) throws -> String {
        guard version == 1 else { throw BitcoinImportError.unsupportedEncryption }
        guard encrypted else { return encoded }
        guard let password else { throw BitcoinImportError.passwordRequired }
        guard let bytes = Data(base64Encoded: encoded), bytes.count >= 32 else { throw BitcoinImportError.invalidFile }
        let key = Hash.sha256SHA256(data: Data(password.utf8))
        let plaintext = try decryptAES(Data(bytes.dropFirst(16)), key: key, iv: Data(bytes.prefix(16)))
        guard let string = String(data: plaintext, encoding: .utf8) else { throw BitcoinImportError.incorrectPassword }
        return string
    }

    /// Long reduction is needed for Electrum's 64-byte PBKDF2 scalar; truncating it
    /// to 32 bytes is not compatible with ECPrivkey.from_arbitrary_size_secret.
    static func reducedScalar(_ bytes: Data, allowZero: Bool = false) throws -> Data {
        let order: [UInt8] = [0] + Array(Data(hexString: "fffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141")!)
        var remainder = [UInt8](repeating: 0, count: 33)
        for byte in bytes {
            for bit in stride(from: 7, through: 0, by: -1) {
                var carry = (byte >> bit) & 1
                for index in stride(from: 32, through: 0, by: -1) {
                    let next = remainder[index] >> 7
                    remainder[index] = (remainder[index] << 1) | carry
                    carry = next
                }
                if !remainder.lexicographicallyPrecedes(order) {
                    var borrow = 0
                    for index in stride(from: 32, through: 0, by: -1) {
                        let value = Int(remainder[index]) - Int(order[index]) - borrow
                        remainder[index] = UInt8(truncatingIfNeeded: value)
                        borrow = value < 0 ? 1 : 0
                    }
                }
            }
        }
        let result = Data(remainder.dropFirst())
        guard (allowZero && result.allSatisfy { $0 == 0 }) || PrivateKey.isValid(data: result, curve: .secp256k1) else { throw BitcoinImportError.invalidKey }
        return result
    }

    private static func decryptAES(_ bytes: Data, key: Data, iv: Data) throws -> Data {
        guard [16, 32].contains(key.count), iv.count == 16, !bytes.isEmpty,
              bytes.count.isMultiple(of: 16) else { throw BitcoinImportError.invalidFile }
        var output = Data(count: bytes.count + 16)
        let capacity = output.count
        var count = 0
        let status = output.withUnsafeMutableBytes { result in
            bytes.withUnsafeBytes { input in
                key.withUnsafeBytes { secret in
                    iv.withUnsafeBytes { vector in
                        CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                            secret.baseAddress, key.count, vector.baseAddress, input.baseAddress, bytes.count,
                            result.baseAddress, capacity, &count)
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw BitcoinImportError.incorrectPassword }
        output.removeSubrange(count..<output.count)
        return output
    }

    private static func inflate(_ bytes: Data) throws -> Data {
        var capacity = min(max(bytes.count * 2, 4096), BitcoinImportFileParser.maximumBytes)
        while true {
            try Task.checkCancellation()
            var output = Data(count: capacity)
            var length = uLongf(capacity)
            let status = output.withUnsafeMutableBytes { result in
                bytes.withUnsafeBytes { input in
                    uncompress(result.baseAddress!.assumingMemoryBound(to: UInt8.self), &length,
                        input.baseAddress!.assumingMemoryBound(to: UInt8.self), uLong(bytes.count))
                }
            }
            if status == Z_OK { output.removeSubrange(Int(length)..<output.count); return output }
            guard status == Z_BUF_ERROR else { throw BitcoinImportError.invalidFile }
            guard capacity < BitcoinImportFileParser.maximumBytes else { throw BitcoinImportError.fileTooLarge }
            capacity = min(capacity * 2, BitcoinImportFileParser.maximumBytes)
        }
    }
}
