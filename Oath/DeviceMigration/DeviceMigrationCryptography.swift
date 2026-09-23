import CryptoKit
import Foundation
import Security

struct DeviceMigrationSourceHandshake: Sendable {
    let invitation: DeviceMigrationInvitation
    let privateKey: P256.KeyAgreement.PrivateKey
}

struct DeviceMigrationReceiverHandshake: Sendable {
    let joinRequest: DeviceMigrationJoinRequest
    let encryptionKey: SymmetricKey
}

enum DeviceMigrationCryptography {
    private static let keyAgreementInfo = Data(
        "aperture.device-migration.key-agreement.v1".utf8
    )

    static func makeSourceHandshake(
        now: Date = Date()
    ) throws -> DeviceMigrationSourceHandshake {
        let privateKey = P256.KeyAgreement.PrivateKey()
        let sessionData = try secureRandomData(count: 16)
        let invitation = DeviceMigrationInvitation(
            protocolVersion: DeviceMigrationProtocol.version,
            sessionID: sessionData.deviceMigrationBase64URL,
            sourcePublicKey:
                privateKey.publicKey.x963Representation,
            expiresAt: now.addingTimeInterval(
                DeviceMigrationProtocol.invitationLifetime
            )
        )
        return DeviceMigrationSourceHandshake(
            invitation: invitation,
            privateKey: privateKey
        )
    }

    static func makeReceiverHandshake(
        invitation: DeviceMigrationInvitation
    ) throws -> DeviceMigrationReceiverHandshake {
        guard invitation.protocolVersion
                == DeviceMigrationProtocol.version else {
            throw DeviceMigrationError.unsupportedProtocol
        }
        guard !invitation.isExpired else {
            throw DeviceMigrationError.expiredInvitation
        }

        let sourcePublicKey: P256.KeyAgreement.PublicKey
        do {
            sourcePublicKey = try P256.KeyAgreement.PublicKey(
                x963Representation: invitation.sourcePublicKey
            )
        } catch {
            throw DeviceMigrationError.invalidInvitation
        }

        let receiverPrivateKey = P256.KeyAgreement.PrivateKey()
        let receiverPublicKey =
            receiverPrivateKey.publicKey.x963Representation
        let encryptionKey = try derivedKey(
            privateKey: receiverPrivateKey,
            publicKey: sourcePublicKey,
            sessionID: invitation.sessionID
        )
        let authenticationTag = Data(
            HMAC<SHA256>.authenticationCode(
                for: joinAuthenticationData(
                    invitation: invitation,
                    receiverPublicKey: receiverPublicKey
                ),
                using: encryptionKey
            )
        )
        return DeviceMigrationReceiverHandshake(
            joinRequest: DeviceMigrationJoinRequest(
                protocolVersion: DeviceMigrationProtocol.version,
                sessionID: invitation.sessionID,
                receiverPublicKey: receiverPublicKey,
                authenticationTag: authenticationTag
            ),
            encryptionKey: encryptionKey
        )
    }

    static func accept(
        joinRequest: DeviceMigrationJoinRequest,
        sourceHandshake: DeviceMigrationSourceHandshake
    ) throws -> SymmetricKey {
        let invitation = sourceHandshake.invitation
        guard !invitation.isExpired else {
            throw DeviceMigrationError.expiredInvitation
        }
        guard joinRequest.protocolVersion
                == DeviceMigrationProtocol.version,
              joinRequest.sessionID == invitation.sessionID
        else {
            throw DeviceMigrationError.authenticationFailed
        }

        let receiverPublicKey: P256.KeyAgreement.PublicKey
        do {
            receiverPublicKey = try P256.KeyAgreement.PublicKey(
                x963Representation: joinRequest.receiverPublicKey
            )
        } catch {
            throw DeviceMigrationError.authenticationFailed
        }
        let encryptionKey = try derivedKey(
            privateKey: sourceHandshake.privateKey,
            publicKey: receiverPublicKey,
            sessionID: invitation.sessionID
        )
        let authenticated = HMAC<SHA256>.isValidAuthenticationCode(
            joinRequest.authenticationTag,
            authenticating: joinAuthenticationData(
                invitation: invitation,
                receiverPublicKey: joinRequest.receiverPublicKey
            ),
            using: encryptionKey
        )
        guard authenticated else {
            throw DeviceMigrationError.authenticationFailed
        }
        return encryptionKey
    }

    static func seal<Value: Encodable>(
        _ value: Value,
        domain: String,
        sessionID: String,
        using key: SymmetricKey
    ) throws -> Data {
        let plaintext = try encode(value)
        let sealedBox = try ChaChaPoly.seal(
            plaintext,
            using: key,
            authenticating: associatedData(
                domain: domain,
                sessionID: sessionID
            )
        )
        return sealedBox.combined
    }

    static func open<Value: Decodable>(
        _ type: Value.Type,
        sealedData: Data,
        domain: String,
        sessionID: String,
        using key: SymmetricKey
    ) throws -> Value {
        do {
            let sealedBox = try ChaChaPoly.SealedBox(
                combined: sealedData
            )
            let plaintext = try ChaChaPoly.open(
                sealedBox,
                using: key,
                authenticating: associatedData(
                    domain: domain,
                    sessionID: sessionID
                )
            )
            return try decode(type, from: plaintext)
        } catch {
            throw DeviceMigrationError.transferIntegrityFailed
        }
    }

    static func encode<Value: Encodable>(
        _ value: Value
    ) throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try encoder.encode(value)
    }

    static func decode<Value: Decodable>(
        _ type: Value.Type,
        from data: Data
    ) throws -> Value {
        try PropertyListDecoder().decode(type, from: data)
    }

    private static func derivedKey(
        privateKey: P256.KeyAgreement.PrivateKey,
        publicKey: P256.KeyAgreement.PublicKey,
        sessionID: String
    ) throws -> SymmetricKey {
        let sharedSecret: SharedSecret
        do {
            sharedSecret = try privateKey.sharedSecretFromKeyAgreement(
                with: publicKey
            )
        } catch {
            throw DeviceMigrationError.authenticationFailed
        }
        return sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data(sessionID.utf8),
            sharedInfo: keyAgreementInfo,
            outputByteCount: 32
        )
    }

    private static func joinAuthenticationData(
        invitation: DeviceMigrationInvitation,
        receiverPublicKey: Data
    ) -> Data {
        var data = Data()
        append(
            UInt64(invitation.protocolVersion),
            to: &data
        )
        append(Data(invitation.sessionID.utf8), to: &data)
        append(invitation.sourcePublicKey, to: &data)
        append(receiverPublicKey, to: &data)
        append(
            UInt64(
                invitation.expiresAt.timeIntervalSince1970
                    .rounded(.down)
            ),
            to: &data
        )
        return data
    }

    private static func associatedData(
        domain: String,
        sessionID: String
    ) -> Data {
        Data(
            "aperture.device-migration.v1|\(sessionID)|\(domain)".utf8
        )
    }

    private static func append(
        _ value: UInt64,
        to data: inout Data
    ) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) {
            data.append(contentsOf: $0)
        }
    }

    private static func append(
        _ value: Data,
        to data: inout Data
    ) {
        append(UInt64(value.count), to: &data)
        data.append(value)
    }

    private static func secureRandomData(count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(
            kSecRandomDefault,
            bytes.count,
            &bytes
        )
        guard status == errSecSuccess else {
            throw DeviceMigrationError.authenticationFailed
        }
        return Data(bytes)
    }
}
