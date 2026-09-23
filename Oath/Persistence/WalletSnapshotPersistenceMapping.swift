import Foundation
import GRDB

enum WalletSnapshotPersistenceError: Error, Equatable {
    case selectedWalletUnavailable
    case addressDoesNotBelongToSelectedWallet
    case watchOnlyWalletUnsupported
    case unverifiedBalanceSnapshot
    case invalidTrackedTokenBalance

    var diagnosticDescription: String {
        switch self {
        case .selectedWalletUnavailable:
            "selected_wallet_unavailable"
        case .addressDoesNotBelongToSelectedWallet:
            "address_does_not_belong_to_selected_wallet"
        case .watchOnlyWalletUnsupported:
            "watch_only_wallet_unsupported"
        case .unverifiedBalanceSnapshot:
            "unverified_balance_snapshot"
        case .invalidTrackedTokenBalance:
            "invalid_tracked_token_balance"
        }
    }
}

extension WalletDatabase {
    struct WalletContext: Sendable {
        let wallet: DBWalletRecord
        let accountsByNetwork: [String: DBWalletAccountRecord]
    }

    static func registeredWalletAndAccounts(
        address: String,
        normalizedAddress: String,
        database: Database
    ) throws -> WalletContext {
        let now = Date().timeIntervalSince1970
        guard
            let wallet = try DBWalletRecord
                .filter(Column("profileID") == defaultProfileID)
                .filter(Column("isSelected") == true)
                .filter(Column("archivedAt") == nil)
                .fetchOne(database)
        else {
            throw WalletSnapshotPersistenceError
                .selectedWalletUnavailable
        }
        guard wallet.kind != DatabaseWalletKind.watchOnly.rawValue else {
            throw WalletSnapshotPersistenceError
                .watchOnlyWalletUnsupported
        }
        let matchingAccounts = try DBWalletAccountRecord
            .filter(Column("walletID") == wallet.id)
            .filter(Column("normalizedAddress") == normalizedAddress)
            .fetchAll(database)
        guard let anchorAccount = matchingAccounts.first(where: {
            $0.isEnabled && !$0.isWatchOnly
        }) else {
            throw WalletSnapshotPersistenceError
                .addressDoesNotBelongToSelectedWallet
        }

        let networks = try DBNetworkRecord
            .filter(Column("isEnabled") == true)
            .filter(Column("isMainnet") == true)
            .order(Column("sortOrder"))
            .fetchAll(database)
            .filter {
                AnkrAPIClient.supportsTokenLookup(networkID: $0.id)
            }
        let existingByNetwork = Dictionary(
            uniqueKeysWithValues: matchingAccounts.map {
                ($0.networkID, $0)
            }
        )
        var accountsByNetwork: [String: DBWalletAccountRecord] = [:]
        for network in networks {
            let existing = existingByNetwork[network.id]
            if let existing, existing.isEnabled, !existing.isWatchOnly {
                accountsByNetwork[network.id] = existing
                continue
            }
            let account = DBWalletAccountRecord(
                id: existing?.id ?? UUID().uuidString.lowercased(),
                walletID: wallet.id,
                networkID: network.id,
                address: address,
                normalizedAddress: normalizedAddress,
                label: existing?.label ?? anchorAccount.label,
                derivationPath:
                    existing?.derivationPath
                    ?? anchorAccount.derivationPath,
                accountIndex:
                    existing?.accountIndex
                    ?? anchorAccount.accountIndex,
                publicKey:
                    existing?.publicKey
                    ?? anchorAccount.publicKey,
                isWatchOnly: false,
                isEnabled: true,
                createdAt: existing?.createdAt ?? now,
                updatedAt: now,
                lastSyncedAt: existing?.lastSyncedAt
            )
            try account.save(database)
            accountsByNetwork[network.id] = account
        }

        return WalletContext(
            wallet: wallet,
            accountsByNetwork: accountsByNetwork
        )
    }

    static func upsertAsset(
        _ asset: WalletAsset,
        networkID: String,
        existing: DBAssetRecord?,
        now: Double,
        database: Database
    ) throws -> DBAssetRecord {
        let identity = assetIdentity(
            logoSource: asset.logoSource,
            networkID: networkID,
            fallbackContractAddress: contractAddress(from: asset.id),
            verificationOverride: asset.isVerified
        )
        let record = DBAssetRecord(
            id: identity.id,
            networkID: networkID,
            assetType: identity.assetType.rawValue,
            contractAddress: identity.contractAddress,
            normalizedContractAddress: identity.contractAddress.lowercased(),
            name: asset.name,
            symbol: asset.symbol,
            decimals: asset.decimals ?? existing?.decimals,
            trustWalletBlockchain: identity.blockchainIdentifier,
            trustWalletContractAddress: identity.contractIdentity,
            logoURL: asset.logoSource.remoteLogoURL?.absoluteString,
            logoOrigin: asset.logoSource.origin?.rawValue,
            isVerified: identity.isCatalogVerified,
            isSpam: asset.isSpam
                || existing?.isSpam == true
                || TokenSafetyPolicy.isHardDenied(
                    networkID: networkID,
                    contractAddress: identity.contractAddress
                ),
            createdAt: existing?.createdAt ?? now,
            updatedAt: now,
            metadataUpdatedAt: now
        )
        try record.save(database)
        return record
    }

    static func upsertTransaction(
        _ transaction: WalletTransaction,
        walletAddress: String,
        accountsByNetwork: [String: DBWalletAccountRecord],
        persistedAssetsByID: inout [String: DBAssetRecord],
        existingTransactionsByID: inout [String: DBTransactionRecord],
        now: Double,
        database: Database
    ) throws {
        guard
            let networkID = transactionNetworkID(transaction),
            let account = accountsByNetwork[networkID]
        else {
            return
        }

        let assetIdentity = assetIdentity(
            logoSource: transaction.assetLogoSource,
            networkID: networkID,
            fallbackContractAddress: transaction.metadata.contractAddress
        )
        guard !TokenSafetyPolicy.isHardDenied(
            networkID: networkID,
            contractAddress: assetIdentity.contractAddress
        ) else {
            return
        }
        var asset = persistedAssetsByID[assetIdentity.id]
        if asset == nil {
            let record = DBAssetRecord(
                id: assetIdentity.id,
                networkID: networkID,
                assetType: assetIdentity.assetType.rawValue,
                contractAddress: assetIdentity.contractAddress,
                normalizedContractAddress:
                    assetIdentity.contractAddress.lowercased(),
                name: transaction.metadata.tokenName
                    ?? transaction.assetSymbol,
                symbol: transaction.assetSymbol,
                decimals: transaction.metadata.tokenDecimals,
                trustWalletBlockchain:
                    assetIdentity.blockchainIdentifier,
                trustWalletContractAddress:
                    assetIdentity.contractIdentity,
                logoURL:
                    transaction.assetLogoSource.remoteLogoURL?.absoluteString,
                logoOrigin: transaction.assetLogoSource.origin?.rawValue,
                isVerified: assetIdentity.isCatalogVerified,
                isSpam: TokenSafetyPolicy.isHardDenied(
                    networkID: networkID,
                    contractAddress: assetIdentity.contractAddress
                ),
                createdAt: now,
                updatedAt: now,
                metadataUpdatedAt: now
            )
            try record.insert(database)
            persistedAssetsByID[record.id] = record
            asset = record
        }

        let kind = transactionKind(transaction.kind)
        let direction = transactionDirection(transaction.kind)
        let hash = transaction.metadata.transactionHash ?? transaction.id
        let exactAmountText = transaction.assetAmountText
            ?? storageString(transaction.assetAmount)
        let generatedRecordID = transactionRecordID(
            transaction,
            walletAddress: walletAddress,
            networkID: networkID
        )
        let reconciliation = try reconcileSubmittedEVMTransaction(
            generatedRecordID: generatedRecordID,
            accountID: account.id,
            networkID: networkID,
            normalizedHash: hash.lowercased(),
            assetID: asset?.id,
            providerDirection: direction,
            providerAmountText: exactAmountText,
            database: database
        )
        let recordID = reconciliation.recordID
        let existing = existingTransactionsByID[recordID]
            ?? reconciliation.existingRecord
        if generatedRecordID != recordID {
            existingTransactionsByID.removeValue(
                forKey: generatedRecordID
            )
        }
        let secondarySymbol: String? = {
            if case let .swapped(_, destinationSymbol) = transaction.kind {
                return destinationSymbol
            }
            return nil
        }()
        let counterparty: String?
        switch direction {
        case "incoming":
            counterparty = transaction.metadata.fromAddress
        case "outgoing":
            counterparty = transaction.metadata.toAddress
        default:
            counterparty = nil
        }
        let providerFiatUSDValue: String?
        if let asset, asset.assetType != DatabaseAssetType.native.rawValue {
            providerFiatUSDValue = try cachedFiatUSDValue(
                amountText: exactAmountText, assetID: asset.id,
                fallback: nil, database: database
            )
        } else {
            providerFiatUSDValue = transaction.fiatValue.map(storageString)
        }
        let providerNetworkFeeFiatUSDValue =
            transaction.metadata.networkFeeFiatValue.map(storageString)
        let primaryTransferID = "\(recordID)|primary"
        let existingPrimaryTransfer =
            try DBTransactionTransferRecord.fetchOne(
                database,
                key: primaryTransferID
            )

        let record = DBTransactionRecord(
            id: recordID,
            accountID: account.id,
            networkID: networkID,
            transactionHash: hash,
            normalizedTransactionHash: hash.lowercased(),
            kind: kind,
            status: transactionStatus(transaction.status),
            direction: direction,
            fromAddress: transaction.metadata.fromAddress,
            toAddress: transaction.metadata.toAddress,
            counterpartyAddress: counterparty,
            blockNumber: transaction.metadata.blockNumber,
            blockHash: transaction.metadata.blockHash,
            transactionIndex: transaction.metadata.transactionIndex,
            nonce: transaction.metadata.nonce,
            transactionType: transaction.metadata.transactionType,
            timestamp: transaction.metadata.date?.timeIntervalSince1970,
            assetID: asset?.id,
            assetSymbol: transaction.assetSymbol,
            secondaryAssetSymbol: secondarySymbol,
            assetAmount: exactAmountText,
            fiatUSDValue: providerFiatUSDValue
                ?? existing?.fiatUSDValue,
            networkFee: transaction.metadata.networkFee.map(storageString),
            networkFeeFiatUSDValue:
                providerNetworkFeeFiatUSDValue
                ?? existing?.networkFeeFiatUSDValue,
            networkFeeSymbol: transaction.metadata.networkFeeSymbol,
            gasPriceGwei: transaction.metadata.gasPriceGwei.map(storageString),
            gasLimit: transaction.metadata.gasLimit,
            gasUsed: transaction.metadata.gasUsed,
            inputData: transaction.metadata.inputData,
            methodName: nil,
            displayDetail: transaction.detail,
            displayTime: transaction.time,
            firstSeenAt: existing?.firstSeenAt ?? now,
            updatedAt: now
        )
        try record.save(database)
        existingTransactionsByID[recordID] = record

        try DBTransactionTransferRecord(
            id: primaryTransferID,
            transactionID: recordID,
            logIndex: transaction.metadata.logIndex,
            assetID: asset?.id,
            fromAddress: transaction.metadata.fromAddress,
            toAddress: transaction.metadata.toAddress,
            direction: direction,
            amount: exactAmountText,
            amountAtomic: transaction.assetAmountAtomic
                ?? reconciliation.retainedAmountAtomic,
            fiatUSDValue: providerFiatUSDValue
                ?? existingPrimaryTransfer?.fiatUSDValue,
            tokenName: transaction.metadata.tokenName,
            tokenSymbol: transaction.assetSymbol,
            tokenDecimals: transaction.metadata.tokenDecimals
        ).save(database)
    }

    static func transactionNetworkID(
        _ transaction: WalletTransaction
    ) -> String? {
        guard
            let blockchainIdentifier =
                transaction.metadata.blockchainIdentifier
        else {
            return nil
        }
        return (
            ReceiveNetworkCatalog.network(for: blockchainIdentifier)
                ?? ReceiveNetworkCatalog.all.first {
                    $0.blockchain.rawValue == blockchainIdentifier
                }
        )?.id
    }

    static func isDisplayEligibleAsset(
        _ asset: DBAssetRecord
    ) -> Bool {
        guard !asset.isSpam else {
            return false
        }
        let requiresVerifiedCatalogEntry =
            asset.networkID == SolanaConstants.networkID
            || asset.networkID == SuiConstants.networkID
        guard requiresVerifiedCatalogEntry,
              asset.assetType == DatabaseAssetType.fungibleToken.rawValue
        else {
            return true
        }
        return asset.isVerified
    }

    static func isDisplayEligibleTransaction(
        _ transaction: DBTransactionRecord,
        assetsByID: [String: DBAssetRecord]
    ) -> Bool {
        guard let assetID = transaction.assetID else {
            return transaction.networkID != SolanaConstants.networkID
                && transaction.networkID != SuiConstants.networkID
        }
        guard let asset = assetsByID[assetID] else {
            return false
        }
        return isDisplayEligibleAsset(asset)
    }

    static func cachedDisplayEligibleTransactions(
        accountIDs: [String],
        database: Database
    ) throws -> [DBTransactionRecord] {
        let resultLimit = 100
        let pageLimit = 256
        guard !accountIDs.isEmpty else { return [] }

        var selected: [DBTransactionRecord] = []
        var assetsByID: [String: DBAssetRecord] = [:]
        var networksByID: [String: DBNetworkRecord] = [:]
        var unitUSDPricesByAssetID: [String: Decimal] = [:]
        var assetIDsWithoutPrice = Set<String>()
        var offset = 0
        var sourceExhausted = false

        while selected.count < resultLimit, !sourceExhausted {
            let page = try DBTransactionRecord
                .filter(accountIDs.contains(Column("accountID")))
                .order(
                    sql: """
                    COALESCE(timestamp, firstSeenAt) DESC, id DESC
                    """
                )
                .limit(pageLimit, offset: offset)
                .fetchAll(database)
            guard !page.isEmpty else {
                sourceExhausted = true
                break
            }

            offset += page.count
            sourceExhausted = page.count < pageLimit

            let missingAssetIDs = Set(page.compactMap(\.assetID))
                .subtracting(assetsByID.keys)
            if !missingAssetIDs.isEmpty {
                let assets = try DBAssetRecord
                    .filter(Array(missingAssetIDs).contains(Column("id")))
                    .fetchAll(database)
                for asset in assets {
                    assetsByID[asset.id] = asset
                }
            }

            let unresolvedPriceAssetIDs = Set(page.compactMap(\.assetID))
                .subtracting(unitUSDPricesByAssetID.keys)
                .subtracting(assetIDsWithoutPrice)
            if !unresolvedPriceAssetIDs.isEmpty {
                let priceRecords = try DBAssetPriceRecord
                    .filter(
                        Array(unresolvedPriceAssetIDs).contains(
                            Column("assetID")
                        )
                    )
                    .filter(Column("quoteCurrency") == "USD")
                    .order(Column("observedAt").desc)
                    .fetchAll(database)
                for priceRecord in priceRecords
                where unitUSDPricesByAssetID[priceRecord.assetID] == nil {
                    guard
                        let asset = assetsByID[priceRecord.assetID],
                        AssetPriceClient.cachedPriceIsReusable(
                            priceRecord,
                            for: asset
                        ),
                        let price = decimal(priceRecord.price),
                        price > 0
                    else {
                        continue
                    }
                    unitUSDPricesByAssetID[priceRecord.assetID] = price
                }
                assetIDsWithoutPrice.formUnion(
                    unresolvedPriceAssetIDs.subtracting(
                        unitUSDPricesByAssetID.keys
                    )
                )
            }

            let missingNetworkIDs = Set(page.map(\.networkID))
                .subtracting(networksByID.keys)
            if !missingNetworkIDs.isEmpty {
                let networks = try DBNetworkRecord
                    .filter(
                        Array(missingNetworkIDs).contains(Column("id"))
                    )
                    .fetchAll(database)
                for network in networks {
                    networksByID[network.id] = network
                }
            }

            for record in page where selected.count < resultLimit {
                let valuedRecord = transactionByApplyingCachedUSDPrice(
                    record,
                    unitUSDPricesByAssetID: unitUSDPricesByAssetID
                )
                guard
                    isDisplayEligibleTransaction(
                        valuedRecord,
                        assetsByID: assetsByID
                    ),
                    let transaction = walletTransaction(
                        valuedRecord,
                        assetsByID: assetsByID,
                        networkByID: networksByID
                    ),
                    WalletTransactionVisibilityPolicy.includes(transaction)
                else {
                    continue
                }
                selected.append(valuedRecord)
            }
        }
        return selected
    }

    static func hasStoredActivity(
        accountIDs: [String],
        database: Database
    ) throws -> Bool {
        guard !accountIDs.isEmpty else { return false }
        return try DBTransactionRecord
            .filter(accountIDs.contains(Column("accountID")))
            .limit(1)
            .fetchOne(database) != nil
    }

    static func transactionByApplyingCachedUSDPrice(
        _ transaction: DBTransactionRecord,
        unitUSDPricesByAssetID: [String: Decimal]
    ) -> DBTransactionRecord {
        guard transaction.fiatUSDValue == nil,
              let assetID = transaction.assetID,
              let unitPrice = unitUSDPricesByAssetID[assetID],
              let fiatText = transactionUSDValueText(
                  amountText: transaction.assetAmount,
                  unitPrice: unitPrice
              ) else {
            return transaction
        }
        var valuedTransaction = transaction
        valuedTransaction.fiatUSDValue = fiatText
        return valuedTransaction
    }

    static func transactionUSDValueText(
        amountText: String,
        unitPrice: Decimal
    ) -> String? {
        guard unitPrice > 0,
              let amountMagnitudeText =
                  ExactDecimalText.canonicalMagnitude(amountText),
              let amountMagnitude = decimal(amountMagnitudeText)
        else {
            return nil
        }
        return storageString(amountMagnitude * unitPrice)
    }

    static func transactionRecordID(
        _ transaction: WalletTransaction,
        walletAddress: String,
        networkID: String
    ) -> String {
        "\(walletAddress)|\(networkID)|\(transaction.id)"
    }

    static func walletTransaction(
        _ record: DBTransactionRecord,
        assetsByID: [String: DBAssetRecord],
        networkByID: [String: DBNetworkRecord],
        localNote: String? = nil,
        primaryTransfer: DBTransactionTransferRecord? = nil,
        assetAmountAtomic: String? = nil
    ) -> WalletTransaction? {
        let storedAmount = primaryTransfer?.amount ?? record.assetAmount
        guard
            let exactAmount = ExactDecimalText.signedMagnitude(
                storedAmount,
                isIncoming: record.direction == "incoming"
            ),
            let status = walletTransactionStatus(record.observedStatus == "notFound" && record.status == "pending"
                ? "notFound" : (record.observedStatus == "replaced" && ["pending", "canceled"].contains(record.status)
                    ? "replaced" : record.status))
        else {
            return nil
        }
        let storedMagnitude = ExactDecimalText.canonicalMagnitude(
            exactAmount
        ).flatMap(decimal) ?? 0
        let amountMagnitude = storedMagnitude
        let amount = record.direction == "incoming"
            ? amountMagnitude
            : -amountMagnitude
        let fiatValue = record.fiatUSDValue.flatMap(decimal).map { stored in
            let magnitude = stored < 0 ? -stored : stored
            return record.direction == "incoming"
                ? magnitude
                : -magnitude
        }

        let kind: WalletTransactionKind
        switch record.kind {
        case "received":
            kind = .received(assetSymbol: record.assetSymbol)
        case "sent":
            kind = record.direction == "self"
                ? .selfTransfer(assetSymbol: record.assetSymbol)
                : .sent(assetSymbol: record.assetSymbol)
        case "swapped":
            kind = .swapped(
                sourceSymbol: record.assetSymbol,
                destinationSymbol: record.secondaryAssetSymbol ?? ""
            )
        default:
            return nil
        }

        let network = networkByID[record.networkID].flatMap {
            WalletBlockchain(rawValue: $0.trustWalletBlockchain)
        }
        let asset = record.assetID.flatMap { assetsByID[$0] }
        let logo: AssetLogoSource
        if let asset, let network {
            logo = logoSource(asset: asset, fallbackNetwork: network)
        } else if let network {
            logo = .nativeCoin(blockchain: network)
        } else {
            logo = .unavailable
        }
        let date = record.timestamp.map(Date.init(timeIntervalSince1970:))
        let fromAddress = record.fromAddress
            ?? primaryTransfer?.fromAddress
        let toAddress = record.toAddress
            ?? primaryTransfer?.toAddress
            ?? (
                record.direction == "outgoing"
                    ? record.counterpartyAddress : nil
            )
        let displayTime = date.map {
            EnglishNumbers.walletActivityTimestamp($0)
        } ?? (
            record.networkID == AptosConstants.networkID
                ? "" : record.displayTime
        )

        return WalletTransaction(
            id: record.id,
            kind: kind,
            detail: record.displayDetail,
            time: displayTime,
            assetLogoSource: logo,
            assetAmount: amount,
            assetAmountText: exactAmount,
            assetAmountAtomic: assetAmountAtomic
                ?? primaryTransfer?.amountAtomic,
            assetSymbol: record.assetSymbol,
            fiatValue: fiatValue,
            status: status,
            metadata: WalletTransactionMetadata(
                transactionHash: record.transactionHash,
                blockchainIdentifier: record.networkID,
                date: date,
                fromAddress: fromAddress,
                toAddress: toAddress,
                blockNumber: record.blockNumber,
                blockHash: record.blockHash,
                contractAddress: asset?.contractAddress.isEmpty == false
                    ? asset?.contractAddress
                    : nil,
                tokenName: primaryTransfer?.tokenName ?? asset?.name,
                tokenDecimals:
                    primaryTransfer?.tokenDecimals ?? asset?.decimals,
                logIndex: primaryTransfer?.logIndex,
                networkFee: record.networkFee.flatMap(decimal),
                networkFeeFiatValue:
                    record.networkFeeFiatUSDValue.flatMap(decimal),
                networkFeeSymbol: record.networkFeeSymbol,
                gasPriceGwei: record.gasPriceGwei.flatMap(decimal),
                gasLimit: record.gasLimit,
                gasUsed: record.gasUsed,
                nonce: record.nonce,
                transactionIndex: record.transactionIndex,
                transactionType: record.transactionType,
                inputData: record.inputData,
                note: WalletTransactionNote.normalized(localNote)
            ),
            replacementTransactionHash: record.replacementTransactionHash
        )
    }

    static func assetIdentity(
        logoSource: AssetLogoSource,
        networkID: String,
        fallbackContractAddress: String?,
        verificationOverride: Bool? = nil
    ) -> (
        id: String,
        assetType: DatabaseAssetType,
        contractAddress: String,
        blockchainIdentifier: String?,
        contractIdentity: String?,
        isCatalogVerified: Bool
    ) {
        switch logoSource {
        case let .nativeCoin(blockchain),
             let .network(blockchain):
            return (
                "\(networkID):native",
                .native,
                "",
                blockchain.rawValue,
                nil,
                true
            )
        case let .token(
            blockchain,
            checksummedContractAddress,
            _,
            _
        ):
            return (
                "\(networkID):\(checksummedContractAddress.lowercased())",
                .fungibleToken,
                checksummedContractAddress,
                blockchain.rawValue,
                checksummedContractAddress,
                verificationOverride
                    ?? ReceiveAssetCatalog.variant(
                        networkID: networkID,
                        contractAddress: checksummedContractAddress
                    )?.isVerified
                    ?? false
            )
        case .unavailable, .family:
            // A family badge is never an asset's own logo; fall back to the
            // identity the caller already knows.
            if let contract = normalizedTokenContract(
                fallbackContractAddress
            ) {
                return (
                    "\(networkID):\(contract.lowercased())",
                    .fungibleToken,
                    contract,
                    nil,
                    nil,
                    false
                )
            }
            return (
                "\(networkID):native",
                .native,
                "",
                nil,
                nil,
                false
            )
        }
    }

    static func contractAddress(from assetID: String) -> String? {
        guard let separator = assetID.firstIndex(of: ":") else {
            return nil
        }
        return normalizedTokenContract(
            String(assetID[assetID.index(after: separator)...])
        )
    }

    static func normalizedTokenContract(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard
            normalized.count == 42,
            normalized.hasPrefix("0x"),
            normalized.dropFirst(2).allSatisfy(\.isHexDigit),
            normalized.lowercased()
                != "0x0000000000000000000000000000000000000000"
        else {
            return nil
        }
        return normalized
    }

    static func logoSource(
        asset: DBAssetRecord,
        fallbackNetwork: WalletBlockchain
    ) -> AssetLogoSource {
        let network = asset.trustWalletBlockchain
            .flatMap(WalletBlockchain.init(rawValue:)) ?? fallbackNetwork

        if asset.assetType == DatabaseAssetType.native.rawValue {
            return .nativeCoin(blockchain: network)
        }
        let contract = asset.trustWalletContractAddress
            ?? asset.contractAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !contract.isEmpty else {
            return .unavailable
        }
        if let catalogSource = ReceiveAssetCatalog.variant(
            networkID: asset.networkID,
            contractAddress: contract
        )?.logoSource, catalogSource.remoteLogoURL != nil {
            return catalogSource
        }
        if asset.logoOrigin == AssetLogoSourceOrigin.ankr.rawValue
            || asset.logoOrigin == "provider" {
            return .ankrToken(
                blockchain: network,
                contractAddress: contract,
                logoURL: asset.logoURL
            )
        }
        if asset.logoOrigin == AssetLogoSourceOrigin.catalog.rawValue {
            return .catalogToken(
                blockchain: network,
                contractAddress: contract,
                logoURL: asset.logoURL
            )
        }
        return .unavailable
    }

    static func networkID(
        for blockchain: WalletBlockchain?
    ) -> String? {
        guard let blockchain else { return nil }
        return ReceiveNetworkCatalog.all.first {
            $0.blockchain == blockchain
        }?.id
    }

    static func transactionKind(_ kind: WalletTransactionKind) -> String {
        switch kind {
        case .received: "received"
        case .sent: "sent"
        case .selfTransfer: "sent"
        case .swapped: "swapped"
        }
    }

    static func transactionDirection(
        _ kind: WalletTransactionKind
    ) -> String {
        switch kind {
        case .received: "incoming"
        case .sent: "outgoing"
        case .selfTransfer: "self"
        case .swapped: "self"
        }
    }

    static func transactionStatus(
        _ status: WalletTransactionStatus
    ) -> String {
        switch status {
        case .pending: "pending"
        case .confirmed: "confirmed"
        case .canceled: "canceled"
        case .failed: "failed"
        case .notFound, .replaced: "pending"
        }
    }

    static func walletTransactionStatus(
        _ rawValue: String
    ) -> WalletTransactionStatus? {
        switch rawValue {
        case "pending": .pending
        case "confirmed": .confirmed
        case "canceled": .canceled
        case "failed": .failed
        case "notFound": .notFound
        case "replaced": .replaced
        default: nil
        }
    }

    static func pruneActivity(
        accountID: String,
        database: Database
    ) throws {
        try database.execute(
            sql: """
            DELETE FROM transactions
            WHERE accountID = ?
              AND id NOT IN (
                SELECT id FROM transactions
                WHERE accountID = ?
                ORDER BY timestamp DESC, blockNumber DESC
                LIMIT 5000
              )
            """,
            arguments: [accountID, accountID]
        )
    }

    static func pruneCaches(now: Double, database: Database) throws {
        try database.execute(
            sql: "DELETE FROM apiCache WHERE expiresAt <= ?",
            arguments: [now]
        )
        let priceCutoff = now - (90 * 24 * 60 * 60)
        try database.execute(
            sql: """
            DELETE FROM assetPrices
            WHERE observedAt < ?
              AND EXISTS (
                SELECT 1
                FROM assetPrices AS newer
                WHERE newer.assetID = assetPrices.assetID
                  AND newer.quoteCurrency = assetPrices.quoteCurrency
                  AND newer.provider = assetPrices.provider
                  AND newer.observedAt > assetPrices.observedAt
              )
            """,
            arguments: [priceCutoff]
        )
        try database.execute(
            sql: "DELETE FROM marketSnapshots WHERE observedAt < ?",
            arguments: [priceCutoff]
        )
    }

    static func normalizedAddress(_ address: String) -> String {
        address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func storageString(_ value: Decimal) -> String {
        NSDecimalNumber(decimal: value).stringValue
    }

    static func providerBalanceText(
        _ value: String?,
        matching decimalValue: Decimal
    ) -> String {
        guard
            let value,
            value.count <= 256,
            decimal(value) == decimalValue
        else {
            return storageString(decimalValue)
        }
        return value
    }

    static func providerAtomicBalance(_ value: String?) -> String? {
        guard
            let value,
            !value.isEmpty,
            value.count <= 256,
            value.allSatisfy(\.isASCII),
            value.allSatisfy(\.isNumber)
        else {
            return nil
        }
        return value
    }

    static func decimal(_ value: String) -> Decimal? {
        Decimal(
            string: value,
            locale: Locale(identifier: "en_US_POSIX")
        )
    }

    static func magnitude(_ value: Decimal) -> Decimal {
        value < 0 ? -value : value
    }
}
