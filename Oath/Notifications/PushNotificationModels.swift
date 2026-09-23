import Foundation

enum PushServiceDate {
    private static let parser = PushServiceDateParser()

    static func parse(_ value: String) -> Date? {
        parser.parse(value)
    }
}

private final class PushServiceDateParser: @unchecked Sendable {
    private let lock = NSLock()
    private let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds
        ]
        return formatter
    }()
    private let standard = ISO8601DateFormatter()

    func parse(_ value: String) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        return fractional.date(from: value)
            ?? standard.date(from: value)
    }
}

struct PushNotificationPreferences: Codable, Equatable, Sendable {
    let master: Bool
    let received: Bool
    let sent: Bool
    let admin: Bool
}

struct PushRegisteredAccount: Codable, Equatable, Sendable {
    let accountID: String
    let networkID: String
    let chainID: String
    let monitoredAddresses: [PushMonitoredAddress]
}

struct PushMonitoredAddress: Codable, Equatable, Sendable {
    let address: String
    let normalizedAddress: String
    let role: String
}

struct PushRegisteredWallet: Codable, Equatable, Sendable {
    let walletID: String
    let name: String
    let kind: String
    let notificationMonitoringEnabled: Bool
    let accounts: [PushRegisteredAccount]
}

struct PushInstallationSnapshotRequest: Codable, Equatable, Sendable {
    let remoteUserID: String
    let installationID: String
    let apnsToken: String
    let environment: String
    let locale: String
    let currencyCode: String
    let currencyRatePerUSDBase10: String
    let appVersion: String
    let osVersion: String
    let deviceModel: String
    let preferences: PushNotificationPreferences
    let wallets: [PushRegisteredWallet]
}

struct PushRegistrationChallengeRequest:
    Codable, Equatable, Sendable {
    let installationID: String
    let apnsToken: String
}

struct PushRegistrationChallengeResponse:
    Codable, Equatable, Sendable {
    let challenge: String
    let expiresAt: String
    let serverTime: String
}

struct PushInstallationBootstrapRequest: Codable, Equatable, Sendable {
    let remoteUserID: String
    let installationID: String
    let bootstrapCredential: String
    let apnsToken: String
    let environment: String
    let locale: String
    let currencyCode: String
    let currencyRatePerUSDBase10: String
    let appVersion: String
    let osVersion: String
    let deviceModel: String
    let preferences: PushNotificationPreferences
    let wallets: [PushRegisteredWallet]

    init(
        snapshot: PushInstallationSnapshotRequest,
        bootstrapCredential: String
    ) {
        remoteUserID = snapshot.remoteUserID
        installationID = snapshot.installationID
        self.bootstrapCredential = bootstrapCredential
        apnsToken = snapshot.apnsToken
        environment = snapshot.environment
        locale = snapshot.locale
        currencyCode = snapshot.currencyCode
        currencyRatePerUSDBase10 =
            snapshot.currencyRatePerUSDBase10
        appVersion = snapshot.appVersion
        osVersion = snapshot.osVersion
        deviceModel = snapshot.deviceModel
        preferences = snapshot.preferences
        wallets = snapshot.wallets
    }
}

struct PushInstallationSnapshotResponse: Codable, Equatable, Sendable {
    let snapshotDigest: String
    let registeredAt: String
    let serverTime: String
}

enum PushNotificationHistoryState: String, Codable, Sendable {
    case sent
    case opened
}

struct PushNotificationHistoryItem: Codable, Equatable, Sendable {
    let notificationID: String
    let category: PushNotificationCategory
    let state: PushNotificationHistoryState
    let titleKey: String
    let bodyKey: String
    let arguments: [String]
    let title: String?
    let body: String?
    let walletID: String?
    let networkID: String?
    let transactionHash: String?
    let assetSymbol: String?
    let createdAt: String
    let sentAt: String?
    let openedAt: String?
}

struct PushNotificationHistoryResponse:
    Codable, Equatable, Sendable {
    let items: [PushNotificationHistoryItem]
    let nextCursor: String?
    let serverTime: String
}

struct PushInstallationIdentity: Codable, Equatable, Sendable {
    let installationID: String
    let credential: Data
    var apnsToken: Data?
    var remoteUserID: String? = nil
    var apnsTopic: String? = nil
    var apnsEnvironment: String? = nil

    mutating func bindAPNSContext(
        topic: String,
        environment: String
    ) -> Bool {
        guard apnsTopic != topic || apnsEnvironment != environment else {
            return false
        }
        apnsToken = nil
        apnsTopic = topic
        apnsEnvironment = environment
        return true
    }
}

struct PushDeactivationTombstone: Codable, Equatable, Sendable {
    let installationID: String
    let credential: Data
    let createdAt: Date
}

enum PushNotificationCategory: String, Codable, Sendable {
    case received
    case sent
    case admin
}

struct PushNotificationRoute: Equatable, Sendable {
    let notificationID: String
    let category: PushNotificationCategory
    let walletID: String?
    let networkID: String?
    let transactionHash: String?
}

struct PushNotificationDisplayContent: Equatable, Sendable {
    let title: String
    let body: String
    var assetSymbol: String? = nil
}


enum PushReconciliationReason: String, Sendable {
    case appActivation
    case apnsTokenChanged
    case preferencesChanged
    case walletChanged
    case chainSynchronization
    case deviceMigration
    case retry
}

enum PushAuthorizationState: Equatable, Sendable {
    case unknown
    case notDetermined
    case authorized
    case denied
    case provisional
    case ephemeral
}

enum PushNotificationMasterPreferenceAction: Equatable, Sendable {
    case none
    case enableFromSystemAuthorization
    case disableForSystemAuthorization

    static func resolve(
        authorizationState: PushAuthorizationState,
        notificationsEnabled: Bool,
        explicitlyDisabled: Bool
    ) -> Self {
        if explicitlyDisabled {
            return notificationsEnabled
                ? .disableForSystemAuthorization
                : .none
        }

        switch authorizationState {
        case .authorized, .provisional, .ephemeral:
            return notificationsEnabled
                ? .none
                : .enableFromSystemAuthorization
        case .notDetermined, .denied:
            return notificationsEnabled
                ? .disableForSystemAuthorization
                : .none
        case .unknown:
            return .none
        }
    }
}

enum PushRegistrationState: Equatable, Sendable {
    case idle
    case waitingForPermission
    case waitingForDeviceToken
    case registering
    case registered
    case failed(String)
}

struct PushNotificationPayload: Equatable, Sendable {
    let notificationID: String
    let category: PushNotificationCategory
    let walletID: String?
    let networkID: String?
    let transactionHash: String?
    let localizationKey: String?
    let assetSymbol: String?
    let titleKey: String
    let bodyKey: String
    let localizationArguments: [String]
    let createdAt: Double?

    init?(userInfo: [AnyHashable: Any]) {
        guard let notificationID = Self.string(
            userInfo["notificationID"] ?? userInfo["notification_id"]
        ), UUID(uuidString: notificationID) != nil else {
            return nil
        }

        self.notificationID = notificationID
        let parsedCategory = Self.string(
            userInfo["kind"] ?? userInfo["category"]
        )
        .flatMap(PushNotificationCategory.init(rawValue:))
            ?? .admin
        category = parsedCategory
        walletID = Self.validIdentifier(
            userInfo["walletID"] ?? userInfo["wallet_id"]
        )
        networkID = Self.validIdentifier(
            userInfo["networkID"] ?? userInfo["network_id"]
        )
        transactionHash = Self.validTransactionHash(
            userInfo["transactionHash"] ?? userInfo["transaction_hash"]
        )
        localizationKey = Self.validLocalizationKey(
            userInfo["localizationKey"] ?? userInfo["localization_key"]
        )
        let alert = Self.alertDictionary(userInfo["aps"])
        assetSymbol = Self.validAssetSymbol(
            userInfo["assetSymbol"] ?? userInfo["asset_symbol"]
                ?? (alert?["title-loc-args"] as? [String])?.first
        )
        titleKey = Self.payloadLocalizationKey(
            userInfo["titleKey"]
                ?? userInfo["title_key"]
                ?? alert?["title-loc-key"],
            fallback: Self.defaultTitleKey(for: parsedCategory)
        )
        bodyKey = Self.payloadBodyLocalizationKey(
            userInfo["bodyKey"]
                ?? userInfo["body_key"]
                ?? alert?["loc-key"],
            category: parsedCategory
        )
        localizationArguments = Self.arguments(
            userInfo["localizationArguments"] ?? userInfo["arguments"] ?? alert?["loc-args"]
        )
        createdAt = Self.timestamp(
            userInfo["createdAt"] ?? userInfo["created_at"]
        )
    }

    private static func defaultTitleKey(
        for category: PushNotificationCategory
    ) -> String {
        switch category {
        case .received:
            "notification.received.title"
        case .sent:
            "notification.sent.title"
        case .admin:
            "notification.generic.title"
        }
    }

    private static func defaultBodyKey(
        for category: PushNotificationCategory
    ) -> String {
        switch category {
        case .received:
            "notification.received.body"
        case .sent:
            "notification.sent.body"
        case .admin:
            "notification.generic.body"
        }
    }

    private static func payloadLocalizationKey(
        _ value: Any?,
        fallback: String
    ) -> String {
        guard let key = validLocalizationKey(value),
              key == fallback else {
            return fallback
        }
        return key
    }

    private static func payloadBodyLocalizationKey(
        _ value: Any?,
        category: PushNotificationCategory
    ) -> String {
        let fallback = defaultBodyKey(for: category)
        guard let key = validLocalizationKey(value) else {
            return fallback
        }
        let allowed: Set<String> = switch category {
        case .received:
            [
                "notification.received.body",
                "notification.received.body.unpriced",
                "notification.received.body.priced"
            ]
        case .sent:
            [
                "notification.sent.body",
                "notification.sent.body.v2"
            ]
        case .admin:
            ["notification.generic.body"]
        }
        return allowed.contains(key) ? key : fallback
    }

    private static func alertDictionary(
        _ apsValue: Any?
    ) -> [String: Any]? {
        let aps: [String: Any]
        if let values = apsValue as? [String: Any] {
            aps = values
        } else if let values = apsValue as? [AnyHashable: Any] {
            aps = Dictionary(
                uniqueKeysWithValues: values.compactMap {
                    key, value in
                    guard let key = key as? String else {
                        return nil
                    }
                    return (key, value)
                }
            )
        } else {
            return nil
        }

        if let alert = aps["alert"] as? [String: Any] {
            return alert
        }
        guard let values = aps["alert"] as? [AnyHashable: Any]
        else {
            return nil
        }
        return Dictionary(
            uniqueKeysWithValues: values.compactMap { key, value in
                guard let key = key as? String else { return nil }
                return (key, value)
            }
        )
    }

    private static func arguments(_ value: Any?) -> [String] {
        guard let values = value as? [Any],
              values.count <= 12 else {
            return []
        }
        let strings = values.compactMap { $0 as? String }
        guard strings.count == values.count,
              strings.allSatisfy({ $0.utf8.count <= 1_000 }) else {
            return []
        }
        return strings
    }

    private static func validAssetSymbol(_ value: Any?) -> String? {
        guard let value = string(value), value.utf8.count <= 256 else { return nil }
        return value
    }

    private static func validIdentifier(_ value: Any?) -> String? {
        guard let value = string(value), value.utf8.count <= 128 else {
            return nil
        }
        let allowed = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: "_.:@+-")
        )
        return value.unicodeScalars.allSatisfy(allowed.contains)
            ? value
            : nil
    }

    private static func validTransactionHash(_ value: Any?) -> String? {
        guard let value = string(value), value.utf8.count <= 256 else {
            return nil
        }
        let allowed = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: "_:-")
        )
        return value.unicodeScalars.allSatisfy(allowed.contains)
            ? value
            : nil
    }

    private static func validLocalizationKey(_ value: Any?) -> String? {
        guard let value = string(value), value.utf8.count <= 160 else {
            return nil
        }
        let allowed = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: "._-")
        )
        return value.unicodeScalars.allSatisfy(allowed.contains)
            ? value
            : nil
    }

    private static func timestamp(_ value: Any?) -> Double? {
        if let number = value as? NSNumber {
            let result = number.doubleValue
            return result.isFinite && result >= 0 ? result : nil
        }
        guard let value = string(value) else { return nil }
        if let number = Double(value) {
            return number.isFinite && number >= 0 ? number : nil
        }
        return PushServiceDate.parse(value)?
            .timeIntervalSince1970
    }

    private static func string(_ value: Any?) -> String? {
        guard let value = value as? String, !value.isEmpty else {
            return nil
        }
        return value
    }
}
