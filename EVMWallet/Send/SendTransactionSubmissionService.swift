import Foundation
import GRDB

struct SendTransactionSubmissionOutcome: Hashable, Sendable {
    let receipt: SendTransactionReceipt
    let localTransactionID: String?
    let localPersistenceWarningCode: String?
}

struct SendTransactionSubmissionService: Sendable {
    let database: WalletDatabase

    func submit(
        draft: SendDraft,
        authorization: SendTransactionAuthorization
    ) async throws -> SendTransactionSubmissionOutcome {
        let material = try await SendSigningKeyResolver(
            database: database
        ).resolve(
            draft: draft,
            authorization: authorization
        )
        let reservation = try await acquireSpendReservation(
            material: material
        )
        let receipt: SendTransactionReceipt
        do {
            if BitcoinFamilyChain(rawValue: draft.asset.networkID) != nil {
                receipt = try await SendBitcoinTransactionService(
                    database: database
                ).submit(
                    draft: draft,
                    material: material,
                    reservation: reservation
                )
            } else if draft.asset.networkID == SolanaConstants.networkID {
                receipt = try await SendSolanaTransactionService().submit(
                    draft: draft,
                    material: material,
                    reservation: reservation
                )
            } else if draft.asset.networkID == TronConstants.networkID {
                receipt = try await SendTronTransactionService().submit(
                    draft: draft,
                    material: material,
                    reservation: reservation
                )
            } else if draft.asset.networkID == TONConstants.networkID {
                receipt = try await SendTONTransactionService().submit(
                    draft: draft,
                    material: material,
                    reservation: reservation
                )
            } else if draft.asset.networkID == SuiConstants.networkID {
                receipt = try await SendSuiTransactionService().submit(
                    draft: draft,
                    material: material,
                    reservation: reservation
                )
            } else if draft.asset.networkID == XRPConstants.networkID {
                receipt = try await SendXRPTransactionService().submit(
                    draft: draft,
                    material: material,
                    reservation: reservation
                )
            } else if draft.asset.networkID == NEARConstants.networkID {
                receipt = try await SendNEARTransactionService().submit(
                    draft: draft,
                    material: material,
                    reservation: reservation
                )
            } else if draft.asset.networkID == AptosConstants.networkID {
                receipt = try await SendAptosTransactionService().submit(
                    draft: draft,
                    material: material,
                    reservation: reservation
                )
            } else if draft.asset.networkID == StellarConstants.networkID {
                receipt = try await SendStellarTransactionService().submit(
                    draft: draft,
                    material: material,
                    reservation: reservation
                )
            } else if ReceiveNetworkCatalog.network(
                for: draft.asset.networkID
            )?.chainID ?? 0 > 0 {
                receipt = try await SendEVMTransactionService().submit(
                    draft: draft,
                    material: material,
                    reservation: reservation
                )
            } else {
                throw SendTransactionSubmissionError.unsupportedNetwork
            }
        } catch let error as SendTransactionSubmissionError {
            if let receipt = error.unconfirmedReceipt {
                _ = try? await database.recordSubmittedSend(
                    receipt: receipt,
                    draft: draft,
                    outcome: .outcomeUnknown
                )
            } else if error.wasExecutedOnNetwork,
                      let receipt = error.transactionEvidenceReceipt {
                _ = try? await database.recordSubmittedSend(
                    receipt: receipt,
                    draft: draft,
                    outcome: .executionFailed
                )
            }
            if case .broadcastRejected = error {
                try? await database.releaseSendSpendReservation(
                    reservation
                )
            } else {
                try? await database.releaseSendSpendReservation(
                    reservation,
                    onlyIfPreparing: true
                )
                try? await database.finishSendSpendSubmission(reservation)
            }
            throw error
        } catch {
            try? await database.releaseSendSpendReservation(
                reservation,
                onlyIfPreparing: true
            )
            if let evidence = try? await database
                .sendSpendReservationEvidence(
                    accountID: reservation.accountID
                ),
               evidence.reservationID == reservation.reservationID,
               let receipt = evidence.statusReceipt {
                try? await database.finishSendSpendSubmission(reservation)
                let unknown = SendTransactionSubmissionError
                    .broadcastOutcomeUnknown(
                        networkID: reservation.networkID,
                        code: error is CancellationError
                            ? "cancelled_after_broadcast_started"
                            : SendTransactionSubmissionError
                                .sanitizedErrorType(error),
                        receipt: receipt
                    )
                throw unknown
            }
            throw error
        }

        try? await database.finishSendSpendSubmission(reservation)
        do {
            let localTransactionID = try await database.recordSubmittedSend(
                receipt: receipt,
                draft: draft,
                outcome: .accepted
            )
            return SendTransactionSubmissionOutcome(
                receipt: receipt,
                localTransactionID: localTransactionID,
                localPersistenceWarningCode: nil
            )
        } catch {
            return SendTransactionSubmissionOutcome(
                receipt: receipt,
                localTransactionID: nil,
                localPersistenceWarningCode:
                    Self.persistenceCode(error)
            )
        }
    }

    func acquireSpendReservation(
        material: SendResolvedSigningMaterial,
        mayReconcile: Bool = true
    ) async throws -> SendSpendReservation {
        do {
            return try await database.acquireSendSpendReservation(
                material: material
            )
        } catch let error as SendSpendReservationStoreError {
            guard case let .conflict(evidence) = error else {
                throw SendTransactionSubmissionError.persistence(
                    code: Self.persistenceCode(error)
                )
            }
            guard mayReconcile,
                  let receipt = evidence.statusReceipt else {
                throw SendTransactionSubmissionError
                    .spendAlreadyReserved(
                        networkID: evidence.networkID,
                        stateCode: evidence.state.rawValue
                    )
            }

            // This also repairs an already-blocked Bitcoin send created by the
            // previous app version, without waiting for its parent to confirm.
            if (try? await recoverLegacySpendReservation(evidence)) == true {
                return try await acquireSpendReservation(material: material, mayReconcile: false)
            }

            let status: SendTransactionNetworkStatus
            do {
                status = try await SendTransactionStatusService()
                    .status(for: receipt)
            } catch {
                throw SendTransactionSubmissionError
                    .spendAlreadyReserved(
                        networkID: evidence.networkID,
                        stateCode: SendTransactionStatusService
                            .diagnosticCode(error)
                    )
            }
            guard status.isTerminal else {
                throw SendTransactionSubmissionError
                    .spendAlreadyReserved(
                        networkID: evidence.networkID,
                        stateCode: status.rawValue
                    )
            }
            do {
                _ = try await database.updateSubmittedSendStatus(
                    receipt: receipt,
                    status: status
                )
            } catch {
                throw SendTransactionSubmissionError.persistence(
                    code: Self.persistenceCode(error)
                )
            }
            return try await acquireSpendReservation(
                material: material,
                mayReconcile: false
            )
        } catch {
            throw SendTransactionSubmissionError.persistence(
                code: Self.persistenceCode(error)
            )
        }
    }

    static func persistenceCode(_ error: Error) -> String {
        if let error = error as? WalletDataStoreError {
            return switch error {
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
        if let error = error as? DatabaseError {
            return switch error.resultCode {
            case .SQLITE_FULL:
                "storage_full"
            case .SQLITE_BUSY, .SQLITE_LOCKED:
                "database_busy"
            case .SQLITE_READONLY, .SQLITE_PERM, .SQLITE_CANTOPEN,
                 .SQLITE_IOERR:
                "database_write"
            case .SQLITE_CORRUPT, .SQLITE_NOTADB:
                "database_integrity"
            case .SQLITE_CONSTRAINT:
                "database_constraint"
            default:
                "database_\(error.resultCode.rawValue)"
            }
        }
        if let error = error as? CocoaError {
            return "cocoa_\(error.code.rawValue)"
        }
        return SendTransactionSubmissionError.sanitizedErrorType(error)
    }
}

struct SendPostBroadcastChainRefreshID: Hashable, Sendable {
    let walletID: String
    let networkID: String
    let transactionHash: String

    init(walletID: String, receipt: SendTransactionReceipt) {
        self.walletID = walletID
        networkID = receipt.networkID
        transactionHash = WalletDatabase.normalizedSendHash(
            receipt.transactionHash, networkID: receipt.networkID)
    }
}

enum SendPostBroadcastChainRefreshPolicy {
    static let delay: Duration = .seconds(2)

    static func refreshReceipt(
        for error: SendTransactionSubmissionError
    ) -> SendTransactionReceipt? {
        // A rejected submission can still reveal stale spendable balances.
        // Refresh it once; its definitive result must not become pending.
        error.transactionEvidenceReceipt
    }
}

struct SendPostBroadcastChainRefreshScheduler: Sendable {
    typealias Sleeper = @Sendable (Duration) async throws -> Void

    let delay: Duration
    private let sleeper: Sleeper

    init(
        delay: Duration = SendPostBroadcastChainRefreshPolicy.delay,
        sleeper: @escaping Sleeper = { duration in
            try await Task.sleep(for: duration)
        }
    ) {
        self.delay = delay
        self.sleeper = sleeper
    }

    func wait() async -> Bool {
        do {
            try await sleeper(delay)
            try Task.checkCancellation()
            return true
        } catch {
            return false
        }
    }
}

enum SendPostBroadcastChainRefreshRoute: Sendable {
    case evm
    case bitcoinFamily(BitcoinFamilyChain)
    case solana
    case tron
    case ton
    case sui
    case xrp
    case near
    case aptos
    case stellar

    static func resolve(networkID: String) throws -> Self {
        if let chain = BitcoinFamilyChain(rawValue: networkID) {
            return .bitcoinFamily(chain)
        }
        return switch networkID {
        case SolanaConstants.networkID:
            .solana
        case TronConstants.networkID:
            .tron
        case TONConstants.networkID:
            .ton
        case SuiConstants.networkID:
            .sui
        case XRPConstants.networkID:
            .xrp
        case NEARConstants.networkID:
            .near
        case AptosConstants.networkID:
            .aptos
        case StellarConstants.networkID:
            .stellar
        default:
            if AnkrAPIClient.supportsTokenLookup(networkID: networkID) {
                .evm
            } else {
                throw SendPostBroadcastChainRefreshError
                    .unsupportedNetwork(networkID)
            }
        }
    }
}

enum SendPostBroadcastChainRefreshError: Error, Equatable, Sendable {
    case unsupportedNetwork(String)
    case accountUnavailable(String)
}

actor SendPostBroadcastChainRefreshService {
    let database: WalletDatabase

    init(database: WalletDatabase) {
        self.database = database
    }

    func refresh(
        walletID: String,
        receipt: SendTransactionReceipt,
        onProgress: WalletSyncProgressHandler? = nil
    ) async -> WalletChainSyncOutcome {
        do {
            switch try SendPostBroadcastChainRefreshRoute.resolve(
                networkID: receipt.networkID
            ) {
            case .evm:
                return await refreshEVM(
                    walletID: walletID,
                    receipt: receipt,
                    onProgress: onProgress
                )
            case let .bitcoinFamily(chain):
                let service = BitcoinFamilySyncService(database: database)
                guard let material = try await service.accountMaterials(walletID: walletID)
                    .first(where: { $0.chain == chain }) else {
                    throw SendPostBroadcastChainRefreshError.accountUnavailable(receipt.networkID)
                }
                // Read confirmed + mempool balance immediately. Do not wait for
                // historical transactions, prices or address enrichment.
                do {
                    try await service.refreshBalance(material: material, walletID: walletID, onProgress: onProgress)
                    return WalletChainSyncOutcome(source: .bitcoinFamily, didPersistData: true, failures: [])
                } catch {
                    return .failure(.bitcoinFamily, stage: .providerRead, error: error, networkID: receipt.networkID)
                }
            case .solana:
                return await SolanaSyncService(database: database).sync(
                    walletID: walletID,
                    requiresFresh: true,
                    onProgress: onProgress
                )
            case .tron:
                return await TronSyncService(database: database).sync(
                    walletID: walletID,
                    onProgress: onProgress
                )
            case .ton:
                return await TONSyncService.shared.sync(
                    walletID: walletID,
                    onProgress: onProgress
                )
            case .sui:
                return await SuiSyncService.shared.sync(
                    walletID: walletID,
                    onProgress: onProgress
                )
            case .xrp:
                return await XRPSyncService.shared.sync(
                    walletID: walletID,
                    onProgress: onProgress
                )
            case .near:
                return await NEARSyncService.shared.sync(
                    walletID: walletID,
                    onProgress: onProgress
                )
            case .aptos:
                return await AptosSyncService.shared.sync(
                    walletID: walletID,
                    onProgress: onProgress
                )
            case .stellar:
                return await StellarSyncService.shared.sync(
                    walletID: walletID,
                    onProgress: onProgress
                )
            }
        } catch {
            return .failure(
                .evm,
                stage: .accountPreparation,
                error: error,
                networkID: receipt.networkID
            )
        }
    }

    private func refreshEVM(
        walletID: String,
        receipt: SendTransactionReceipt,
        onProgress: WalletSyncProgressHandler?
    ) async -> WalletChainSyncOutcome {
        let persistence = WalletSyncPersistenceTracker()
        var failureStage = WalletSyncFailureStage.accountPreparation
        do {
            let accounts = try await WalletDataStore(
                database: database
            ).accounts(walletID: walletID)
            guard let account = accounts.first(where: {
                $0.id == receipt.accountID
                    && $0.networkID == receipt.networkID
                    && $0.isEnabled
            }) else {
                throw SendPostBroadcastChainRefreshError
                    .accountUnavailable(receipt.networkID)
            }

            let historicalPrices = try await database
                .cachedAnkrHistoricalTokenPrices(walletID: walletID)
            let historyFromTimestamp = max(
                0,
                Int64(receipt.submittedAt.timeIntervalSince1970) - 600
            )
            let client = try AnkrAPIClient.localBuild()
            async let providerOutcome = client.loadNetworkWithOutcome(
                address: account.address,
                networkID: receipt.networkID,
                historyFromTimestamp: historyFromTimestamp,
                cachedHistoricalTokenPrices: historicalPrices
            ) { [self] balanceSnapshot in
                try await self.database.saveWalletSnapshot(
                    balanceSnapshot,
                    address: account.address
                )
                await persistence.markPersisted()
                await onProgress?(
                    WalletSyncProgressEvent(
                        source: .evm,
                        networkID: receipt.networkID,
                        stage: .balancesPersisted
                    )
                )
            }

            failureStage = .trackedAssetRead
            let trackedTargets = try await database
                .trackedEVMTokenBalanceTargets(walletID: walletID)
                .filter { $0.networkID == receipt.networkID }
            async let trackedBalances = TrackedEVMTokenBalanceService()
                .loadBalances(for: trackedTargets)

            failureStage = .providerRead
            let providerResult = try await providerOutcome
            let directTrackedBalances = try await trackedBalances
            try Task.checkCancellation()

            failureStage = .persistence
            try await database.saveWalletSnapshot(
                providerResult.snapshot,
                address: account.address,
                trackedTokenBalances: directTrackedBalances
            )
            try await database.saveAnkrHistoricalTokenPrices(
                providerResult.historicalTokenPrices,
                walletID: walletID
            )
            await persistence.markPersisted()
            await publishWalletSyncDatasets(
                source: .evm,
                networkID: receipt.networkID,
                onProgress: onProgress
            )
            return .persistedEVM(
                providerFailures: providerResult.failures,
                failedTrackedTokenCount:
                    directTrackedBalances.failedHoldingIDs.count
            )
        } catch is CancellationError {
            return WalletChainSyncOutcome(
                source: .evm,
                didPersistData: await persistence.didPersistData,
                failures: []
            )
        } catch {
            return WalletChainSyncOutcome(
                source: .evm,
                didPersistData: await persistence.didPersistData,
                failures: [
                    WalletChainSyncFailure(
                        source: .evm,
                        stage: failureStage,
                        error: error,
                        networkID: receipt.networkID
                    )
                ]
            )
        }
    }
}

extension AppRootView {
    @MainActor
    func schedulePostBroadcastChainRefresh(
        request: SendPostBroadcastRefreshRequest,
        context: AppRootResolvedWalletContext
    ) {
        let receipt = request.receipt
        let refreshID = SendPostBroadcastChainRefreshID(
            walletID: context.identity.walletID,
            receipt: receipt
        )
        if let previous = postBroadcastChainRefreshTasks[refreshID] {
            guard request.knownTerminalStatus != nil, previous.knownTerminalStatus == nil else { return }
            // Confirmation monitoring wakes this path immediately, even when
            // the pending-balance worker is in its thirty-second backoff.
            previous.task.cancel()
        }
        let taskID = UUID()
        let database = database
        let task = Task { @MainActor in
            defer {
                if postBroadcastChainRefreshTasks[refreshID]?.id == taskID {
                    postBroadcastChainRefreshTasks[refreshID] = nil
                }
            }
            let onProgress: WalletSyncProgressHandler = { event in
                guard !Task.isCancelled,
                      event.networkID == nil
                        || event.networkID == receipt.networkID,
                      walletPresentation.accepts(context) else {
                    return
                }
                await publishCachedSnapshot(
                    context: context,
                    scope: event.stage.publicationScope
                )
            }
            await SendPostBroadcastBalanceFollowUp().run(
                knownTerminalStatus: request.knownTerminalStatus,
                snapshot: { try await database.sendBalanceSnapshot(receipt: receipt) },
                status: {
                    if let stored = try await database.persistedTerminalSendStatus(receipt) { return stored }
                    return try await SendStatusRequestPool.shared.status(for: receipt)
                },
                refresh: { terminal in
                    let outcome = await SendPostBroadcastBalanceRefreshPool.shared.refresh(
                        database: database, walletID: context.identity.walletID,
                        receipt: receipt, afterInFlightRead: terminal != nil, onProgress: onProgress)
                    return outcome.didPersistData && outcome.failures.isEmpty
                }
            )
        }
        postBroadcastChainRefreshTasks[refreshID] = .init(
            id: taskID, knownTerminalStatus: request.knownTerminalStatus, task: task)
    }

    @MainActor
    func cancelPostBroadcastChainRefreshes() {
        postBroadcastChainRefreshTasks.values.forEach { $0.task.cancel() }
        postBroadcastChainRefreshTasks.removeAll(keepingCapacity: false)
    }
}
