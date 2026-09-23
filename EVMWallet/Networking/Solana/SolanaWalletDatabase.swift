import Foundation
import GRDB
import WalletCore

struct SolanaSecretDerivationAuthorization: Sendable {
    private let walletID: String

    fileprivate init(walletID: String) {
        self.walletID = walletID
    }

    func permits(walletID: String) -> Bool {
        self.walletID == walletID
    }
}

extension WalletDatabase {
    func solanaHistoryCursors(
        walletID: String
    ) async throws -> [String: SolanaHistoryCursor] {
        try await pool.read { database in
            let rows = try Row.fetchAll(
                database,
                sql: """
                SELECT
                    state.address,
                    state.newestSignature,
                    state.oldestSignature,
                    state.providerHistoryComplete,
                    account.label
                FROM solanaSyncState AS state
                JOIN walletAccounts AS account
                    ON account.id = state.accountID
                WHERE account.walletID = ?
                """,
                arguments: [walletID]
            )
            return Dictionary(
                uniqueKeysWithValues: rows.compactMap { row in
                    let address: String = row["address"]
                    let label: String = row["label"]
                    guard
                        let kind = SolanaDerivationKind(rawValue: label)
                    else {
                        return nil
                    }
                    return (
                        address,
                        SolanaHistoryCursor(
                            queriedAddress: address,
                            ownerKind: kind,
                            newestSignature: row["newestSignature"],
                            oldestSignature: row["oldestSignature"],
                            providerHistoryComplete:
                                row["providerHistoryComplete"]
                        )
                    )
                }
            )
        }
    }

    func ensureSolanaAccounts(
        walletID: String
    ) async throws -> SolanaAccountSet {
        let stored = try await pool.read { database in
            return (
                wallet: try DBWalletRecord.fetchOne(
                    database,
                    key: walletID
                ),
                accounts: try DBWalletAccountRecord
                    .filter(Column("walletID") == walletID)
                    .filter(
                        Column("networkID")
                            == SolanaConstants.networkID
                    )
                    .filter(Column("isEnabled") == true)
                    .fetchAll(database)
            )
        }
        guard let wallet = stored.wallet else {
            throw WalletCreationPersistenceError.missingSecret
        }
        if let accountSet = Self.persistedSolanaAccountSet(
            accounts: stored.accounts,
            walletKind: wallet.kind
        ) {
            return accountSet
        }
        let authorization = SolanaSecretDerivationAuthorization(
            walletID: walletID
        )
        let materials: [SolanaAccountMaterial]
        if wallet.kind == DatabaseWalletKind.importedPrivateKey.rawValue {
            let account = stored.accounts.first
            guard let account else {
                throw WalletCreationPersistenceError.invalidDraft
            }
            let data = try await privateKeyData(
                walletID: walletID,
                authorization: authorization
            )
            guard let key = PrivateKey(data: data) else {
                throw SolanaProviderError.accountDerivationUnavailable
            }
            let material = try Self.solanaMaterial(
                    kind: .phantom,
                    privateKey: key,
                    derivationPath: account.derivationPath
                )
            guard material.address == account.address else {
                throw WalletCreationPersistenceError.invalidDraft
            }
            materials = [material]
        } else {
            let credential = try await recoveryCredential(
                walletID: walletID,
                authorization: authorization
            )
            guard let hdWallet = credential.makeHDWallet() else {
                throw WalletCreationPersistenceError.missingSecret
            }
            materials = try SolanaDerivationKind.allCases.map { kind in
                guard let key = hdWallet.getKey(
                    coin: .solana,
                    derivationPath: kind.derivationPath
                ) else {
                    throw SolanaProviderError.accountDerivationUnavailable
                }
                return try Self.solanaMaterial(
                    kind: kind,
                    privateKey: key,
                    derivationPath: kind.derivationPath
                )
            }
        }
        guard let primary = materials.first else {
            throw SolanaProviderError.accountDerivationUnavailable
        }

        let now = Date().timeIntervalSince1970
        try await pool.write { database in
            let accountIDs = materials.map {
                Self.solanaAccountID(
                    walletID: walletID,
                    kind: $0.kind
                )
            }
            let existingByID = Dictionary(
                uniqueKeysWithValues: try DBWalletAccountRecord
                    .filter(accountIDs.contains(Column("id")))
                    .fetchAll(database)
                    .map { ($0.id, $0) }
            )
            for material in materials {
                let accountID = Self.solanaAccountID(
                    walletID: walletID,
                    kind: material.kind
                )
                let existing = existingByID[accountID]
                guard existing == nil || existing?.isEnabled == false else {
                    continue
                }
                try DBWalletAccountRecord(
                    id: accountID,
                    walletID: walletID,
                    networkID: SolanaConstants.networkID,
                    address: material.address,
                    normalizedAddress: material.address,
                    label: material.kind.rawValue,
                    derivationPath: material.derivationPath,
                    accountIndex: existing?.accountIndex ?? 0,
                    publicKey: material.publicKey,
                    isWatchOnly: false,
                    isEnabled: true,
                    createdAt: existing?.createdAt ?? now,
                    updatedAt: now,
                    lastSyncedAt: existing?.lastSyncedAt
                ).save(database)
            }
        }
        return SolanaAccountSet(
            primary: primary,
            alternatives: Array(materials.dropFirst())
        )
    }

    private static func persistedSolanaAccountSet(
        accounts: [DBWalletAccountRecord],
        walletKind: String
    ) -> SolanaAccountSet? {
        let materials = accounts.compactMap {
            account -> SolanaAccountMaterial? in
            guard
                let label = account.label,
                let kind = SolanaDerivationKind(rawValue: label),
                CoinType.solana.validate(address: account.address),
                let publicKey = account.publicKey,
                !publicKey.isEmpty
            else {
                return nil
            }
            return SolanaAccountMaterial(
                kind: kind,
                address: account.address,
                publicKey: publicKey,
                derivationPath: account.derivationPath
            )
        }
        if walletKind == DatabaseWalletKind.importedPrivateKey.rawValue {
            guard let primary = materials.first, materials.count == 1 else {
                return nil
            }
            return SolanaAccountSet(primary: primary, alternatives: [])
        }
        let byKind = Dictionary(
            uniqueKeysWithValues: materials.map { ($0.kind, $0) }
        )
        guard
            let primary = byKind[.phantom],
            byKind.count == SolanaDerivationKind.allCases.count
        else {
            return nil
        }
        return SolanaAccountSet(
            primary: primary,
            alternatives: SolanaDerivationKind.allCases
                .filter { $0 != .phantom }
                .compactMap { byKind[$0] }
        )
    }

    static func solanaAccountID(
        walletID: String,
        kind: SolanaDerivationKind
    ) -> String {
        "\(walletID):solana:\(kind.rawValue):0"
    }

    private static func solanaMaterial(
        kind: SolanaDerivationKind,
        privateKey: PrivateKey,
        derivationPath: String?
    ) throws -> SolanaAccountMaterial {
        let address = CoinType.solana.deriveAddress(privateKey: privateKey)
        guard CoinType.solana.validate(address: address) else {
            throw SolanaProviderError.accountDerivationUnavailable
        }
        return SolanaAccountMaterial(
            kind: kind,
            address: address,
            publicKey: privateKey.getPublicKeyEd25519()
                .data.base64EncodedString(),
            derivationPath: derivationPath
        )
    }
}
