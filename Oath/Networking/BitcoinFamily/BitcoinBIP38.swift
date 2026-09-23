import CommonCrypto
import CryptoExtras
import Foundation
import P256K
import WalletCore

enum BitcoinBIP38Error: Error, Equatable {
    case invalidEncoding
    case incorrectPassword
    case decryptionFailed
}

/// Mainnet BIP38 decryption. Passwords use NFC (not BIP39's NFKD).
/// All work is local; callers must run the expensive KDF off the main actor.
enum BitcoinBIP38 {
    static func recognizes(_ encoded: String, network: PrivateKeyImportNetwork) -> Bool {
        network == .bitcoin && (try? payload(encoded)) != nil
    }

    static func decrypt(_ encoded: String, password: String) throws -> WalletImportDraft {
        let bytes = try payload(encoded)
        try Task.checkCancellation()
        let passphrase = Data(password.precomposedStringWithCanonicalMapping.utf8)
        let compressed = bytes[2] & 0x20 != 0
        let addressHash = Data(bytes[3..<7])
        var secret: Data
        if bytes[1] == 0x42 {
            var derived = try scrypt(passphrase, salt: addressHash, rounds: 16_384, blockSize: 8, parallelism: 8, count: 64)
            defer { derived.resetBytes(in: 0..<derived.count) }
            secret = try xor(aesDecrypt(Data(bytes[7..<39]), key: Data(derived[32..<64])), Data(derived[0..<32]))
        } else {
            secret = try decryptMultiplied(bytes, password: passphrase)
        }
        defer { secret.resetBytes(in: 0..<secret.count) }
        try Task.checkCancellation()
        guard PrivateKey.isValid(data: secret, curve: .secp256k1) else {
            throw BitcoinBIP38Error.incorrectPassword
        }
        // BIP38's address checksum always uses P2PKH with the recorded key compression.
        let legacy = try BitcoinFamilyDerivationService().derive(
            privateKey: secret, chain: .bitcoin,
            format: compressed ? .extendedLegacy : .wifUncompressed
        )
        guard Hash.sha256SHA256(data: Data(legacy.address.utf8)).prefix(4).elementsEqual(addressHash) else {
            throw BitcoinBIP38Error.incorrectPassword
        }
        // Preserve existing WIF import and multi-format discovery behavior.
        // Compressed WIF imports default to SegWit but also scan their legacy address.
        return try PrivateKeyImportService.revalidate(
            privateKeyData: secret, network: .bitcoin,
            format: compressed ? .wifCompressed : .wifUncompressed
        )
    }

    private static func payload(_ encoded: String) throws -> Data {
        let text = encoded.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.utf8.count == 58, text.hasPrefix("6P"),
              let bytes = Base58.decode(string: text), bytes.count == 39,
              bytes[0] == 0x01 else { throw BitcoinBIP38Error.invalidEncoding }
        switch bytes[1] {
        case 0x42:
            guard bytes[2] == 0xc0 || bytes[2] == 0xe0 else { throw BitcoinBIP38Error.invalidEncoding }
        case 0x43:
            guard bytes[2] & ~UInt8(0x24) == 0 else { throw BitcoinBIP38Error.invalidEncoding }
        default: throw BitcoinBIP38Error.invalidEncoding
        }
        return bytes
    }

    private static func decryptMultiplied(_ bytes: Data, password: Data) throws -> Data {
        let entropy = Data(bytes[7..<15])
        let hasLotSequence = bytes[2] & 0x04 != 0
        var factor = try scrypt(password, salt: hasLotSequence ? Data(entropy.prefix(4)) : entropy,
                                rounds: 16_384, blockSize: 8, parallelism: 8, count: 32)
        defer { factor.resetBytes(in: 0..<factor.count) }
        if hasLotSequence { factor = Hash.sha256SHA256(data: factor + entropy) }
        guard let privateKey = PrivateKey(data: factor), PrivateKey.isValid(data: factor, curve: .secp256k1) else {
            throw BitcoinBIP38Error.incorrectPassword
        }
        let passpoint = privateKey.getPublicKeySecp256k1(compressed: true).data
        var derived = try scrypt(passpoint, salt: Data(bytes[3..<15]),
                                 rounds: 1_024, blockSize: 1, parallelism: 1, count: 64)
        defer { derived.resetBytes(in: 0..<derived.count) }
        let aesKey = Data(derived[32..<64])
        let part2 = try xor(aesDecrypt(Data(bytes[23..<39]), key: aesKey), Data(derived[16..<32]))
        let part1 = try xor(aesDecrypt(Data(bytes[15..<23]) + part2.prefix(8), key: aesKey), Data(derived[0..<16]))
        var seed = part1 + part2.suffix(8)
        defer { seed.resetBytes(in: 0..<seed.count) }
        let factorB = Hash.sha256SHA256(data: seed)
        do {
            let key = try P256K.Signing.PrivateKey(dataRepresentation: factor)
            return Data(try key.multiply(Array(factorB)).dataRepresentation)
        } catch { throw BitcoinBIP38Error.incorrectPassword }
    }

    private static func scrypt(_ password: Data, salt: Data, rounds: Int,
                               blockSize: Int, parallelism: Int, count: Int) throws -> Data {
        try Task.checkCancellation()
        let key: Data
        do {
            key = try KDF.Scrypt.deriveKey(from: password, salt: salt, outputByteCount: count,
                                           rounds: rounds, blockSize: blockSize, parallelism: parallelism)
                .withUnsafeBytes { Data($0) }
        } catch { throw BitcoinBIP38Error.decryptionFailed }
        try Task.checkCancellation()
        return key
    }

    private static func xor(_ left: Data, _ right: Data) -> Data {
        Data(zip(left, right).map { $0 ^ $1 })
    }

    private static func aesDecrypt(_ ciphertext: Data, key: Data) throws -> Data {
        var output = Data(count: ciphertext.count)
        var length = 0
        let status = output.withUnsafeMutableBytes { out in
            key.withUnsafeBytes { keyBytes in
                ciphertext.withUnsafeBytes { input in
                    CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode),
                            keyBytes.baseAddress, key.count, nil, input.baseAddress, ciphertext.count,
                            out.baseAddress, ciphertext.count, &length)
                }
            }
        }
        guard status == kCCSuccess, length == ciphertext.count else { throw BitcoinBIP38Error.decryptionFailed }
        return output
    }
}
