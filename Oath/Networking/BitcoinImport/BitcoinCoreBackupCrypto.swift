import CommonCrypto
import CryptoKit
import Foundation
import WalletCore

enum BitcoinCoreBackupCrypto {
    static func masterKey(record: Data, password: String) throws -> Data {
        var reader = BitcoinBackupBytes(record)
        let encrypted = try reader.vector(limit: 128)
        let salt = try reader.vector(limit: 32)
        let method = try reader.integer(4)
        let rounds = try reader.integer(4)
        let extra = try reader.vector(limit: 1024)
        guard method == 0, extra.isEmpty else { throw BitcoinImportError.unsupportedEncryption }
        guard salt.count == 8, (1...10_000_000).contains(rounds), reader.remaining == 0 else {
            throw BitcoinImportError.invalidFile
        }
        // Core uses the exact UTF-8 password, without BIP38/BIP39 normalization.
        var digest = Data(SHA512.hash(data: Data(password.utf8) + salt))
        defer { digest.resetBytes(in: 0..<digest.count) }
        if rounds > 1 {
            for index in 1..<rounds {
                if index.isMultiple(of: 1024) { try Task.checkCancellation() }
                digest = Data(SHA512.hash(data: digest))
            }
        }
        let decrypted = try decrypt(encrypted, key: Data(digest.prefix(32)), iv: Data(digest[32..<48]))
        guard decrypted.count == 32 else { throw BitcoinImportError.incorrectPassword }
        return decrypted
    }

    static func privateKey(encrypted: Data, publicKey: Data, masterKey: Data) throws -> Data {
        let iv = Data(Hash.sha256SHA256(data: publicKey).prefix(16))
        let key = try decrypt(encrypted, key: masterKey, iv: iv)
        try verify(key: key, publicKey: publicKey, error: .incorrectPassword)
        return key
    }

    static func verify(key: Data, publicKey: Data, error: BitcoinImportError = .invalidFile) throws {
        guard [33, 65].contains(publicKey.count), PrivateKey.isValid(data: key, curve: .secp256k1),
              let privateKey = PrivateKey(data: key),
              privateKey.getPublicKeySecp256k1(compressed: publicKey.count == 33).data == publicKey else {
            throw error
        }
    }

    /// SEC1 ECPrivateKey DER. Extract only the scalar and verify its recorded SEC
    /// public key independently; do not trust optional curve/public-key fields.
    static func derPrivateKey(_ data: Data, publicKey: Data) throws -> Data {
        var outer = BitcoinBackupBytes(data)
        guard try outer.integer(1) == 0x30 else { throw BitcoinImportError.invalidFile }
        let length = try derLength(&outer)
        guard length == outer.remaining else { throw BitcoinImportError.invalidFile }
        guard try outer.integer(1) == 0x02, try derLength(&outer) == 1,
              try outer.integer(1) == 1, try outer.integer(1) == 0x04 else {
            throw BitcoinImportError.invalidFile
        }
        let size = try derLength(&outer)
        guard (1...32).contains(size) else { throw BitcoinImportError.invalidFile }
        let scalar = try Data(repeating: 0, count: 32 - size) + outer.take(size)
        // Validate remaining DER TLV boundaries rather than accepting arbitrary trailing bytes.
        while outer.remaining > 0 {
            let tag = try outer.integer(1)
            guard tag == 0xa0 || tag == 0xa1 else { throw BitcoinImportError.invalidFile }
            _ = try outer.take(derLength(&outer))
        }
        try verify(key: scalar, publicKey: publicKey)
        return scalar
    }

    private static func derLength(_ reader: inout BitcoinBackupBytes) throws -> Int {
        let first = try reader.integer(1)
        if first < 128 { return Int(first) }
        let bytes = Int(first & 0x7f)
        guard (1...2).contains(bytes) else { throw BitcoinImportError.invalidFile }
        let value = try reader.integer(bytes, bigEndian: true)
        guard value >= 128 else { throw BitcoinImportError.invalidFile }
        return Int(value)
    }

    private static func decrypt(_ ciphertext: Data, key: Data, iv: Data) throws -> Data {
        guard key.count == 32, iv.count == 16, !ciphertext.isEmpty,
              ciphertext.count.isMultiple(of: 16) else { throw BitcoinImportError.invalidFile }
        var output = Data(count: ciphertext.count + 16)
        let capacity = output.count
        var length = 0
        let status = output.withUnsafeMutableBytes { result in
            ciphertext.withUnsafeBytes { input in
                key.withUnsafeBytes { secret in
                    iv.withUnsafeBytes { vector in
                        CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                                secret.baseAddress, key.count, vector.baseAddress, input.baseAddress,
                                ciphertext.count, result.baseAddress, capacity, &length)
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw BitcoinImportError.incorrectPassword }
        output.removeSubrange(length..<output.count)
        return output
    }
}
