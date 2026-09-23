import CryptoKit
import Foundation

extension BitcoinFamilySyncService {
    nonisolated static func completeIndexedHistory(
        _ indexedHistory: [(String, Int64)]
    ) -> [(String, Int64)] {
        var seenHashes = Set<String>()
        return Array(
            indexedHistory
                .filter { element in
                    seenHashes.insert(element.0).inserted
                }
                .sorted { left, right in
                    let leftPending = left.1 <= 0
                    let rightPending = right.1 <= 0
                    if leftPending != rightPending { return leftPending }
                    if left.1 != right.1 { return left.1 > right.1 }
                    return left.0 < right.0
                }
                .prefix(Self.maximumHistoryTransactions)
        )
    }

    nonisolated static func combinedElectrumBalance(
        confirmed: BitcoinFamilyAtomicInteger,
        unconfirmed: BitcoinFamilyAtomicInteger
    ) throws -> BitcoinFamilyAtomicInteger {
        let balance = confirmed.adding(unconfirmed)
        guard !balance.isNegative else {
            throw BitcoinFamilyElectrumError.invalidResponse
        }
        return balance
    }

    nonisolated static func electrumScriptHash(
        _ material: BitcoinFamilyAccountMaterial
    ) -> String {
        Data(SHA256.hash(data: material.scriptPubKey))
            .reversed()
            .map { String(format: "%02x", $0) }
            .joined()
    }

    nonisolated static func validateBalanceTransition(
        previousBalance: BitcoinFamilyAtomicInteger?,
        fetchedBalance: BitcoinFamilyAtomicInteger,
        hasHistoryEvidence: Bool
    ) throws {
        // A first incoming mempool payment can disappear completely after
        // replacement or eviction. Empty history is valid evidence, not a
        // reason to retain money that a successful balance read no longer sees.
        guard !fetchedBalance.isNegative else {
            throw BitcoinFamilyElectrumError.invalidResponse
        }
    }

    nonisolated static func validateZeroBalanceHistoryEvidence(
        _ value: JSONValue
    ) throws {
        guard let history = value.array else {
            throw BitcoinFamilyElectrumError.invalidResponse
        }
        for entry in history {
            guard let item = entry.object,
                  let hash = item["tx_hash"]?.string?.lowercased(),
                  BitcoinFamilyIndexedAPIClient.isValidTransactionHash(hash),
                  item["height"]?.exactInt64 != nil else {
                throw BitcoinFamilyElectrumError.invalidResponse
            }
        }
    }

    nonisolated static func providerLatency(from startedAt: Date) -> Int {
        max(
            1,
            Int((Date().timeIntervalSince(startedAt) * 1_000).rounded())
        )
    }

    func refreshValuation(
        material: BitcoinFamilyAccountMaterial,
        walletID: String
    ) async -> Bool {
        let asset = WalletAsset(
            id: "\(material.chain.networkID):native",
            name: material.chain.name,
            symbol: material.chain.symbol,
            logoSource: .nativeCoin(blockchain: material.chain.blockchain),
            network: material.chain.blockchain,
            balance: 0,
            fiatValue: 0,
            balanceText: "0",
            balanceAtomic: "0",
            decimals: 8,
            receiveAddress: material.address
        )
        guard let quote = try? await AssetPriceClient.shared.usdPrice(
            for: asset
        ) else {
            return false
        }
        do {
            try await database.saveBitcoinFamilyValuation(
                quote,
                material: material,
                walletID: walletID
            )
            return true
        } catch {
            return false
        }
    }
}

func withBitcoinFamilyTimeout<T: Sendable>(
    seconds: UInt64,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw BitcoinFamilyAPIError.timeout
        }
        guard let result = try await group.next() else {
            throw BitcoinFamilyAPIError.timeout
        }
        group.cancelAll()
        return result
    }
}
