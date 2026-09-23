import Foundation

enum DeviceMigrationProtocol {
    static let version = 2
    static let serviceType = "aperture-xfer"
    static let invitationLifetime: TimeInterval = 3 * 60
    static let connectionTimeout: TimeInterval = 45
    static let transferTimeout: TimeInterval = 15 * 60
    static let maximumDatabaseByteCount: Int64 = 512 * 1_024 * 1_024
    static let maximumSecretByteCount = 2 * 1_024 * 1_024
    static let maximumWireMessageByteCount =
        maximumSecretByteCount + 64 * 1_024

    static func databaseResourceName(transferID: String) -> String {
        "aperture-\(transferID).sqlite"
    }
}

struct DeviceMigrationInvitation: Hashable, Sendable {
    let protocolVersion: Int
    let sessionID: String
    let sourcePublicKey: Data
    let expiresAt: Date

    var qrPayload: String {
        var components = URLComponents()
        components.scheme = "aperture"
        components.host = "device-transfer"
        components.queryItems = [
            URLQueryItem(
                name: "v",
                value: String(protocolVersion)
            ),
            URLQueryItem(name: "s", value: sessionID),
            URLQueryItem(
                name: "k",
                value: sourcePublicKey.deviceMigrationBase64URL
            ),
            URLQueryItem(
                name: "e",
                value: String(
                    Int64(expiresAt.timeIntervalSince1970.rounded(.down))
                )
            )
        ]
        return components.string ?? ""
    }

    var isExpired: Bool {
        Date() >= expiresAt
    }

    static func parse(
        _ payload: String,
        now: Date = Date()
    ) throws -> Self {
        guard
            let components = URLComponents(string: payload),
            components.scheme?.lowercased() == "aperture",
            components.host?.lowercased() == "device-transfer"
        else {
            throw DeviceMigrationError.invalidInvitation
        }

        let items = Dictionary(
            components.queryItems?.compactMap { item in
                item.value.map { (item.name, $0) }
            } ?? [],
            uniquingKeysWith: { first, _ in first }
        )
        guard
            let versionText = items["v"],
            let version = Int(versionText),
            version == DeviceMigrationProtocol.version,
            let sessionID = items["s"],
            let sessionData = Data(
                deviceMigrationBase64URL: sessionID
            ),
            sessionData.count == 16,
            let publicKeyText = items["k"],
            let publicKey = Data(
                deviceMigrationBase64URL: publicKeyText
            ),
            publicKey.count == 65,
            let expiryText = items["e"],
            let expirySeconds = Int64(expiryText)
        else {
            throw DeviceMigrationError.invalidInvitation
        }

        let expiresAt = Date(
            timeIntervalSince1970: TimeInterval(expirySeconds)
        )
        guard expiresAt > now,
              expiresAt.timeIntervalSince(now)
                <= DeviceMigrationProtocol.invitationLifetime + 5
        else {
            throw DeviceMigrationError.expiredInvitation
        }

        return Self(
            protocolVersion: version,
            sessionID: sessionID,
            sourcePublicKey: publicKey,
            expiresAt: expiresAt
        )
    }
}

struct DeviceMigrationJoinRequest: Codable, Sendable {
    let protocolVersion: Int
    let sessionID: String
    let receiverPublicKey: Data
    let authenticationTag: Data
}

struct DeviceMigrationManifest: Codable, Sendable {
    let protocolVersion: Int
    let transferID: String
    let createdAt: Double
    let sourceAppVersion: String
    let sourceAppBuild: String
    let databaseMigrationIdentifiers: [String]
    let databaseByteCount: Int64
    let databaseSHA256: Data
    let walletCount: Int
    let walletSecretCount: Int
}

enum DeviceMigrationWalletSecretKind: String, Codable, Sendable {
    case recoveryPhrase
    case privateKey
    case muunRecovery
    case bitcoinImportedWallet

    var vaultKind: WalletSecretKind {
        switch self {
        case .recoveryPhrase:
            .recoveryPhrase
        case .privateKey:
            .privateKey
        case .bitcoinImportedWallet:
            .bitcoinImportedWallet
        case .muunRecovery:
            .muunRecovery
        }
    }
}

struct DeviceMigrationWalletSecret: Codable, Sendable {
    let walletID: String
    let kind: DeviceMigrationWalletSecretKind
    let data: Data
}

struct DeviceMigrationSecretsBundle: Codable, Sendable {
    let protocolVersion: Int
    let walletSecrets: [DeviceMigrationWalletSecret]
}

struct DeviceMigrationPreparedExport: Sendable {
    let databaseURL: URL
    let manifest: DeviceMigrationManifest
    let secrets: DeviceMigrationSecretsBundle
}

struct DeviceMigrationIncomingPackage: Identifiable, Sendable {
    let databaseURL: URL
    let manifest: DeviceMigrationManifest
    let secrets: DeviceMigrationSecretsBundle

    var id: String { manifest.transferID }
}

struct DeviceMigrationImportResult: Sendable {
    let selectedWallet: PersistedWalletIdentity
    let walletCount: Int
    let applicationSettings: WalletApplicationSettings
}

enum DeviceMigrationWireKind: String, Codable, Sendable {
    case manifest
    case secrets
    case transferComplete
    case receipt
}

struct DeviceMigrationWireMessage: Codable, Sendable {
    let protocolVersion: Int
    let kind: DeviceMigrationWireKind
    let sealedPayload: Data?
}

struct DeviceMigrationTransferComplete: Codable, Sendable {
    let transferID: String
}

struct DeviceMigrationReceipt: Codable, Sendable {
    let transferID: String
    let succeeded: Bool
    let diagnosticCode: String?
}

enum DeviceMigrationError: Error, Equatable, Sendable {
    case invalidInvitation
    case expiredInvitation
    case unsupportedProtocol
    case authenticationFailed
    case authorizationExpired
    case noWallets
    case silentPaymentRecoveryRequired
    case incompleteSecretSet
    case invalidWalletSecret
    case databaseTooLarge
    case invalidDatabase
    case incompatibleDatabase
    case destinationNotEmpty
    case connectionTimedOut
    case transferTimedOut
    case peerDisconnected
    case transportFailed
    case transferIntegrityFailed
    case importFailed
    case cancelled

    var diagnosticCode: String {
        switch self {
        case .invalidInvitation:
            "invalid_invitation"
        case .expiredInvitation:
            "expired_invitation"
        case .unsupportedProtocol:
            "unsupported_protocol"
        case .authenticationFailed:
            "authentication_failed"
        case .authorizationExpired:
            "authorization_expired"
        case .silentPaymentRecoveryRequired:
            "silent_payment_recovery_required"
        case .noWallets:
            "no_wallets"
        case .incompleteSecretSet:
            "incomplete_secret_set"
        case .invalidWalletSecret:
            "invalid_wallet_secret"
        case .databaseTooLarge:
            "database_too_large"
        case .invalidDatabase:
            "invalid_database"
        case .incompatibleDatabase:
            "incompatible_database"
        case .destinationNotEmpty:
            "destination_not_empty"
        case .connectionTimedOut:
            "connection_timed_out"
        case .transferTimedOut:
            "transfer_timed_out"
        case .peerDisconnected:
            "peer_disconnected"
        case .transportFailed:
            "transport_failed"
        case .transferIntegrityFailed:
            "transfer_integrity_failed"
        case .importFailed:
            "import_failed"
        case .cancelled:
            "cancelled"
        }
    }

    var userMessageKey: String {
        switch self {
        case .invalidInvitation:
            "device_migration.error.invitation.invalid"
        case .expiredInvitation:
            "device_migration.error.invitation.expired"
        case .unsupportedProtocol, .incompatibleDatabase:
            "device_migration.error.version"
        case .destinationNotEmpty:
            "device_migration.error.destination_not_empty"
        case .connectionTimedOut:
            "device_migration.error.connection_timeout"
        case .transferTimedOut:
            "device_migration.error.transfer_timeout"
        case .peerDisconnected:
            "device_migration.error.disconnected"
        case .databaseTooLarge:
            "device_migration.error.database_too_large"
        case .silentPaymentRecoveryRequired:
            "bitcoin.silent.known_outputs_only"
        case .noWallets:
            "device_migration.error.no_wallets"
        case .authenticationFailed, .authorizationExpired:
            "device_migration.error.authentication"
        case .invalidDatabase, .transferIntegrityFailed,
             .incompleteSecretSet, .invalidWalletSecret:
            "device_migration.error.verification"
        case .transportFailed:
            "device_migration.error.transport"
        case .importFailed:
            "device_migration.error.import"
        case .cancelled:
            "device_migration.error.cancelled"
        }
    }
}

extension Data {
    var deviceMigrationBase64URL: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(deviceMigrationBase64URL value: String) {
        let remainder = value.count % 4
        let padding = remainder == 0
            ? ""
            : String(repeating: "=", count: 4 - remainder)
        let base64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
            + padding
        self.init(base64Encoded: base64)
    }
}
