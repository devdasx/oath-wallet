import Foundation
import GRDB

enum AppRootPhase: Equatable {
    case startup
    case onboarding
    case launchAuthentication(
        PersistedWalletIdentity,
        WalletSecuritySettings
    )
    case launchSecurityUnavailable(
        PersistedWalletIdentity,
        WalletPasscodeCredentialIssue
    )
    case launchRestorationUnavailable(
        AppLaunchWalletRestorationFailure
    )
    case wallet
}

enum AppLaunchWalletSelectionIssue: Error, Equatable, Sendable {
    case missingSelectedWallet(activeWalletCount: Int)
    case multipleSelectedWallets(count: Int)
    case selectedWalletMissingEnabledAccount
    case selectedWalletHasEmptyAddress

    var diagnosticCode: String {
        switch self {
        case let .missingSelectedWallet(activeWalletCount):
            "missing_selection_active_count_\(activeWalletCount)"
        case let .multipleSelectedWallets(count):
            "multiple_selections_count_\(count)"
        case .selectedWalletMissingEnabledAccount:
            "selected_wallet_missing_enabled_account"
        case .selectedWalletHasEmptyAddress:
            "selected_wallet_empty_address"
        }
    }
}

enum AppLaunchWalletSelection: Equatable, Sendable {
    case noWallets
    case selected(
        PersistedWalletIdentity,
        activeWalletCount: Int
    )
    case inconsistent(AppLaunchWalletSelectionIssue)
}

extension WalletDatabase {
    /// Resolves the launch selection in one database snapshot.
    ///
    /// Only a successful read proving that no active wallets exist may
    /// produce `.noWallets`. Existing but inconsistent wallet records remain
    /// distinguishable from a fresh installation.
    func appLaunchWalletSelection() async throws
        -> AppLaunchWalletSelection {
        try await pool.read { database in
            let wallets = try DBWalletRecord
                .filter(Column("profileID") == Self.defaultProfileID)
                .filter(Column("archivedAt") == nil)
                .fetchAll(database)

            guard !wallets.isEmpty else {
                return .noWallets
            }

            let selectedWallets = wallets.filter(\.isSelected)
            guard selectedWallets.count == 1 else {
                if selectedWallets.isEmpty {
                    return .inconsistent(
                        .missingSelectedWallet(
                            activeWalletCount: wallets.count
                        )
                    )
                }
                return .inconsistent(
                    .multipleSelectedWallets(
                        count: selectedWallets.count
                    )
                )
            }

            let wallet = selectedWallets[0]
            guard let account = try DBWalletAccountRecord
                .filter(Column("walletID") == wallet.id)
                .filter(Column("isEnabled") == true)
                .order(
                    sql:
                        "CASE WHEN networkID = 'eth' THEN 0 ELSE 1 END, createdAt"
                )
                .fetchOne(database)
            else {
                return .inconsistent(
                    .selectedWalletMissingEnabledAccount
                )
            }

            let address = account.address.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard !address.isEmpty else {
                return .inconsistent(
                    .selectedWalletHasEmptyAddress
                )
            }

            return .selected(
                PersistedWalletIdentity(
                    walletID: wallet.id,
                    address: address
                ),
                activeWalletCount: wallets.count
            )
        }
    }
}

struct AppLaunchWalletRestorationPayload: Sendable {
    let identity: PersistedWalletIdentity
    let walletName: String
    let walletAppearanceColor: WalletAppearanceColor
    let capabilities: WalletCapabilities
    let cachedSnapshot: WalletHomeSnapshot?
}

enum AppLaunchWalletRestorationOutcome: Sendable {
    case noWallets
    case wallet(AppLaunchWalletRestorationPayload)
    case failed(AppLaunchWalletRestorationFailure)
}

enum AppLaunchWalletRestorationStage: String, Sendable {
    case selection
    case capabilities
    case walletMetadata = "wallet_metadata"
    case cachedSnapshot = "cached_snapshot"
    case accountAddresses = "account_addresses"
}

struct AppLaunchWalletRestorationFailure: Hashable, Sendable {
    let messageKey: String
    let diagnosticCode: String

    init(
        issue: AppLaunchWalletSelectionIssue
    ) {
        self.init(
            messageKey: "wallet.launch.restore.error.inconsistent",
            diagnosticCode: "selection_\(issue.diagnosticCode)"
        )
    }

    init(
        error: any Error,
        stage: AppLaunchWalletRestorationStage
    ) {
        let prefix = stage.rawValue

        if let issue = error as? AppLaunchWalletSelectionIssue {
            self.init(issue: issue)
            return
        }

        if let databaseError = error as? DatabaseError {
            let code = databaseError.extendedResultCode.rawValue
            switch databaseError.resultCode {
            case .SQLITE_BUSY, .SQLITE_LOCKED:
                self.init(
                    messageKey:
                        "wallet.launch.restore.error.database_busy",
                    diagnosticCode:
                        "\(prefix)_sqlite_busy_\(code)"
                )
            case .SQLITE_CORRUPT, .SQLITE_NOTADB:
                self.init(
                    messageKey:
                        "wallet.launch.restore.error.database_integrity",
                    diagnosticCode:
                        "\(prefix)_sqlite_integrity_\(code)"
                )
            case .SQLITE_CANTOPEN, .SQLITE_IOERR, .SQLITE_READONLY,
                 .SQLITE_PERM, .SQLITE_FULL:
                self.init(
                    messageKey:
                        "wallet.launch.restore.error.database_unavailable",
                    diagnosticCode:
                        "\(prefix)_sqlite_unavailable_\(code)"
                )
            default:
                self.init(
                    messageKey: "wallet.launch.restore.error.database",
                    diagnosticCode: "\(prefix)_sqlite_\(code)"
                )
            }
            return
        }

        if let managementError = error as? WalletManagementError {
            switch managementError {
            case .walletNotFound, .addressUnavailable:
                self.init(
                    messageKey:
                        "wallet.launch.restore.error.inconsistent",
                    diagnosticCode:
                        "\(prefix)_wallet_record_inconsistent"
                )
            default:
                self.init(
                    messageKey: "wallet.launch.restore.error.database",
                    diagnosticCode:
                        "\(prefix)_wallet_metadata_unavailable"
                )
            }
            return
        }

        if let storeError = error as? WalletDataStoreError {
            self.init(
                messageKey:
                    "wallet.launch.restore.error.inconsistent",
                diagnosticCode:
                    "\(prefix)_data_store_\(Self.storeCode(storeError))"
            )
            return
        }

        if let cocoaError = error as? CocoaError {
            self.init(
                messageKey:
                    "wallet.launch.restore.error.database_unavailable",
                diagnosticCode:
                    "\(prefix)_cocoa_\(cocoaError.errorCode)"
            )
            return
        }

        self.init(
            messageKey: "wallet.launch.restore.error.database",
            diagnosticCode:
                "\(prefix)_unexpected_\(Self.sanitizedTypeName(type(of: error)))"
        )
    }

    private init(
        messageKey: String,
        diagnosticCode: String
    ) {
        self.messageKey = messageKey
        self.diagnosticCode = diagnosticCode
    }

    var supportURL: URL? {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = WalletSupport.emailAddress
        components.queryItems = [
            URLQueryItem(
                name: "subject",
                value: WalletLocalization.string(
                    "wallet.persistence.support.subject"
                )
            ),
            URLQueryItem(
                name: "body",
                value: EnglishNumbers.localized(
                    "wallet.launch.restore.support.body",
                    diagnosticCode
                )
            )
        ]
        return components.url
    }

    private static func storeCode(
        _ error: WalletDataStoreError
    ) -> String {
        switch error {
        case .invalidAddress:
            "invalid_address"
        case .missingRecord:
            "missing_record"
        case .invalidMainnet:
            "invalid_mainnet"
        case .invalidState:
            "invalid_state"
        }
    }

    private static func sanitizedTypeName(
        _ type: Any.Type
    ) -> String {
        String(reflecting: type)
            .lowercased()
            .map { character in
                character.isLetter || character.isNumber
                    ? character
                    : "_"
            }
            .reduce(into: "") { result, character in
                if character != "_" || result.last != "_" {
                    result.append(character)
                }
            }
            .prefix(80)
            .description
    }
}

private struct AppLaunchWalletStageError:
    Error,
    @unchecked Sendable {
    let stage: AppLaunchWalletRestorationStage
    let underlying: any Error
}

struct AppLaunchWalletRestorationService: Sendable {
    typealias LoadSelection =
        @Sendable () async throws -> AppLaunchWalletSelection
    typealias LoadCapabilities =
        @Sendable (String) async throws -> WalletCapabilities
    typealias LoadWallet =
        @Sendable (String) async throws -> ManagedWallet
    typealias LoadSnapshot =
        @Sendable (String) async throws -> WalletHomeSnapshot?

    private let loadSelection: LoadSelection
    private let loadCapabilities: LoadCapabilities
    private let loadWallet: LoadWallet
    private let loadSnapshot: LoadSnapshot

    init(database: WalletDatabase) {
        loadSelection = {
            try await database.appLaunchWalletSelection()
        }
        loadCapabilities = { walletID in
            try await database.walletCapabilities(walletID: walletID)
        }
        loadWallet = { walletID in
            try await database.managedWallet(walletID: walletID)
        }
        loadSnapshot = { walletID in
            try await database.cachedWalletSnapshot(walletID: walletID)
        }
    }

    init(
        loadSelection: @escaping LoadSelection,
        loadCapabilities: @escaping LoadCapabilities,
        loadWallet: @escaping LoadWallet,
        loadSnapshot: @escaping LoadSnapshot
    ) {
        self.loadSelection = loadSelection
        self.loadCapabilities = loadCapabilities
        self.loadWallet = loadWallet
        self.loadSnapshot = loadSnapshot
    }

    func restore() async -> AppLaunchWalletRestorationOutcome {
        let selection: AppLaunchWalletSelection
        do {
            selection = try await loadSelection()
        } catch {
            let failure = AppLaunchWalletRestorationFailure(
                error: error,
                stage: .selection
            )
            return .failed(failure)
        }

        switch selection {
        case .noWallets:
            return .noWallets
        case let .inconsistent(issue):
            let failure = AppLaunchWalletRestorationFailure(
                issue: issue
            )
            return .failed(failure)
        case let .selected(identity, _):
            do {
                async let capabilities = load(stage: .capabilities) {
                    try await loadCapabilities(identity.walletID)
                }
                async let wallet = load(stage: .walletMetadata) {
                    try await loadWallet(identity.walletID)
                }
                async let snapshot = load(stage: .cachedSnapshot) {
                    try await loadSnapshot(identity.walletID)
                }

                let (
                    restoredCapabilities,
                    restoredWallet,
                    cachedSnapshot
                ) = try await (capabilities, wallet, snapshot)

                return .wallet(
                    AppLaunchWalletRestorationPayload(
                        identity: identity,
                        walletName: restoredWallet.name,
                        walletAppearanceColor:
                            restoredWallet.appearanceColor,
                        capabilities: restoredCapabilities,
                        cachedSnapshot: cachedSnapshot
                    )
                )
            } catch {
                let stageError = error as? AppLaunchWalletStageError
                let stage = stageError?.stage ?? .selection
                let underlying = stageError?.underlying ?? error
                let failure = AppLaunchWalletRestorationFailure(
                    error: underlying,
                    stage: stage
                )
                return .failed(failure)
            }
        }
    }

    private func load<Value: Sendable>(
        stage: AppLaunchWalletRestorationStage,
        operation: @Sendable () async throws -> Value
    ) async throws -> Value {
        do {
            return try await operation()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw AppLaunchWalletStageError(
                stage: stage,
                underlying: error
            )
        }
    }
}
