import Foundation
import GRDB
import Observation

@MainActor
@Observable
final class NotificationTransactionDetailModel {
    typealias StatusReader = @Sendable (NotificationTransactionContext) async throws -> SendTransactionNetworkStatus
    let notification: DBNotificationRecord
    let database: WalletDatabase
    private let statusReader: StatusReader
    private let sleep: @Sendable (Duration) async throws -> Void
    private let refreshHistory: @Sendable () async throws -> Void
    var context: NotificationTransactionContext?
    var isLoading = true
    var failureCode: String?

    init(notification: DBNotificationRecord, database: WalletDatabase,
         statusReader: StatusReader? = nil,
         refreshHistory: (@Sendable () async throws -> Void)? = nil,
         sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.sleep = sleep
        self.notification = notification
        self.database = database
        let service = SendTransactionStatusService()
        let tonProvider = NotificationTONStatusProvider()
        self.statusReader = statusReader ?? { context in
            if context.record.networkID == TONConstants.networkID {
                return try await tonProvider.status(
                    hash: context.record.transactionHash, accountAddress: context.account.address,
                    contractAddress: context.transaction.metadata.contractAddress,
                    sender: context.transaction.metadata.fromAddress, recipient: context.transaction.metadata.toAddress
                )
            }
            if context.record.networkID == NEARConstants.networkID,
               context.transaction.metadata.fromAddress?.isEmpty != false {
                throw SendTransactionStatusProviderError.invalidAccount(networkID: NEARConstants.networkID)
            }
            return try await service.status(for: context.receipt)
        }
        self.refreshHistory = refreshHistory ?? {
            try await NotificationTransactionRefreshService(database: database).refresh(notification)
        }
    }

    func run() async {
        async let observation: Void = observe()
        await monitor()
        await observation
    }

    private func observe() async {
        do {
            let notification = notification
            let observation = ValueObservation.tracking { db in
                try NotificationTransactionStore.context(for: notification, in: db)
            }
            for try await value in observation.values(in: database.pool, bufferingPolicy: .bufferingNewest(1)) {
                guard !Task.isCancelled else { return }
                context = value
            }
        } catch {
            guard !Task.isCancelled else { return }
            failureCode = SendTransactionStatusService.diagnosticCode(error)
        }
    }

    private func loadContext() async throws -> NotificationTransactionContext? {
        let notification = notification
        return try await database.pool.read { db in
            try NotificationTransactionStore.context(for: notification, in: db)
        }
    }

    func monitor() async {
        isLoading = context == nil
        failureCode = nil
        defer { isLoading = false }
        do {
            // Providers often deliver pushes before their history index catches up.
            // Keep the placeholder alive across empty responses and transient failures.
            var hydrationFailures = 0
            var current = try await loadContext()
            while current == nil {
                try Task.checkCancellation()
                do {
                    try await refreshHistory()
                    failureCode = nil
                } catch is CancellationError { throw CancellationError() }
                catch {
                    failureCode = Self.code(error)
                }
                try Task.checkCancellation()
                // A partial refresh can persist this transaction and still report
                // an unrelated provider failure. Always check the database again.
                current = try await loadContext()
                if current == nil {
                    hydrationFailures += 1
                    try await sleep(Self.retryDelay(attempt: hydrationFailures, code: failureCode))
                    current = try await loadContext()
                }
            }
            guard let loaded = current else { return }
            context = loaded
            isLoading = false
            if loaded.record.status == "canceled" { return }
            if BitcoinFamilyChain(rawValue: loaded.record.networkID) != nil,
               loaded.transaction.metadata.fromAddress == nil || loaded.transaction.metadata.toAddress == nil {
                do {
                    _ = try await BitcoinFamilyTransactionIdentityResolver(database: database)
                        .resolveAndPersist(transactionID: loaded.record.id)
                } catch is CancellationError { return }
                catch { failureCode = Self.code(error) }
            }
            let identityFailure = failureCode
            var failures = 0
            while !Task.isCancelled {
                guard let latest = try await loadContext() else { context = nil; return }
                if latest.record.status == "canceled" { return }
                do {
                    let status = try await statusReader(latest)
                    try Task.checkCancellation()
                    try await NotificationTransactionStore.persist(status, context: latest, database: database)
                    context = try await loadContext()
                    failureCode = identityFailure
                    failures = 0
                    if status.isTerminal || latest.record.status != "pending" { return }
                } catch is CancellationError { return }
                catch {
                    try Task.checkCancellation()
                    failureCode = Self.code(error)
                    failures += 1
                    if latest.record.status != "pending" { return }
                }
                // Pending-only monitoring, with bounded backoff after failures.
                try await sleep(Self.retryDelay(attempt: failures, code: failureCode))
            }
        } catch is CancellationError { return }
        catch {
            guard !Task.isCancelled else { return }
            failureCode = Self.code(error)
        }
    }

    static func retryDelay(attempt: Int, code: String?) -> Duration {
        // Avoid hammering a throttled endpoint. Empty index responses also back off.
        if code?.contains("429") == true { return .seconds(30) }
        return .seconds(min(30, 4 * (1 << min(max(attempt, 0), 3))))
    }

    private static func code(_ error: Error) -> String {
        if let failure = error as? NotificationTransactionRefreshFailure {
            return SendTransactionSubmissionError.sanitizedMessage(failure.code)
        }
        return SendTransactionStatusService.diagnosticCode(error)
    }
}
