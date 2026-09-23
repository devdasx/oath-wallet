import Foundation
import GRDB
import WalletCore

struct BitcoinFamilySecretDerivationAuthorization: Sendable {
    private let walletID: String

    init(walletID: String) {
        self.walletID = walletID
    }

    func permits(walletID: String) -> Bool {
        self.walletID == walletID
    }
}

private struct BitcoinFamilyPersistedHistoryEntry: Sendable {
    let source: BitcoinFamilyHistoryEntry
    let amountText: String
    let amountProjection: Decimal?
    let feeText: String?
    let feeProjection: Decimal?
}

enum BitcoinFamilyPersistenceError: Error, Equatable, Sendable {
    case missingAccount(String)
    case missingAsset(String)
}

extension WalletDatabase {
    func bitcoinFamilyPersistedBalance(
        walletID: String,
        chain: BitcoinFamilyChain = .bitcoin
    ) async throws -> BitcoinFamilyAtomicInteger? {
        let accountID = "\(walletID):\(chain.networkID):0"
        let assetID = "\(chain.networkID):native"
        let atomicText = try await pool.read { database in
            try DBAccountAssetRecord.fetchOne(
                database,
                key: ["accountID": accountID, "assetID": assetID]
            )?.balanceAtomic
        }
        return try atomicText.map(BitcoinFamilyAtomicInteger.init(validating:))
    }

    /// Persists the spendable Bitcoin-family balance independently from
    /// history and remote price enrichment. Electrum's `confirmed` and
    /// `unconfirmed` values are already combined by the caller, so pending
    /// receives become visible as soon as the balance RPC completes.
    func saveBitcoinFamilyBalance(
        _ balanceAtomic: BitcoinFamilyAtomicInteger,
        material: BitcoinFamilyAccountMaterial,
        walletID: String
    ) async throws {
        guard !balanceAtomic.isNegative else {
            throw BitcoinFamilyElectrumError.invalidResponse
        }
        let chain = material.chain
        let accountID = "\(walletID):\(chain.networkID):0"
        let assetID = "\(chain.networkID):native"
        let balanceText = try balanceAtomic.userUnits(decimals: 8)
        let now = Date().timeIntervalSince1970

        try await pool.write { database in
            // Read the quote and write the balance in one transaction. A quote
            // arriving between separate read/write operations must not leave
            // the new balance valued with the previous (possibly zero) amount.
            let fiatText = try Self.cachedFiatUSDValue(
                amountText: balanceText,
                assetID: assetID,
                fallback: nil,
                database: database
            )
            var holding = try Self.bitcoinFamilyHolding(
                database,
                accountID: accountID,
                assetID: assetID,
                chain: chain,
                balance: balanceText,
                balanceAtomic: balanceAtomic.decimalText,
                fiatUSDValue: fiatText,
                now: now
            )
            holding.balance = balanceText
            holding.balanceAtomic = balanceAtomic.decimalText
            if let fiatText {
                holding.fiatUSDValue = fiatText
            }
            holding.lastSeenAt = now
            holding.updatedAt = now
            try holding.save(database)
            try database.execute(
                sql: """
                UPDATE walletAccounts
                SET lastSyncedAt = ?, updatedAt = ?
                WHERE id = ?
                """,
                arguments: [now, now, accountID]
            )
        }
    }

    /// Revalues the already-persisted native holding and activity after the
    /// independent price task completes. This keeps quote networking off the
    /// balance critical path while still publishing a second, fiat-complete
    /// snapshot during the same refresh.
    func saveBitcoinFamilyValuation(
        _ quote: AssetUSDPrice,
        material: BitcoinFamilyAccountMaterial,
        walletID: String
    ) async throws {
        let chain = material.chain
        let accountID = "\(walletID):\(chain.networkID):0"
        let assetID = "\(chain.networkID):native"
        guard quote.assetID == assetID, quote.price >= 0 else {
            throw AssetPriceError.invalidResponse
        }
        let locale = Locale(identifier: "en_US_POSIX")
        let now = Date().timeIntervalSince1970

        try await pool.write { database in
            if var holding = try DBAccountAssetRecord.fetchOne(
                database,
                key: ["accountID": accountID, "assetID": assetID]
            ), let balance = Decimal(
                string: holding.balance,
                locale: locale
            ) {
                holding.fiatUSDValue = NSDecimalNumber(
                    decimal: balance * quote.price
                ).stringValue
                holding.updatedAt = now
                try holding.update(database)
            }

            let transactions = try DBTransactionRecord
                .filter(Column("accountID") == accountID)
                .filter(Column("assetID") == assetID)
                .fetchAll(database)
            for var transaction in transactions {
                if let amount = Decimal(
                    string: transaction.assetAmount,
                    locale: locale
                ) {
                    transaction.fiatUSDValue = NSDecimalNumber(
                        decimal: amount * quote.price
                    ).stringValue
                }
                if let fee = transaction.networkFee.flatMap({
                    Decimal(string: $0, locale: locale)
                }) {
                    transaction.networkFeeFiatUSDValue = NSDecimalNumber(
                        decimal: fee * quote.price
                    ).stringValue
                }
                transaction.updatedAt = now
                try transaction.update(database)
            }
        }
    }

    func ensureBitcoinFamilyAccounts(
        walletID: String
    ) async throws -> [BitcoinFamilyAccountMaterial] {
        let stored = try await pool.read { database in
            (
                wallet: try DBWalletRecord.fetchOne(
                    database,
                    key: walletID
                ),
                accounts: try DBWalletAccountRecord
                    .filter(Column("walletID") == walletID)
                    .filter(
                        BitcoinFamilyChain.allCases
                            .map(\.networkID)
                            .contains(Column("networkID"))
                    )
                    .filter(Column("isEnabled") == true)
                    .fetchAll(database)
            )
        }
        guard let wallet = stored.wallet else {
            throw WalletCreationPersistenceError.missingSecret
        }

        if let materials = Self.persistedBitcoinFamilyMaterials(
            accounts: stored.accounts,
            walletKind: wallet.kind
        ) {
            try await ensureBitcoinFamilyRows(
                materials,
                walletID: walletID
            )
            return materials
        }

        let authorization = BitcoinFamilySecretDerivationAuthorization(
            walletID: walletID
        )
        let materials: [BitcoinFamilyAccountMaterial]
        if wallet.kind == DatabaseWalletKind.importedPrivateKey.rawValue {
            let account = stored.accounts.first
            guard let account,
                  let chain = BitcoinFamilyChain(
                      rawValue: account.networkID
                  )
            else {
                throw WalletCreationPersistenceError.invalidDraft
            }
            let format = PrivateKeyImportFormat(
                accountMarker: account.derivationPath
            ) ?? .wifCompressed
            let material = try BitcoinFamilyDerivationService().derive(
                privateKey: try await privateKeyData(
                    walletID: walletID,
                    authorization: authorization
                ),
                chain: chain,
                format: format,
                derivationPath: account.derivationPath
            )
            guard material.address == account.address else {
                throw WalletCreationPersistenceError.invalidDraft
            }
            materials = [material]
        } else {
            materials = try BitcoinFamilyDerivationService().derive(
                credential: try await recoveryCredential(
                    walletID: walletID,
                    authorization: authorization
                )
            )
        }

        try await ensureBitcoinFamilyRows(
            materials,
            walletID: walletID
        )
        return materials
    }

    private func ensureBitcoinFamilyRows(
        _ materials: [BitcoinFamilyAccountMaterial],
        walletID: String
    ) async throws {
        let now = Date().timeIntervalSince1970
        try await pool.write { database in
            let accountIDs = materials.map {
                "\(walletID):\($0.chain.networkID):0"
            }
            let assetIDs = materials.map {
                "\($0.chain.networkID):native"
            }
            let accountsByID = Dictionary(
                uniqueKeysWithValues: try DBWalletAccountRecord
                    .filter(accountIDs.contains(Column("id")))
                    .fetchAll(database)
                    .map { ($0.id, $0) }
            )
            let assetsByID = Dictionary(
                uniqueKeysWithValues: try DBAssetRecord
                    .filter(assetIDs.contains(Column("id")))
                    .fetchAll(database)
                    .map { ($0.id, $0) }
            )
            let holdings = Set(
                try DBAccountAssetRecord
                    .filter(accountIDs.contains(Column("accountID")))
                    .filter(assetIDs.contains(Column("assetID")))
                    .fetchAll(database)
                    .map { "\($0.accountID)|\($0.assetID)" }
            )

            for (index, material) in materials.enumerated() {
                let accountID = "\(walletID):\(material.chain.networkID):0"
                let existingAccount = accountsByID[accountID]
                if existingAccount == nil
                    || existingAccount?.isEnabled == false
                {
                    try DBWalletAccountRecord(
                        id: accountID,
                        walletID: walletID,
                        networkID: material.chain.networkID,
                        address: material.address,
                        normalizedAddress: material.address.lowercased(),
                        label: existingAccount?.label,
                        derivationPath: material.derivationPath,
                        accountIndex: existingAccount?.accountIndex ?? 0,
                        publicKey: material.publicKey,
                        isWatchOnly: false,
                        isEnabled: true,
                        createdAt: existingAccount?.createdAt ?? now,
                        updatedAt: now,
                        lastSyncedAt: existingAccount?.lastSyncedAt
                    ).save(database)
                }

                let assetID = "\(material.chain.networkID):native"
                if assetsByID[assetID] == nil {
                    try DBAssetRecord(
                        id: assetID,
                        networkID: material.chain.networkID,
                        assetType: DatabaseAssetType.native.rawValue,
                        contractAddress: "",
                        normalizedContractAddress: "",
                        name: material.chain.name,
                        symbol: material.chain.symbol,
                        decimals: 8,
                        trustWalletBlockchain:
                            material.chain.blockchain.rawValue,
                        trustWalletContractAddress: nil,
                        isVerified: true,
                        isSpam: false,
                        createdAt: now,
                        updatedAt: now,
                        metadataUpdatedAt: now
                    ).insert(database)
                }
                if !holdings.contains("\(accountID)|\(assetID)") {
                    try DBAccountAssetRecord(
                        accountID: accountID,
                        assetID: assetID,
                        balance: "0",
                        balanceAtomic: "0",
                        fiatUSDValue: "0",
                        isEnabled: true,
                        isPinned: false,
                        isHidden: false,
                        sortOrder: index,
                        firstSeenAt: now,
                        lastSeenAt: now,
                        updatedAt: now
                    ).insert(database)
                }
            }
        }
    }

    private static func persistedBitcoinFamilyMaterials(
        accounts: [DBWalletAccountRecord],
        walletKind: String
    ) -> [BitcoinFamilyAccountMaterial]? {
        let materials = accounts.compactMap {
            account -> BitcoinFamilyAccountMaterial? in
            guard
                let chain = BitcoinFamilyChain(rawValue: account.networkID),
                chain.coin.validate(address: account.address),
                let publicKey = account.publicKey,
                !publicKey.isEmpty
            else {
                return nil
            }
            let script = BitcoinScript.lockScriptForAddress(
                address: account.address,
                coin: chain.coin
            ).data
            guard !script.isEmpty else { return nil }
            return BitcoinFamilyAccountMaterial(
                chain: chain,
                address: account.address,
                derivationPath: account.derivationPath,
                publicKey: publicKey,
                scriptPubKey: script
            )
        }
        if walletKind == DatabaseWalletKind.importedPrivateKey.rawValue {
            return materials.count == 1 ? materials : nil
        }
        let byChain: [BitcoinFamilyChain: BitcoinFamilyAccountMaterial] =
            Dictionary(
            uniqueKeysWithValues: materials.map { ($0.chain, $0) }
        )
        guard byChain.count == BitcoinFamilyChain.allCases.count else {
            return nil
        }
        return BitcoinFamilyChain.allCases.compactMap { byChain[$0] }
    }

    func saveBitcoinFamilySnapshot(
        _ snapshot: BitcoinFamilyChainSnapshot,
        walletID: String,
        preservingPersistedBalance: Bool = false
    ) async throws {
        let chain = snapshot.material.chain
        let accountID = "\(walletID):\(chain.networkID):0"
        let assetID = "\(chain.networkID):native"
        let balanceText = try snapshot.balanceAtomic.userUnits(decimals: 8)
        let balanceProjection = snapshot.balanceAtomic.decimalProjection(
            decimals: 8
        )
        let persistedHistory = try snapshot.history.map { entry in
            BitcoinFamilyPersistedHistoryEntry(
                source: entry,
                amountText: try entry.amountAtomic.userUnits(decimals: 8),
                amountProjection: entry.amountAtomic.decimalProjection(
                    decimals: 8
                ),
                feeText: try entry.feeAtomic?.userUnits(decimals: 8),
                feeProjection: entry.feeAtomic?.decimalProjection(
                    decimals: 8
                )
            )
        }
        let now = Date().timeIntervalSince1970

        try await pool.write { database in
            // Keep price lookup atomic with both balance and history writes.
            let price = try Self.latestValidUSDPriceRecord(
                assetID: assetID,
                database: database
            ).flatMap { Self.decimal($0.price) } ?? 0
            let fiatText = balanceProjection.map {
                NSDecimalNumber(decimal: $0 * price).stringValue
            }
            let transactionIDs = persistedHistory.map {
                "\(accountID):\($0.source.transactionHash)"
            }
            let existingTransactionsByID = Dictionary(
                uniqueKeysWithValues: try DBTransactionRecord
                    .filter(transactionIDs.contains(Column("id")))
                    .fetchAll(database)
                    .map { ($0.id, $0) }
            )
            let primaryTransfersByTransactionID = Dictionary(
                uniqueKeysWithValues: try DBTransactionTransferRecord
                    .filter(
                        transactionIDs.contains(Column("transactionID"))
                    )
                    .fetchAll(database)
                    .compactMap { transfer in
                        transfer.id == "\(transfer.transactionID)|primary"
                            ? (transfer.transactionID, transfer) : nil
                    }
            )
            let existingHolding = try DBAccountAssetRecord.fetchOne(
                database,
                key: ["accountID": accountID, "assetID": assetID]
            )
            if !preservingPersistedBalance || existingHolding == nil {
                var holding = try Self.bitcoinFamilyHolding(
                    database,
                    accountID: accountID,
                    assetID: assetID,
                    chain: chain,
                    balance: balanceText,
                    balanceAtomic: snapshot.balanceAtomic.decimalText,
                    fiatUSDValue: price > 0 ? fiatText : nil,
                    now: now
                )
                holding.balance = balanceText
                holding.balanceAtomic = snapshot.balanceAtomic.decimalText
                if price > 0, let fiatText {
                    holding.fiatUSDValue = fiatText
                }
                holding.lastSeenAt = now
                holding.updatedAt = now
                try holding.save(database)
            }

            for persisted in persistedHistory {
                let entry = persisted.source
                let id = "\(accountID):\(entry.transactionHash)"
                let confirmed = entry.height > 0
                let transactionFiat = persisted.amountProjection.map {
                    $0 * price
                }
                let existing = existingTransactionsByID[id]
                let transactionFiatText: String?
                if price > 0, let transactionFiat {
                    transactionFiatText = NSDecimalNumber(
                        decimal: transactionFiat
                    ).stringValue
                } else {
                    transactionFiatText = existing?.fiatUSDValue
                }
                let retainedTransfer = primaryTransfersByTransactionID[id]
                let retainedRecipient = existing?.toAddress
                    ?? retainedTransfer?.toAddress
                    ?? existing?.counterpartyAddress
                let retainedSender = existing?.fromAddress
                    ?? retainedTransfer?.fromAddress
                    ?? existing?.counterpartyAddress
                let fromAddress = entry.direction == "incoming"
                    ? (retainedSender ?? entry.identity?.fromAddress)
                    : (entry.identity?.fromAddress
                        ?? snapshot.material.address)
                let toAddress = entry.direction == "incoming"
                    ? (entry.identity?.toAddress
                        ?? snapshot.material.address)
                    : (retainedRecipient ?? entry.identity?.toAddress)
                let counterpartyAddress = entry.direction == "incoming"
                    ? fromAddress : toAddress
                try DBTransactionRecord(
                    id: id,
                    accountID: accountID,
                    networkID: chain.networkID,
                    transactionHash: entry.transactionHash,
                    normalizedTransactionHash:
                        entry.transactionHash.lowercased(),
                    kind: entry.direction == "incoming"
                        ? "received"
                        : "sent",
                    status: confirmed ? "confirmed" : "pending",
                    direction: entry.direction,
                    fromAddress: fromAddress,
                    toAddress: toAddress,
                    counterpartyAddress: counterpartyAddress,
                    blockNumber: confirmed ? entry.height : nil,
                    blockHash: nil,
                    transactionIndex: nil,
                    nonce: nil,
                    transactionType: nil,
                    timestamp: entry.timestamp ?? existing?.timestamp,
                    assetID: assetID,
                    assetSymbol: chain.symbol,
                    secondaryAssetSymbol: nil,
                    assetAmount:
                        retainedTransfer?.amount ?? persisted.amountText,
                    fiatUSDValue: transactionFiatText,
                    networkFee: persisted.feeText,
                    networkFeeFiatUSDValue:
                        persisted.feeProjection.flatMap {
                            price > 0
                                ? NSDecimalNumber(
                                    decimal: $0 * price
                                ).stringValue
                                : nil
                        } ?? existing?.networkFeeFiatUSDValue,
                    networkFeeSymbol: chain.symbol,
                    gasPriceGwei: nil,
                    gasLimit: nil,
                    gasUsed: nil,
                    inputData: nil,
                    methodName: nil,
                    displayDetail:
                        counterpartyAddress ?? entry.transactionHash,
                    displayTime: confirmed
                        ? WalletLocalization.string(
                            "wallet.activity.status.confirmed"
                        )
                        : WalletLocalization.string(
                            "wallet.activity.status.pending"
                        ),
                    firstSeenAt: existing?.firstSeenAt ?? now,
                    updatedAt: now
                ).save(database)
            }
            try database.execute(
                sql: """
                UPDATE walletAccounts
                SET lastSyncedAt = ?, updatedAt = ?
                WHERE id = ?
                """,
                arguments: [now, now, accountID]
            )
        }
    }

    private static func bitcoinFamilyHolding(
        _ database: Database,
        accountID: String,
        assetID: String,
        chain: BitcoinFamilyChain,
        balance: String,
        balanceAtomic: String,
        fiatUSDValue: String?,
        now: Double
    ) throws -> DBAccountAssetRecord {
        guard try DBWalletAccountRecord.fetchOne(
            database,
            key: accountID
        ) != nil else {
            throw BitcoinFamilyPersistenceError.missingAccount(accountID)
        }
        guard try DBAssetRecord.fetchOne(database, key: assetID) != nil else {
            throw BitcoinFamilyPersistenceError.missingAsset(assetID)
        }
        if let holding = try DBAccountAssetRecord.fetchOne(
            database,
            key: ["accountID": accountID, "assetID": assetID]
        ) {
            return holding
        }
        return DBAccountAssetRecord(
            accountID: accountID,
            assetID: assetID,
            balance: balance,
            balanceAtomic: balanceAtomic,
            fiatUSDValue: fiatUSDValue,
            isEnabled: true,
            isPinned: false,
            isHidden: false,
            sortOrder: BitcoinFamilyChain.allCases.firstIndex(of: chain),
            firstSeenAt: now,
            lastSeenAt: now,
            updatedAt: now
        )
    }

    func cachedWalletSnapshot(
        walletID: String
    ) async throws -> WalletHomeSnapshot? {
        try await pool.read {
            database -> WalletHomeSnapshot? in
            let accounts = try DBWalletAccountRecord
                .filter(Column("walletID") == walletID)
                .filter(Column("isEnabled") == true)
                .fetchAll(database)
            guard !accounts.isEmpty else { return nil }

            let accountByID = Dictionary(
                uniqueKeysWithValues: accounts.map { ($0.id, $0) }
            )
            let accountIDs = Array(accountByID.keys)
            let hasStoredActivity = try Self.hasStoredActivity(
                accountIDs: accountIDs,
                database: database
            )
            let persistedHoldings = try DBAccountAssetRecord
                .filter(accountIDs.contains(Column("accountID")))
                .filter(Column("isEnabled") == true)
                .fetchAll(database)
            let holdings = WalletHomeHoldingProjection.unifiedHoldings(
                persistedHoldings,
                accountByID: accountByID
            ).filter { !$0.isHidden }
            let transactions = try Self.cachedDisplayEligibleTransactions(
                accountIDs: accountIDs,
                database: database
            )
            let transactionIDs = transactions.map(\.id)
            let transactionNotes =
                transactionIDs.isEmpty
                    ? []
                    : try DBTransactionNoteRecord
                        .filter(
                            transactionIDs.contains(
                                Column("transactionID")
                            )
                        )
                        .fetchAll(database)
            let notesByTransactionID = Dictionary(
                uniqueKeysWithValues: transactionNotes.map {
                    ($0.transactionID, $0.note)
                }
            )
            let primaryTransfers = transactionIDs.isEmpty
                ? []
                : try DBTransactionTransferRecord
                    .filter(
                        transactionIDs.contains(Column("transactionID"))
                    )
                    .fetchAll(database)
            let primaryTransferByTransactionID = Dictionary(
                uniqueKeysWithValues: primaryTransfers.compactMap {
                    transfer
                        -> (String, DBTransactionTransferRecord)? in
                    transfer.id == "\(transfer.transactionID)|primary"
                        ? (transfer.transactionID, transfer) : nil
                }
            )

            let assetIDs = Array(
                Set(
                    holdings.map(\.assetID)
                        + transactions.compactMap(\.assetID)
                )
            )
            let assets = try DBAssetRecord
                .filter(assetIDs.contains(Column("id")))
                .fetchAll(database)
            let assetsByID = Dictionary(
                uniqueKeysWithValues: assets.map { ($0.id, $0) }
            )
            let networkIDs = Array(
                Set(
                    accounts.map(\.networkID)
                        + assets.map(\.networkID)
                        + transactions.map(\.networkID)
                )
            )
            let networkByID = Dictionary(
                uniqueKeysWithValues: try DBNetworkRecord
                    .filter(networkIDs.contains(Column("id")))
                    .fetchAll(database)
                    .map { ($0.id, $0) }
            )

            let walletAssets = holdings.compactMap { holding -> WalletAsset? in
                guard let asset = assetsByID[holding.assetID],
                      let account = accountByID[holding.accountID],
                      let networkRecord = networkByID[asset.networkID],
                      let network = WalletBlockchain(
                        rawValue: networkRecord.trustWalletBlockchain
                      ),
                      let exactBalance = ExactDecimalText.canonicalUnsigned(
                        holding.balance
                      ),
                      let fiat = Self.decimal(
                          holding.fiatUSDValue ?? "0"
                      ) else { return nil }
                let balance = Self.decimal(exactBalance) ?? 0
                return WalletAsset(
                    id: asset.id,
                    name: asset.name,
                    symbol: asset.symbol,
                    logoSource: Self.logoSource(
                        asset: asset,
                        fallbackNetwork: network
                    ),
                    network: network,
                    balance: balance,
                    fiatValue: fiat,
                    balanceText: exactBalance,
                    balanceAtomic: holding.balanceAtomic,
                    decimals: asset.decimals,
                    receiveAddress: account.address,
                    isPinned: holding.isPinned,
                    isVerified: asset.isVerified,
                    isSpam: asset.isSpam
                )
            }
            .sorted {
                if $0.fiatValue == $1.fiatValue {
                    return $0.symbol < $1.symbol
                }
                return $0.fiatValue > $1.fiatValue
            }

            let walletTransactions = transactions.compactMap {
                transaction -> WalletTransaction? in
                guard Self.isDisplayEligibleTransaction(
                    transaction,
                    assetsByID: assetsByID
                ) else {
                    return nil
                }
                return Self.walletTransaction(
                    transaction,
                    assetsByID: assetsByID,
                    networkByID: networkByID,
                    localNote: notesByTransactionID[transaction.id],
                    primaryTransfer:
                        primaryTransferByTransactionID[transaction.id]
                )
            }
            return WalletHomeSnapshot(
                totalBalance: walletAssets.reduce(0) {
                    $0 + (
                        $1.isSpam || $1.requiresExplicitVisibility
                            ? 0 : $1.fiatValue
                    )
                },
                assets: walletAssets,
                transactions: Array(walletTransactions),
                hasStoredActivity: hasStoredActivity
            )
        }
    }
}
