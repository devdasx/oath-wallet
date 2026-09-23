import CommonCrypto
import Foundation
import P256K

enum MuunRecoveryKeyDecryptor {
    static func recover(
        firstEncryptedKey: String,
        secondEncryptedKey: String,
        recoveryCode: String,
        expectedFingerprints: MuunRecoveryFingerprints? = nil,
        expectedRecoveryCodeChecksum: String? = nil
    ) throws -> MuunRecoveryKeyMaterial {
        try recover(
            first: MuunEncryptedPrivateKey(encoded: firstEncryptedKey),
            second: MuunEncryptedPrivateKey(encoded: secondEncryptedKey),
            recoveryCode: recoveryCode,
            expectedFingerprints: expectedFingerprints,
            expectedRecoveryCodeChecksum: expectedRecoveryCodeChecksum
        )
    }

    static func recover(
        first: MuunEncryptedPrivateKey,
        second: MuunEncryptedPrivateKey,
        recoveryCode: String,
        expectedFingerprints: MuunRecoveryFingerprints? = nil,
        expectedRecoveryCodeChecksum: String? = nil
    ) throws -> MuunRecoveryKeyMaterial {
        guard first.birthdayBlock == second.birthdayBlock else {
            throw MuunRecoveryError.encryptedKeysDoNotMatch
        }
        let codeVersion = try MuunRecoveryCode.version(of: recoveryCode)
        guard codeVersion != 1 || second.carriesSalt else {
            throw MuunRecoveryError.invalidEncryptedKey
        }
        let challengeKey = try MuunRecoveryCode.challengePrivateKey(
            code: recoveryCode,
            legacySalt: second.salt
        )
        if let expectedRecoveryCodeChecksum {
            let actualChecksum = try MuunRecoveryCode
                .challengePublicKeyChecksum(privateKey: challengeKey)
            guard actualChecksum == expectedRecoveryCodeChecksum else {
                throw MuunRecoveryError.recoveryCodeDoesNotMatchEmergencyKit
            }
        }
        let user = try decrypt(first, challengePrivateKey: challengeKey)
        let muun = try decrypt(second, challengePrivateKey: challengeKey)
        let material = try MuunRecoveryKeyMaterial(
            userPrivateKey: user.privateKey,
            userChainCode: user.chainCode,
            muunPrivateKey: muun.privateKey,
            muunChainCode: muun.chainCode,
            birthdayBlock: second.birthdayBlock
        )
        if let expectedFingerprints {
            try MuunRecoveryDerivation.verify(
                material: material,
                expectedFingerprints: expectedFingerprints
            )
        }
        return material
    }

    private static func decrypt(
        _ encrypted: MuunEncryptedPrivateKey,
        challengePrivateKey: Data
    ) throws -> (privateKey: Data, chainCode: Data) {
        do {
            let privateKey = try P256K.KeyAgreement.PrivateKey(
                dataRepresentation: challengePrivateKey
            )
            let publicKey = try P256K.KeyAgreement.PublicKey(
                dataRepresentation: encrypted.ephemeralPublicKey,
                format: .compressed
            )
            let shared = privateKey.sharedSecretFromKeyAgreement(with: publicKey)
            let serializedPoint = shared.withUnsafeBytes { Data($0) }
            guard serializedPoint.count == 33 else {
                throw MuunRecoveryError.decryptionFailed
            }
            let aesKey = Data(serializedPoint.dropFirst())
            let initializationVector = Data(
                encrypted.ephemeralPublicKey.suffix(kCCBlockSizeAES128)
            )
            let plaintext = try aesCBCDecrypt(
                ciphertext: encrypted.ciphertext,
                key: aesKey,
                initializationVector: initializationVector
            )
            guard plaintext.count == 64 else {
                throw MuunRecoveryError.decryptionFailed
            }
            let rootPrivateKey = Data(plaintext.prefix(32))
            let chainCode = Data(plaintext.suffix(32))
            guard (try? P256K.Signing.PrivateKey(
                dataRepresentation: rootPrivateKey
            )) != nil else {
                throw MuunRecoveryError.decryptionFailed
            }
            return (rootPrivateKey, chainCode)
        } catch let error as MuunRecoveryError {
            throw error
        } catch {
            throw MuunRecoveryError.decryptionFailed
        }
    }

    private static func aesCBCDecrypt(
        ciphertext: Data,
        key: Data,
        initializationVector: Data
    ) throws -> Data {
        guard ciphertext.count.isMultiple(of: kCCBlockSizeAES128),
              key.count == kCCKeySizeAES256,
              initializationVector.count == kCCBlockSizeAES128 else {
            throw MuunRecoveryError.decryptionFailed
        }
        var output = Data(count: ciphertext.count)
        var outputLength = 0
        let outputCapacity = output.count
        let status = output.withUnsafeMutableBytes { outputBytes in
            key.withUnsafeBytes { keyBytes in
                initializationVector.withUnsafeBytes { ivBytes in
                    ciphertext.withUnsafeBytes { ciphertextBytes in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(0),
                            keyBytes.baseAddress,
                            key.count,
                            ivBytes.baseAddress,
                            ciphertextBytes.baseAddress,
                            ciphertext.count,
                            outputBytes.baseAddress,
                            outputCapacity,
                            &outputLength
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess, outputLength == ciphertext.count else {
            throw MuunRecoveryError.decryptionFailed
        }
        if outputLength < output.count {
            output.removeSubrange(outputLength..<output.count)
        }
        return output
    }
}
