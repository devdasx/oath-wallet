import Foundation

struct NotificationTransactionRefreshFailure: Error, Sendable {
    let code: String
}

/// Targeted history refresh when a push arrives before its activity record.
struct NotificationTransactionRefreshService: Sendable {
    let database: WalletDatabase

    func refresh(_ notification: DBNotificationRecord) async throws {
        guard let walletID = notification.walletID, let networkID = notification.networkID,
              let hash = notification.transactionHash else { return }
        let accounts = try await WalletDataStore(database: database).accounts(walletID: walletID)
        guard let account = accounts.first(where: { $0.networkID == networkID && $0.isEnabled }) else {
            throw SendTransactionStatusProviderError.invalidAccount(networkID: networkID)
        }
        let route = try SendTransactionStatusRoute.resolve(networkID: networkID)
        if case let .bitcoinFamily(chain) = route {
            // Post-broadcast refresh deliberately fetches only balances for UTXO
            // chains. A notification needs full history, including HD addresses.
            let outcome = await BitcoinFamilySyncService(database: database)
                .sync(walletID: walletID, chain: chain)
            try Task.checkCancellation()
            if let failure = outcome.failures.first {
                throw NotificationTransactionRefreshFailure(code: failure.publicCode)
            }
        } else if route == .evm {
            // History refresh is read-only and also supports watch-only wallets.
            let prices = try await database.cachedAnkrHistoricalTokenPrices(walletID: walletID)
            let outcome = try await AnkrAPIClient.localBuild().loadNetworkWithOutcome(
                address: account.address, networkID: networkID,
                historyFromTimestamp: max(0, Int64(notification.createdAt) - 600),
                cachedHistoricalTokenPrices: prices
            )
            try Task.checkCancellation()
            try await database.saveWalletSnapshot(outcome.snapshot, address: account.address)
            if let failure = outcome.failures.first { throw NotificationTransactionRefreshFailure(code: failure.publicCode) }
        } else {
            let routingReceipt = SendTransactionReceipt(
                transactionHash: hash, accountID: account.id, networkID: networkID,
                fromAddress: account.address, toAddress: "", assetID: "", assetSymbol: "",
                amount: "0", amountAtomic: "0", networkFee: nil, networkFeeAtomic: nil,
                networkFeeSymbol: "", submittedAt: Date(timeIntervalSince1970: notification.createdAt)
            )
            let outcome = await SendPostBroadcastChainRefreshService(database: database)
                .refresh(walletID: walletID, receipt: routingReceipt)
            try Task.checkCancellation()
            if let failure = outcome.failures.first { throw NotificationTransactionRefreshFailure(code: failure.publicCode) }
        }
    }
}
