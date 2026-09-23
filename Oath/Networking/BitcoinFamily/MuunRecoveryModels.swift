import Foundation
import P256K
import WalletCore

enum MuunRecoveryError: Error, Equatable, Sendable {
    case invalidRecoveryCode
    case unsupportedRecoveryCodeVersion
    case invalidEncryptedKey
    case encryptedKeysDoNotMatch
    case invalidEmergencyKit
    case recoveryCodeDoesNotMatchEmergencyKit
    case decryptionFailed
    case invalidKeyMaterial
    case invalidDerivationPath
    case derivationFailed
}

struct MuunEncryptedPrivateKey: Hashable, Sendable {
    private static let version2 = 2
    private static let version3 = 3

    let birthdayBlock: Int
    let ephemeralPublicKey: Data
    let ciphertext: Data
    let salt: Data
    let carriesSalt: Bool

    init(encoded: String) throws {
        let normalized = encoded.unicodeScalars.filter {
            CharacterSet.whitespacesAndNewlines.contains($0) == false
        }.map(String.init).joined()
        guard !normalized.isEmpty,
              let raw = Base58.decodeNoCheck(string: normalized),
              Base58.encodeNoCheck(data: raw) == normalized,
              let version = raw.first else {
            throw MuunRecoveryError.invalidEncryptedKey
        }

        let birthday: Int
        let publicKey: Data
        let encrypted: Data
        let decodedSalt: Data
        let hasSalt: Bool
        switch Int(version) {
        case Self.version2:
            guard raw.count == 100 || raw.count == 108 else {
                throw MuunRecoveryError.invalidEncryptedKey
            }
            birthday = Int(raw[1]) << 8 | Int(raw[2])
            publicKey = Data(raw[3..<36])
            encrypted = Data(raw[36..<100])
            hasSalt = raw.count == 108
            decodedSalt = hasSalt
                ? Data(raw[100..<108])
                : Data(repeating: 0, count: 8)
        case Self.version3:
            guard raw.count == 106 else {
                throw MuunRecoveryError.invalidEncryptedKey
            }
            birthday = 0
            publicKey = Data(raw[1..<34])
            encrypted = Data(raw[34..<98])
            decodedSalt = Data(raw[98..<106])
            hasSalt = true
        default:
            throw MuunRecoveryError.invalidEncryptedKey
        }
        try self.init(
            birthdayBlock: birthday,
            ephemeralPublicKey: publicKey,
            ciphertext: encrypted,
            salt: decodedSalt,
            carriesSalt: hasSalt
        )
    }

    init(
        birthdayBlock: Int,
        ephemeralPublicKey: Data,
        ciphertext: Data,
        salt: Data,
        carriesSalt: Bool = true
    ) throws {
        guard (0...Int(UInt16.max)).contains(birthdayBlock),
              ephemeralPublicKey.count == 33,
              ciphertext.count == 64,
              salt.count == 8,
              (try? P256K.KeyAgreement.PublicKey(
                  dataRepresentation: ephemeralPublicKey,
                  format: .compressed
              )) != nil else {
            throw MuunRecoveryError.invalidEncryptedKey
        }
        self.birthdayBlock = birthdayBlock
        self.ephemeralPublicKey = ephemeralPublicKey
        self.ciphertext = ciphertext
        self.salt = salt
        self.carriesSalt = carriesSalt
    }
}

struct MuunRecoveryKeyMaterial: Codable, Hashable, Sendable {
    static let currentVersion = 1
    static let accountMarker = "muun-recovery:v1"

    let version: Int
    let userPrivateKey: Data
    let userChainCode: Data
    let muunPrivateKey: Data
    let muunChainCode: Data
    let birthdayBlock: Int

    init(
        version: Int = currentVersion,
        userPrivateKey: Data,
        userChainCode: Data,
        muunPrivateKey: Data,
        muunChainCode: Data,
        birthdayBlock: Int
    ) throws {
        self.version = version
        self.userPrivateKey = userPrivateKey
        self.userChainCode = userChainCode
        self.muunPrivateKey = muunPrivateKey
        self.muunChainCode = muunChainCode
        self.birthdayBlock = birthdayBlock
        _ = try validated()
    }

    func validated() throws -> Self {
        guard version == Self.currentVersion,
              userPrivateKey.count == 32,
              userChainCode.count == 32,
              muunPrivateKey.count == 32,
              muunChainCode.count == 32,
              (0...Int(UInt16.max)).contains(birthdayBlock),
              (try? P256K.Signing.PrivateKey(
                  dataRepresentation: userPrivateKey
              )) != nil,
              (try? P256K.Signing.PrivateKey(
                  dataRepresentation: muunPrivateKey
              )) != nil else {
            throw MuunRecoveryError.invalidKeyMaterial
        }
        return self
    }

    func encodedData() throws -> Data {
        _ = try validated()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    static func decode(_ data: Data) throws -> Self {
        do {
            return try JSONDecoder().decode(Self.self, from: data)
                .validated()
        } catch let error as MuunRecoveryError {
            throw error
        } catch {
            throw MuunRecoveryError.invalidKeyMaterial
        }
    }
}

enum MuunRecoveryAddressVersion: Int, Codable, CaseIterable, Sendable {
    case v2 = 2
    case v3 = 3
    case v4 = 4
    case v5 = 5
}

enum MuunRecoveryAddressBranch: Int, Codable, Sendable {
    case change = 0
    case external = 1
    case contacts = 2
}

struct MuunRecoveryDerivedAddress: Codable, Hashable, Sendable {
    let version: MuunRecoveryAddressVersion
    let branch: MuunRecoveryAddressBranch
    let contactIndex: Int?
    let addressIndex: Int
    let derivationPath: String
    let address: String
    let scriptPubKey: Data
    let scriptHash: String
}

struct MuunRecoveryAddressState: Hashable, Sendable {
    let derived: MuunRecoveryDerivedAddress
    let isUsed: Bool
    let isReserved: Bool
    let confirmedBalanceAtomic: BitcoinFamilyAtomicInteger
    let unconfirmedBalanceAtomic: BitcoinFamilyAtomicInteger

    var balanceAtomic: BitcoinFamilyAtomicInteger {
        confirmedBalanceAtomic.adding(unconfirmedBalanceAtomic)
    }
}

struct MuunRecoveryWalletState: Hashable, Sendable {
    let walletID: String
    let birthdayBlock: Int
    let recoveryScanCursor: Int
    let fullScanCompleted: Bool
    let nextExternalIndex: Int
    let nextChangeIndex: Int
}

struct MuunRecoveryPersistenceSeed: Sendable {
    let birthdayBlock: Int
    let initialAddress: MuunRecoveryDerivedAddress

    init(
        material: MuunRecoveryKeyMaterial,
        initialAddress: MuunRecoveryDerivedAddress
    ) throws {
        let validated = try material.validated()
        guard initialAddress.version == .v5,
              initialAddress.branch == .external,
              initialAddress.contactIndex == nil,
              initialAddress.addressIndex == 0 else {
            throw MuunRecoveryError.invalidKeyMaterial
        }
        self.birthdayBlock = validated.birthdayBlock
        self.initialAddress = initialAddress
    }
}
