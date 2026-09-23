import Foundation
import GRDB

struct BitcoinFamilyTransactionIdentityResolutionContext: Sendable {
    let transactionID: String
    let chain: BitcoinFamilyChain
    let transactionHash: String
    let walletAddress: String
    let direction: String
    let existingIdentity: BitcoinFamilyTransactionIdentity
}

struct BitcoinFamilyTransactionIdentityResolver: Sendable {
    static let shared = BitcoinFamilyTransactionIdentityResolver(
        databaseProvider: WalletDatabaseRuntime.require,
        client: .shared
    )

    private let databaseProvider:
        @Sendable () throws -> WalletDatabase
    private let client: BitcoinFamilyIndexedAPIClient

    init(
        database: WalletDatabase,
        client: BitcoinFamilyIndexedAPIClient = .shared
    ) {
        databaseProvider = { database }
        self.client = client
    }

    private init(
        databaseProvider:
            @escaping @Sendable () throws -> WalletDatabase,
        client: BitcoinFamilyIndexedAPIClient
    ) {
        self.databaseProvider = databaseProvider
        self.client = client
    }

    func resolveAndPersist(
        transactionID: String
    ) async throws -> BitcoinFamilyTransactionIdentity? {
        let database = try databaseProvider()
        guard let context = try await database
            .bitcoinFamilyTransactionIdentityContext(
                transactionID: transactionID
            ) else {
            return nil
        }
        if Self.hasUsableAddress(context.existingIdentity.fromAddress),
           Self.hasUsableAddress(context.existingIdentity.toAddress) {
            return context.existingIdentity
        }
        return try await resolveAndPersist(
            context: context,
            database: database
        )
    }

    func transactionByResolvingRepeatRecipient(
        _ transaction: WalletTransaction
    ) async throws -> WalletTransaction {
        guard
            !Self.hasUsableAddress(transaction.metadata.toAddress),
            let networkID = WalletNetworkSelectionOrdering
                .canonicalNetworkID(
                    transaction.metadata.blockchainIdentifier
                ),
            BitcoinFamilyChain(rawValue: networkID) != nil
        else {
            return transaction
        }

        let database = try databaseProvider()
        guard let context = try await database
            .bitcoinFamilyTransactionIdentityContext(
                transactionID: transaction.id
            ) else {
            return transaction
        }
        let identity: BitcoinFamilyTransactionIdentity
        if Self.hasUsableAddress(context.existingIdentity.toAddress) {
            identity = context.existingIdentity
        } else {
            identity = try await resolveAndPersist(
                context: context,
                database: database
            )
        }
        return transaction.fillingMissingBitcoinFamilyIdentity(identity)
    }

    private static func hasUsableAddress(_ address: String?) -> Bool {
        guard let address else { return false }
        return !address.trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
    }

    private func resolveAndPersist(
        context: BitcoinFamilyTransactionIdentityResolutionContext,
        database: WalletDatabase
    ) async throws -> BitcoinFamilyTransactionIdentity {
        let resolved = try await client.transactionIdentity(
            chain: context.chain,
            transactionHash: context.transactionHash,
            walletAddress: context.walletAddress,
            direction: context.direction
        )
        return try await database.repairBitcoinFamilyTransactionIdentity(
            context: context,
            resolved: resolved
        )
    }
}

extension WalletTransaction {
    func fillingMissingBitcoinFamilyIdentity(
        _ identity: BitcoinFamilyTransactionIdentity
    ) -> WalletTransaction {
        let resolvedFrom = Self.preferredIdentityAddress(
            current: metadata.fromAddress,
            fallback: identity.fromAddress
        )
        let resolvedTo = Self.preferredIdentityAddress(
            current: metadata.toAddress,
            fallback: identity.toAddress
        )
        guard resolvedFrom != metadata.fromAddress
                || resolvedTo != metadata.toAddress else {
            return self
        }
        return WalletTransaction(
            id: id,
            kind: kind,
            detail: detail,
            time: time,
            assetLogoSource: assetLogoSource,
            assetAmount: assetAmount,
            assetAmountText: assetAmountText,
            assetAmountAtomic: assetAmountAtomic,
            assetSymbol: assetSymbol,
            fiatValue: fiatValue,
            status: status,
            metadata: WalletTransactionMetadata(
                transactionHash: metadata.transactionHash,
                blockchainIdentifier: metadata.blockchainIdentifier,
                date: metadata.date,
                fromAddress: resolvedFrom,
                toAddress: resolvedTo,
                blockNumber: metadata.blockNumber,
                blockHash: metadata.blockHash,
                contractAddress: metadata.contractAddress,
                tokenName: metadata.tokenName,
                tokenDecimals: metadata.tokenDecimals,
                logIndex: metadata.logIndex,
                networkFee: metadata.networkFee,
                networkFeeFiatValue: metadata.networkFeeFiatValue,
                networkFeeSymbol: metadata.networkFeeSymbol,
                gasPriceGwei: metadata.gasPriceGwei,
                gasLimit: metadata.gasLimit,
                gasUsed: metadata.gasUsed,
                nonce: metadata.nonce,
                transactionIndex: metadata.transactionIndex,
                transactionType: metadata.transactionType,
                inputData: metadata.inputData,
                note: metadata.note
            ),
            replacementTransactionHash: replacementTransactionHash
        )
    }

    private static func preferredIdentityAddress(
        current: String?,
        fallback: String?
    ) -> String? {
        for value in [current, fallback] {
            let address = value?.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            if let address, !address.isEmpty {
                return address
            }
        }
        return nil
    }
}

extension WalletDatabase {
    func bitcoinFamilyTransactionIdentityContext(
        transactionID: String
    ) async throws -> BitcoinFamilyTransactionIdentityResolutionContext? {
        try await pool.read { database in
            guard let transaction = try DBTransactionRecord.fetchOne(
                database,
                key: transactionID
            ), let chain = BitcoinFamilyChain(
                rawValue: transaction.networkID
            ), let account = try DBWalletAccountRecord.fetchOne(
                database,
                key: transaction.accountID
            ), account.networkID == chain.networkID,
               chain.coin.validate(address: account.address),
               BitcoinFamilyIndexedAPIClient.isValidTransactionHash(
                   transaction.transactionHash.lowercased()
               ) else {
                return nil
            }
            return BitcoinFamilyTransactionIdentityResolutionContext(
                transactionID: transaction.id,
                chain: chain,
                transactionHash: transaction.transactionHash,
                walletAddress: account.address,
                direction: transaction.direction,
                existingIdentity: BitcoinFamilyTransactionIdentity(
                    fromAddress: transaction.fromAddress,
                    toAddress: transaction.toAddress
                )
            )
        }
    }

    func repairBitcoinFamilyTransactionIdentity(
        context: BitcoinFamilyTransactionIdentityResolutionContext,
        resolved: BitcoinFamilyTransactionIdentity
    ) async throws -> BitcoinFamilyTransactionIdentity {
        try await pool.write { database in
            guard var transaction = try DBTransactionRecord.fetchOne(
                database,
                key: context.transactionID
            ), transaction.networkID == context.chain.networkID,
               transaction.transactionHash.caseInsensitiveCompare(
                   context.transactionHash
               ) == .orderedSame else {
                throw WalletDataStoreError.missingRecord
            }
            let resolvedFrom = Self.validBitcoinFamilyAddress(
                resolved.fromAddress,
                chain: context.chain
            )
            let resolvedTo = Self.validBitcoinFamilyAddress(
                resolved.toAddress,
                chain: context.chain
            )
            transaction.fromAddress = transaction.fromAddress
                ?? resolvedFrom
            transaction.toAddress = transaction.toAddress ?? resolvedTo
            let isIncoming = ["in", "incoming", "received"].contains(
                transaction.direction.lowercased()
            )
            transaction.counterpartyAddress = isIncoming
                ? transaction.fromAddress : transaction.toAddress
            if let counterparty = transaction.counterpartyAddress {
                transaction.displayDetail = counterparty
            }
            transaction.updatedAt = Date().timeIntervalSince1970
            try transaction.update(database)

            let primaryTransferID = "\(transaction.id)|primary"
            if var transfer = try DBTransactionTransferRecord.fetchOne(
                database,
                key: primaryTransferID
            ) {
                transfer.fromAddress = transfer.fromAddress
                    ?? transaction.fromAddress
                transfer.toAddress = transfer.toAddress
                    ?? transaction.toAddress
                try transfer.update(database)
            }
            return BitcoinFamilyTransactionIdentity(
                fromAddress: transaction.fromAddress,
                toAddress: transaction.toAddress
            )
        }
    }

    private static func validBitcoinFamilyAddress(
        _ value: String?,
        chain: BitcoinFamilyChain
    ) -> String? {
        guard let value else { return nil }
        let address = value.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        return chain.coin.validate(address: address) ? address : nil
    }
}
