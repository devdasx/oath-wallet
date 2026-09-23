import CryptoKit
import Foundation

struct BitcoinSilentPaymentWalletResult: Sendable {
    let outputs: [BitcoinSilentPaymentOutput]
    let balanceAtomic: BitcoinFamilyAtomicInteger
    let transactions: [BitcoinHDTransactionReference]
    let balanceIsAuthoritative: Bool
}

enum BitcoinSilentPaymentSyncError: Error, Equatable {
    case unsupportedWallet
    case invalidTransaction
    case invalidElectrumResponse
}

protocol BitcoinSilentPaymentPublicDataClient: Sendable {
    func callStringParameterBatch(
        chain: BitcoinFamilyChain, method: String, parameters: [String], maximumResponseBytes: Int
    ) async throws -> [BitcoinFamilyElectrumBatchValue]
    func silentPaymentRawTransaction(hash: String, maximumResponseBytes: Int) async throws -> JSONValue
}

extension BitcoinFamilyElectrumClient: BitcoinSilentPaymentPublicDataClient {
    func silentPaymentRawTransaction(hash: String, maximumResponseBytes: Int) async throws -> JSONValue {
        try await call(
            chain: .bitcoin, method: "blockchain.transaction.get",
            params: [AnyEncodable(hash), AnyEncodable(false)], maximumResponseBytes: maximumResponseBytes
        )
    }
}

actor BitcoinSilentPaymentSyncService {
    private struct RefreshOperation: Sendable {
        let id: UUID
        let task: Task<BitcoinSilentPaymentWalletResult, Error>
    }

    static let shared = BitcoinSilentPaymentSyncService(
        databaseProvider: WalletDatabaseRuntime.require
    )

    private static let maximumRawTransactionResponseBytes = 8_388_608
    private let databaseProvider: @Sendable () throws -> WalletDatabase
    private let electrum: any BitcoinSilentPaymentPublicDataClient
    private var refreshOperations: [String: RefreshOperation] = [:]

    init(
        database: WalletDatabase,
        electrum: any BitcoinSilentPaymentPublicDataClient = BitcoinFamilyElectrumClient.shared
    ) {
        databaseProvider = { database }
        self.electrum = electrum
    }

    private init(
        databaseProvider: @escaping @Sendable () throws -> WalletDatabase
    ) {
        self.databaseProvider = databaseProvider
        electrum = BitcoinFamilyElectrumClient.shared
    }

    private var database: WalletDatabase {
        get throws { try databaseProvider() }
    }

    func refresh(walletID: String) async throws
        -> BitcoinSilentPaymentWalletResult {
        if let operation = refreshOperations[walletID] {
            return try await operation.task.value
        }
        let id = UUID()
        let task = Task {
            try await self.performRefresh(walletID: walletID)
        }
        refreshOperations[walletID] = RefreshOperation(id: id, task: task)
        do {
            let result = try await task.value
            clearRefreshOperation(walletID: walletID, id: id)
            return result
        } catch {
            clearRefreshOperation(walletID: walletID, id: id)
            throw error
        }
    }

    private func clearRefreshOperation(walletID: String, id: UUID) {
        guard refreshOperations[walletID]?.id == id else { return }
        refreshOperations.removeValue(forKey: walletID)
    }

    /// Refreshes already-known output scripts using public Electrum data only.
    /// It never loads a scan key and never claims discovery of unseen payments.
    private func performRefresh(walletID: String) async throws
        -> BitcoinSilentPaymentWalletResult {
        guard try await database.bitcoinSilentPaymentAccount(walletID: walletID) != nil else {
            return try await cachedResult(walletID: walletID)
        }
        return try await reconcile(
            walletID: walletID,
            scanStartHeight: nil,
            scanTipHeight: nil,
            balanceIsAuthoritative: false
        )
    }

    func cachedResult(walletID: String) async throws
        -> BitcoinSilentPaymentWalletResult {
        let cached = try await database.bitcoinSilentPaymentCachedState(
            walletID: walletID
        )
        let outputs = cached.outputs
        let unspent = outputs.filter { !$0.isSpent }
        return BitcoinSilentPaymentWalletResult(
            outputs: outputs,
            balanceAtomic: unspent.reduce(.zero) {
                $0.adding($1.valueAtomic)
            },
            transactions: outputs.compactMap {
                guard !$0.isSpent
                    || $0.spentByTransactionHash != nil else { return nil }
                return BitcoinHDTransactionReference(
                    transactionHash: $0.transactionHash,
                    height: Int64($0.blockHeight ?? 0)
                )
            },
            balanceIsAuthoritative: cached.balanceIsAuthoritative
        )
    }

    func liveUpdates(walletID _: String) async throws -> BitcoinSilentPaymentLiveSubscription {
        throw BitcoinSilentPaymentScanError.localScanningUnavailable
    }

    func monitoredScriptHashes(walletID: String) async throws -> Set<String> {
        Set(
            try await database.bitcoinSilentPaymentOutputs(
                walletID: walletID
            ).map { Self.scriptHash($0.scriptPubKey) }
        )
    }

    private func reconcile(
        walletID: String,
        freshlyDiscoveredHeights: [String: Int] = [:],
        scanStartHeight: Int?,
        scanTipHeight: Int?,
        balanceIsAuthoritative: Bool
    ) async throws
        -> BitcoinSilentPaymentWalletResult {
        if let start = scanStartHeight, let tip = scanTipHeight {
            guard start >= WalletDatabase.bitcoinSilentPaymentActivationHeight, tip >= start else {
                throw BitcoinSilentPaymentSyncError.invalidElectrumResponse
            }
        } else if scanStartHeight != nil || scanTipHeight != nil {
            throw BitcoinSilentPaymentSyncError.invalidElectrumResponse
        }
        let known = try await database.bitcoinSilentPaymentOutputs(
            walletID: walletID
        )
        guard !known.isEmpty else {
            try await database.completeBitcoinSilentPaymentReconciliation(
                walletID: walletID,
                scanHeight: scanTipHeight,
                mutations: [],
                balanceIsAuthoritative: balanceIsAuthoritative
            )
            return BitcoinSilentPaymentWalletResult(
                outputs: [],
                balanceAtomic: .zero,
                transactions: [],
                balanceIsAuthoritative: balanceIsAuthoritative
            )
        }
        let hashes = known.map { Self.scriptHash($0.scriptPubKey) }
        async let histories = electrum.callStringParameterBatch(
            chain: .bitcoin,
            method: "blockchain.scripthash.get_history",
            parameters: hashes,
            maximumResponseBytes:
                BitcoinFamilyElectrumClient.maximumHistoryResponseBytes
        )
        async let unspent = electrum.callStringParameterBatch(
            chain: .bitcoin,
            method: "blockchain.scripthash.listunspent",
            parameters: hashes,
            maximumResponseBytes: 1_048_576
        )
        let historyValues = try await histories
        let unspentValues = try await unspent
        guard historyValues.count == known.count,
              unspentValues.count == known.count else {
            throw BitcoinSilentPaymentSyncError.invalidElectrumResponse
        }
        let historyByHash = Dictionary(
            uniqueKeysWithValues: historyValues.map {
                ($0.parameter, $0.value)
            }
        )
        let unspentByHash = Dictionary(
            uniqueKeysWithValues: unspentValues.map {
                ($0.parameter, $0.value)
            }
        )
        var references = Set<BitcoinHDTransactionReference>()
        var mutations: [BitcoinSilentPaymentReconciliationMutation] = []

        for output in known {
            let hash = Self.scriptHash(output.scriptPubKey)
            guard let rawHistory = historyByHash[hash]?.array,
                  let rawUnspent = unspentByHash[hash]?.array else {
                throw BitcoinSilentPaymentSyncError.invalidElectrumResponse
            }
            let unspentOutpoints = try rawUnspent.map { value in
                guard let object = value.object,
                      let transactionHash = object["tx_hash"]?.string?
                        .lowercased(),
                      Self.isValidTransactionHash(transactionHash),
                      let rawPosition = object["tx_pos"]?.exactInt64,
                      rawPosition >= 0,
                      let position = Int(exactly: rawPosition) else {
                    throw BitcoinSilentPaymentSyncError
                        .invalidElectrumResponse
                }
                return (transactionHash, position)
            }
            let isUnspent = unspentOutpoints.contains {
                $0.0 == output.transactionHash && $0.1 == output.outputIndex
            }
            var containsCreatingTransaction = false
            for value in rawHistory {
                guard let object = value.object,
                      let transactionHash = object["tx_hash"]?.string?
                        .lowercased(),
                      Self.isValidTransactionHash(transactionHash),
                      let rawHeight = object["height"]?.exactInt64 else {
                    throw BitcoinSilentPaymentSyncError
                        .invalidElectrumResponse
                }
                containsCreatingTransaction = containsCreatingTransaction
                    || transactionHash == output.transactionHash
                references.insert(
                    BitcoinHDTransactionReference(
                        transactionHash: transactionHash,
                        height: rawHeight
                    )
                )
            }
            guard containsCreatingTransaction else {
                if let discoveredHeight = freshlyDiscoveredHeights[
                    output.transactionHash
                ] {
                    references.insert(
                        BitcoinHDTransactionReference(
                            transactionHash: output.transactionHash,
                            height: Int64(discoveredHeight)
                        )
                    )
                    guard isUnspent else {
                        throw BitcoinSilentPaymentSyncError
                            .invalidElectrumResponse
                    }
                    if output.isSpent {
                        mutations.append(
                            .restoreUnspent(
                                transactionHash: output.transactionHash,
                                outputIndex: output.outputIndex
                            )
                        )
                    }
                    continue
                }
                guard let scanStartHeight, let scanTipHeight,
                      Self.scanAuthoritativelyCovers(
                        blockHeight: output.blockHeight,
                        startHeight: scanStartHeight,
                        tipHeight: scanTipHeight
                      ) else {
                    // Electrum omitted a previously known transaction outside
                    // an independently completed scan window. That
                    // is an incomplete provider response, not proof that the
                    // user's output disappeared.
                    throw BitcoinSilentPaymentSyncError
                        .invalidElectrumResponse
                }
                if !output.isSpent || output.spentByTransactionHash != nil {
                    mutations.append(
                        .markOrphaned(
                            transactionHash: output.transactionHash,
                            outputIndex: output.outputIndex
                        )
                    )
                }
                continue
            }
            if isUnspent, output.isSpent {
                mutations.append(
                    .restoreUnspent(
                        transactionHash: output.transactionHash,
                        outputIndex: output.outputIndex
                    )
                )
            } else if !isUnspent {
                let spendingHash = try await findSpendingTransaction(
                    output: output,
                    history: rawHistory
                )
                guard let spendingHash else {
                    throw BitcoinSilentPaymentSyncError
                        .invalidElectrumResponse
                }
                if !output.isSpent
                    || output.spentByTransactionHash != spendingHash {
                    mutations.append(
                        .markSpent(
                            transactionHash: output.transactionHash,
                            outputIndex: output.outputIndex,
                            spendingTransactionHash: spendingHash
                        )
                    )
                }
            }
        }
        try await database.completeBitcoinSilentPaymentReconciliation(
            walletID: walletID,
            scanHeight: scanTipHeight,
            mutations: mutations,
            balanceIsAuthoritative: balanceIsAuthoritative
        )
        let refreshed = try await database.bitcoinSilentPaymentOutputs(
            walletID: walletID
        )
        let balance = refreshed.lazy.filter { !$0.isSpent }.reduce(
            BitcoinFamilyAtomicInteger.zero
        ) { $0.adding($1.valueAtomic) }
        return BitcoinSilentPaymentWalletResult(
            outputs: refreshed,
            balanceAtomic: balance,
            transactions: references.sorted {
                let leftPending = $0.height <= 0
                let rightPending = $1.height <= 0
                if leftPending != rightPending { return leftPending }
                if $0.height != $1.height { return $0.height > $1.height }
                return $0.transactionHash < $1.transactionHash
            },
            balanceIsAuthoritative: balanceIsAuthoritative
        )
    }

    private func findSpendingTransaction(
        output: BitcoinSilentPaymentOutput,
        history: [JSONValue]
    ) async throws -> String? {
        for value in history {
            guard let object = value.object,
                  let hash = object["tx_hash"]?.string?.lowercased(),
                  Self.isValidTransactionHash(hash) else {
                throw BitcoinSilentPaymentSyncError.invalidElectrumResponse
            }
            guard hash != output.transactionHash else { continue }
            let transactionValue = try await electrum.silentPaymentRawTransaction(
                hash: hash,
                maximumResponseBytes:
                    Self.maximumRawTransactionResponseBytes
            )
            guard let hex = transactionValue.string,
                  let transaction = BitcoinRawTransaction(hex: hex),
                  transaction.transactionID == hash else {
                throw BitcoinSilentPaymentSyncError.invalidElectrumResponse
            }
            if transaction.inputs.contains(where: {
                $0.previousHash == output.transactionHash
                    && $0.previousIndex == output.outputIndex
            }) {
                return hash
            }
        }
        return nil
    }

    private nonisolated static func scriptHash(_ script: Data) -> String {
        Data(SHA256.hash(data: script)).reversed()
            .map { String(format: "%02x", $0) }
            .joined()
    }

    nonisolated static func scanAuthoritativelyCovers(
        blockHeight: Int?,
        startHeight: Int,
        tipHeight: Int
    ) -> Bool {
        guard let blockHeight else { return false }
        return blockHeight >= startHeight && blockHeight <= tipHeight
    }

    private nonisolated static func isValidTransactionHash(
        _ value: String
    ) -> Bool {
        value.utf8.count == 64 && value.unicodeScalars.allSatisfy {
            switch $0.value {
            case 48...57, 65...70, 97...102: true
            default: false
            }
        }
    }
}
