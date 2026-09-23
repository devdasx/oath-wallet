import Foundation
import GRDB

enum DatabaseWalletKind: String, Codable, Sendable {
    case created
    case importedRecoveryPhrase
    case importedPrivateKey
    case watchOnly
    case hardware
}

enum WalletDefaultName {
    static let maximumLength = 64

    static func isLegacyGenericName(_ name: String) -> Bool {
        legacyGenericNames.contains(name)
    }

    static func normalizedCustomName(_ name: String) -> String? {
        let trimmedName = name.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !trimmedName.isEmpty,
              trimmedName.count <= maximumLength
        else {
            return nil
        }
        return trimmedName
    }

    static func next(
        for kind: DatabaseWalletKind,
        privateKeyNetwork: PrivateKeyImportNetwork? = nil,
        profileID: String,
        database: Database
    ) throws -> String {
        let existingNames = Set(
            try String.fetchAll(
                database,
                sql: """
                SELECT name
                FROM wallets
                WHERE profileID = ? AND archivedAt IS NULL
                """,
                arguments: [profileID]
            )
        )
        return next(
            for: kind,
            privateKeyNetwork: privateKeyNetwork,
            excluding: existingNames
        )
    }

    static func next(
        for kind: DatabaseWalletKind,
        privateKeyNetwork: PrivateKeyImportNetwork? = nil,
        excluding existingNames: Set<String>
    ) -> String {
        let baseName = baseName(
            for: kind,
            privateKeyNetwork: privateKeyNetwork
        )
        if !existingNames.contains(baseName) {
            return baseName
        }

        var suffix = 2
        while existingNames.contains("\(baseName) \(suffix)") {
            suffix += 1
        }
        return "\(baseName) \(suffix)"
    }

    static func baseName(
        for kind: DatabaseWalletKind,
        privateKeyNetwork: PrivateKeyImportNetwork? = nil
    ) -> String {
        if kind == .importedPrivateKey, let privateKeyNetwork {
            return privateKeyBaseName(for: privateKeyNetwork)
        }

        return switch kind {
        case .created:
            WalletLocalization.string("wallet.name.created")
        case .importedRecoveryPhrase:
            WalletLocalization.string("wallet.name.imported")
        case .importedPrivateKey:
            WalletLocalization.string("wallet.name.private_key")
        case .watchOnly:
            WalletLocalization.string("wallet.name.watch_only")
        case .hardware:
            WalletLocalization.string("wallet.name.hardware")
        }
    }

    static func privateKeyBaseName(
        for network: PrivateKeyImportNetwork
    ) -> String {
        String(
            format: WalletLocalization.string(
                "wallet.name.private_key.chain_format"
            ),
            locale: WalletAppLanguage.locale(
                for: WalletAppLanguage.selectedIdentifier
            ),
            network.localizedWalletNameTitle
        )
    }

    static var legacyGenericNames: Set<String> {
        let key = "wallet.home.wallet.name.default"
        var values: Set<String> = [
            "Main Wallet",
            WalletLocalization.string(key)
        ]

        for localization in Bundle.main.localizations {
            guard let path = Bundle.main.path(
                forResource: localization,
                ofType: "lproj"
            ),
            let bundle = Bundle(path: path)
            else {
                continue
            }
            let value = bundle.localizedString(
                forKey: key,
                value: "",
                table: nil
            )
            if !value.isEmpty, value != key {
                values.insert(value)
            }
        }
        return values
    }

    static func migrateLegacyImportedNames(
        in database: Database
    ) throws {
        let wallets = try DBWalletRecord
            .filter(Column("archivedAt") == nil)
            .order(
                Column("profileID"),
                Column("createdAt"),
                Column("sortOrder")
            )
            .fetchAll(database)
        var reservedNames = Dictionary(
            grouping: wallets,
            by: \.profileID
        ).mapValues { Set($0.map(\.name)) }
        let updatedAt = Date().timeIntervalSince1970

        for var wallet in wallets
        where wallet.kind
            == DatabaseWalletKind.importedRecoveryPhrase.rawValue
            && isLegacyImportedGeneratedName(wallet.name)
        {
            var profileNames = reservedNames[wallet.profileID, default: []]
            profileNames.remove(wallet.name)
            wallet.name = next(
                for: .importedRecoveryPhrase,
                excluding: profileNames
            )
            wallet.updatedAt = updatedAt
            profileNames.insert(wallet.name)
            reservedNames[wallet.profileID] = profileNames
            try wallet.update(database)
        }
    }

    static func isLegacyImportedGeneratedName(_ name: String) -> Bool {
        legacyImportedBaseNames.contains { baseName in
            guard name != baseName else { return true }

            let numberedPrefix = baseName + " "
            guard name.hasPrefix(numberedPrefix) else { return false }

            let suffix = name.dropFirst(numberedPrefix.count)
            guard let number = Int(suffix), number >= 2 else { return false }
            return suffix == String(number)
        }
    }

    private static let legacyImportedBaseNames: Set<String> = [
        "Restored Wallet",
        "መልሶ የተገኘ ዋሌት",
        "محفظة مستعادة",
        "পুনরুদ্ধার করা ওয়ালেট",
        "Obnovená peněženka",
        "Gendannet wallet",
        "Wiederhergestellte Wallet",
        "Επαναφερμένο πορτοφόλι",
        "Cartera restaurada",
        "کیف پول بازیابی‌شده",
        "Palautettu lompakko",
        "Na-restore na Wallet",
        "Portefeuille restauré",
        "પુનઃસ્થાપિત વૉલેટ",
        "Walat da Aka Farfado",
        "ארנק משוחזר",
        "रीस्टोर किया गया वॉलेट",
        "Helyreállított tárca",
        "Dompet yang Dipulihkan",
        "Portafoglio ripristinato",
        "復元したウォレット",
        "កាបូបដែលបានសង្គ្រោះ",
        "ಮರುಸ್ಥಾಪಿಸಿದ ವ್ಯಾಲೆಟ್",
        "복원한 지갑",
        "പുനഃസ്ഥാപിച്ച വാലറ്റ്",
        "पुनर्संचयित वॉलेट",
        "ပြန်လည်ရယူထားသော ပိုက်ဆံအိတ်",
        "पुनर्स्थापित वालेट",
        "Herstelde wallet",
        "ପୁନରୁଦ୍ଧାର ହୋଇଥିବା ୱାଲେଟ୍",
        "ਮੁੜ ਪ੍ਰਾਪਤ ਕੀਤਾ ਵਾਲਿਟ",
        "Przywrócony portfel",
        "Carteira restaurada",
        "Portofel restaurat",
        "Восстановленный кошелёк",
        "بحال ٿيل والٽ",
        "ප්‍රතිසාධනය කළ පසුම්බිය",
        "Återställd plånbok",
        "Pochi Iliyorejeshwa",
        "மீட்டெடுக்கப்பட்ட வாலெட்",
        "పునరుద్ధరించిన వాలెట్",
        "กระเป๋าเงินที่กู้คืน",
        "Geri yüklenen cüzdan",
        "Відновлений гаманець",
        "بحال شدہ والیٹ",
        "Tiklangan hamyon",
        "Ví đã khôi phục",
        "Àpamọ́wọ́ Tí A Mú Padà",
        "已復原的錢包",
    ]
}

enum DatabaseWalletBackupState: String, Codable, Sendable {
    case notVerified
    case verified
}

enum DatabaseAssetType: String, Codable, Sendable {
    case native
    case fungibleToken
    case nonFungibleToken
    case semiFungibleToken
}

struct DBProfileRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "profiles"

    let id: String
    var displayName: String?
    let createdAt: Double
    var updatedAt: Double
    var lastActiveAt: Double
}

struct DBWalletRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "wallets"

    let id: String
    let profileID: String
    var name: String
    let kind: String
    var secretKeyReference: String?
    var isSelected: Bool
    var sortOrder: Int
    let createdAt: Double
    var updatedAt: Double
    var lastOpenedAt: Double?
    var archivedAt: Double?
    var backupState: String = DatabaseWalletBackupState.notVerified.rawValue
    var backupVerifiedAt: Double? = nil
    var mnemonicWordCount: Int? = nil
    var iCloudBackupUpdatedAt: Double? = nil
    var iCloudBackupVerificationVersion: Int = 0
    var iCloudBackupRecordChangeTag: String? = nil
    var iCloudBackupWalletID: String? = nil
    var notificationsEnabledWhenInactive: Bool = false
    var appearanceColorID: String? = WalletAppearanceColor.blue.rawValue
    var accountDerivationVersion: Int = 0
}

struct DBProfileSecurityRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "profileSecurity"

    let profileID: String
    var passcodeKeychainReference: String
    var failedAttemptCount: Int
    var lockedUntil: Double?
    var updatedAt: Double
}

struct DBNetworkRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "networks"

    let id: String
    let chainID: Int64
    let nameKey: String
    let nativeSymbol: String
    let trustWalletBlockchain: String
    let rpcProviderIdentifier: String
    let isMainnet: Bool
    let isEnabled: Bool
    let sortOrder: Int
    let createdAt: Double
    let updatedAt: Double
}

struct DBWalletAccountRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "walletAccounts"

    let id: String
    let walletID: String
    let networkID: String
    let address: String
    let normalizedAddress: String
    var label: String?
    var derivationPath: String?
    var accountIndex: Int?
    var publicKey: String?
    let isWatchOnly: Bool
    var isEnabled: Bool
    let createdAt: Double
    var updatedAt: Double
    var lastSyncedAt: Double?
}

struct DBAssetRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "assets"

    let id: String
    let networkID: String
    let assetType: String
    let contractAddress: String
    let normalizedContractAddress: String
    var name: String
    var symbol: String
    var decimals: Int?
    var trustWalletBlockchain: String?
    var trustWalletContractAddress: String?
    var logoURL: String? = nil
    var logoOrigin: String? = nil
    var isVerified: Bool
    var isSpam: Bool
    let createdAt: Double
    var updatedAt: Double
    var metadataUpdatedAt: Double?
}

struct DBAccountAssetRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "accountAssets"

    let accountID: String
    let assetID: String
    var balance: String
    var balanceAtomic: String?
    var fiatUSDValue: String?
    var isEnabled: Bool
    var isPinned: Bool
    var isHidden: Bool
    var sortOrder: Int?
    var firstSeenAt: Double
    var lastSeenAt: Double
    var updatedAt: Double
}

struct DBAssetPriceRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "assetPrices"

    let assetID: String
    let quoteCurrency: String
    let price: String
    let provider: String
    let observedAt: Double
    let expiresAt: Double?
}

struct DBMarketSnapshotRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "marketSnapshots"

    let assetID: String
    let quoteCurrency: String
    let provider: String
    let observedAt: Double
    var marketCap: String?
    var fullyDilutedValue: String?
    var volume24Hours: String?
    var change24HoursPercent: String?
    var high24Hours: String?
    var low24Hours: String?
    var circulatingSupply: String?
    var totalSupply: String?
    var maximumSupply: String?
    var marketRank: Int?
}

struct DBTransactionRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "transactions"

    let id: String
    let accountID: String
    let networkID: String
    let transactionHash: String
    let normalizedTransactionHash: String
    let kind: String
    let status: String
    let direction: String
    var fromAddress: String?
    var toAddress: String?
    var counterpartyAddress: String?
    var blockNumber: Int64?
    var blockHash: String?
    var transactionIndex: Int64?
    var nonce: Int64?
    var transactionType: Int64?
    var timestamp: Double?
    var assetID: String?
    var assetSymbol: String
    var secondaryAssetSymbol: String?
    var assetAmount: String
    var fiatUSDValue: String?
    var networkFee: String?
    var networkFeeFiatUSDValue: String?
    var networkFeeSymbol: String?
    var gasPriceGwei: String?
    var gasLimit: Int64?
    var gasUsed: Int64?
    var inputData: String?
    var methodName: String?
    var displayDetail: String
    var displayTime: String
    let firstSeenAt: Double
    var updatedAt: Double
    var observedStatus: String? = nil
    var replacementTransactionHash: String? = nil
}

struct DBTransactionTransferRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "transactionTransfers"

    let id: String
    let transactionID: String
    var logIndex: Int?
    var assetID: String?
    var fromAddress: String?
    var toAddress: String?
    let direction: String
    let amount: String
    var amountAtomic: String?
    var fiatUSDValue: String?
    var tokenName: String?
    var tokenSymbol: String
    var tokenDecimals: Int?
}

struct DBTransactionNoteRecord: Codable, FetchableRecord,
    PersistableRecord, Sendable {
    static let databaseTableName = "transactionNotes"

    let transactionID: String
    var note: String
    let createdAt: Double
    var updatedAt: Double
}

struct DBFXRateRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "fxRates"

    let baseCurrency: String
    let quoteCurrency: String
    let rate: String
    let englishName: String
    let symbol: String
    let effectiveDate: String
    let provider: String
    let fetchedAt: Double
}

struct DBUserSettingsRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "userSettings"

    let profileID: String
    var appearance: String
    var languageIdentifier: String
    var currencyCode: String
    var currencyRatePerUSD: String
    var balancePrivacyEnabled: Bool
    var appLockEnabled: Bool
    var biometricEnabled: Bool
    var autoLockSeconds: Int?
    var privacyShieldEnabled: Bool
    var notificationsEnabled: Bool
    var updateNotificationsEnabled: Bool
    var priceNotificationsEnabled: Bool
    var transferNotificationsEnabled: Bool
    var receivedTransactionNotificationsEnabled: Bool = true
    var sentTransactionNotificationsEnabled: Bool = false
    var adminNotificationsEnabled: Bool = true
    var analyticsEnabled: Bool
    var updatedAt: Double
}

struct DBPreferenceRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "preferences"

    let profileID: String
    let key: String
    let valueType: String
    let value: String
    let updatedAt: Double
}

struct DBSyncStateRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "syncStates"

    let accountID: String
    let resource: String
    var cursor: String?
    var lastAttemptAt: Double?
    var lastSuccessAt: Double?
    var nextAllowedAt: Double?
    var consecutiveFailureCount: Int
    var lastErrorCode: String?
}

struct DBAPICacheRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "apiCache"

    let cacheKey: String
    let provider: String
    let endpoint: String
    let payload: Data
    let createdAt: Double
    let expiresAt: Double
    var etag: String?
    var lastModified: String?
}

struct DBSolanaTokenEligibilityRecord:
    Codable,
    FetchableRecord,
    PersistableRecord,
    Sendable
{
    static let databaseTableName = "solanaTokenEligibility"

    let mint: String
    let name: String?
    let symbol: String?
    let decimals: Int?
    let isVerified: Bool
    let liquidityUSD: String?
    let isSuspicious: Bool
    let isEligible: Bool
    let reason: String
    let provider: String
    let observedAt: Double
    let expiresAt: Double
}

struct DBNFTCollectionRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "nftCollections"

    let id: String
    let networkID: String
    let contractAddress: String
    let normalizedContractAddress: String
    var name: String
    var symbol: String?
    let standard: String
    var imageURL: String?
    var isVerified: Bool
    var isSpam: Bool
    var updatedAt: Double
}

struct DBNFTItemRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "nftItems"

    let id: String
    let collectionID: String
    let tokenID: String
    var name: String?
    var description: String?
    var imageURL: String?
    var animationURL: String?
    var metadataURL: String?
    var metadataJSON: Data?
    var updatedAt: Double
}

struct DBAccountNFTHoldingRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "accountNFTHoldings"

    let accountID: String
    let nftItemID: String
    var quantity: String
    var isHidden: Bool
    var lastSeenAt: Double
}

struct DBContactRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "contacts"

    let id: String
    let profileID: String
    var name: String
    var note: String?
    let createdAt: Double
    var updatedAt: Double
}

struct DBContactAddressRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "contactAddresses"

    let id: String
    let contactID: String
    var networkID: String?
    var address: String
    var normalizedAddress: String
    var label: String?
    var isFavorite: Bool
    let createdAt: Double
}

struct DBConnectedDAppRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "connectedDApps"

    let id: String
    let profileID: String
    let origin: String
    var name: String
    var iconURL: String?
    var sessionTopic: String?
    let createdAt: Double
    var lastUsedAt: Double
    var expiresAt: Double?
}

struct DBDAppPermissionRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "dappPermissions"

    let dappID: String
    let accountID: String
    let method: String
    let chainID: Int64
    let grantedAt: Double
}

struct DBPriceAlertRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "priceAlerts"

    let id: String
    let profileID: String
    let assetID: String
    let quoteCurrency: String
    let comparison: String
    let threshold: String
    var isEnabled: Bool
    let createdAt: Double
    var lastTriggeredAt: Double?
}

struct DBNotificationRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "notifications"

    let id: String
    let profileID: String
    let category: String
    let titleKey: String
    let bodyKey: String
    var argumentsJSON: Data?
    var relatedTransactionID: String?
    let createdAt: Double
    var readAt: Double?
    var deliveredAt: Double?
    var remoteNotificationID: String? = nil
    var titleText: String? = nil
    var bodyText: String? = nil
    var walletID: String? = nil
    var networkID: String? = nil
    var transactionHash: String? = nil
    var openedAt: Double? = nil
    var assetSymbol: String? = nil
}

struct DBNotificationProfileRecord: Codable, FetchableRecord,
    PersistableRecord, Sendable {
    static let databaseTableName = "notificationProfiles"

    let profileID: String
    var remoteUserID: String
    var installationID: String?
    var reconciliationNeeded: Bool
    var reconciliationGeneration: Int64
    var lastSnapshotDigest: String?
    var lastRegistrationAttemptAt: Double?
    var lastRegistrationSuccessAt: Double?
    var lastRegistrationErrorCode: String?
    var historyBackfillCursor: String? = nil
    var updatedAt: Double
}

struct DBNotificationOpenAuditRecord: Codable, FetchableRecord,
    PersistableRecord, Sendable {
    static let databaseTableName = "notificationOpenAudits"

    let notificationID: String
    let createdAt: Double
    var attemptCount: Int
    var lastAttemptAt: Double?
    var nextAttemptAt: Double
    var lastErrorCode: String?
}

struct DBPendingOperationRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "pendingOperations"

    let id: String
    let accountID: String
    let operationType: String
    var state: String
    var payload: Data
    let idempotencyKey: String
    var retryCount: Int
    let createdAt: Double
    var updatedAt: Double
    var nextRetryAt: Double?
    var lastErrorCode: String?
}

struct DBTagRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "tags"

    let id: String
    let profileID: String
    var name: String
    let createdAt: Double
}

struct DBTransactionTagRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "transactionTags"

    let transactionID: String
    let tagID: String
}
