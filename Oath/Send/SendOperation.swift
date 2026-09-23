import Foundation
import Observation

/// Owns one authorized submission independently of any sheet or receipt view.
/// The authorization is captured only by the submission task, never retained by UI history.
@MainActor @Observable
final class SendOperation: Identifiable {
    let id = UUID()
    let database: WalletDatabase
    let draft: SendDraft
    let walletAddress: String
    let nativeUnitUSDPrice: Decimal?
    private(set) var activityAssetUnitUSDPrice: Decimal?
    @ObservationIgnored private var didLoadActivityPrice = false
    @ObservationIgnored private let onTransactionBroadcast: (SendPostBroadcastRefreshRequest) -> Void
    @ObservationIgnored private let statusReader: @Sendable (SendTransactionReceipt) async throws -> SendTransactionNetworkStatus
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var monitoringTask: Task<Void, Never>?
    @ObservationIgnored let capsuleDismissal = SendActivityDismissalTimer()
    private(set) var didStart = false
    @ObservationIgnored private var monitoringAllowed = true
    @ObservationIgnored private var hasAnnouncedFailure = false
    @ObservationIgnored private var hasAnnouncedConfirmation = false
    private(set) var hasReadNetworkStatus = false
    var isAcknowledged = false {
        didSet { if isAcknowledged { capsuleDismissal.cancel() } }
    }
    private(set) var capsulePresentationID = UUID()
    enum Phase {
        case submitting
        case submitted(SendTransactionSubmissionOutcome)
        case failed(SendTransactionSubmissionError)
    }

    enum ReceiptVisualStatus {
        case submitting
        case submitted
        case confirmed
        case warning
        case failed
    }

    enum CapsuleStatus: Equatable, Sendable {
        case sending
        case sent
        case confirming
        case confirmed
        case warning
        case failed

        var titleKey: String {
            switch self {
            case .sending: "send.activity.sending"
            case .sent: "send.activity.sent"
            case .confirming: "send.activity.confirming"
            case .confirmed: "wallet.activity.status.confirmed"
            case .warning: "send.broadcast.warning.title"
            case .failed: "wallet.activity.status.failed"
            }
        }

        var showsProgress: Bool { self == .sending || self == .confirming }
    }

    var phase: Phase = .submitting {
        didSet {
            announceTerminalStatusIfNeeded()
            capsuleDismissal.invalidateIfNeeded(for: self)
        }
    }
    var networkStatus: SendTransactionNetworkStatus? {
        didSet {
            announceTerminalStatusIfNeeded()
            capsuleDismissal.invalidateIfNeeded(for: self)
        }
    }
    var monitoringWarningCode: String? {
        didSet { capsuleDismissal.invalidateIfNeeded(for: self) }
    }
    var statusPersistenceWarningCode: String?
    var localPersistenceWarningCode: String?
    var localTransactionID: String?
    var transactionNote: String?
    var isPersistingNote = false
    var noteFeedbackKey: String?
    var noteFeedbackIsSuccess = false

    init(database: WalletDatabase, draft: SendDraft, walletAddress: String,
         nativeUnitUSDPrice: Decimal?,
         onTransactionBroadcast: @escaping (SendPostBroadcastRefreshRequest) -> Void = { _ in },
         statusReader: @escaping @Sendable (SendTransactionReceipt) async throws -> SendTransactionNetworkStatus = {
             try await SendStatusRequestPool.shared.status(for: $0)
         }) {
        self.database = database
        self.draft = draft
        self.walletAddress = walletAddress
        self.nativeUnitUSDPrice = nativeUnitUSDPrice
        self.onTransactionBroadcast = onTransactionBroadcast
        self.statusReader = statusReader
    }

    var isSubmitting: Bool {
        if case .submitting = phase { return true }
        return false
    }

    /// Reuse an identity-matched quote already in the app; showing a banner
    /// must not add a network price request to an in-flight transaction.
    func loadActivityPriceIfNeeded() async {
        guard !didLoadActivityPrice else { return }
        didLoadActivityPrice = true
        guard SendAmountPresentation.unitUSDPrice(
            for: draft.asset, nativeUnitUSDPrice: nativeUnitUSDPrice
        ) == nil else { return }
        let assetID = AssetIdentityKey.canonical(draft.asset.id)
        if let quote = try? await database.cachedAssetUSDPrice(assetID: assetID),
           AssetIdentityKey.canonical(quote.assetID) == assetID, quote.price > 0 {
            activityAssetUnitUSDPrice = quote.price
        }
    }

    var activityAssetSubtitle: String { draft.asset.name + " · " + draft.asset.symbol }

    var canRetry: Bool {
        guard case let .failed(error) = phase else { return false }
        return networkStatus != .confirmed && error.allowsRetry
    }

    /// Calling this again (including when details reopen) never starts a second broadcast.
    func start(submission: @escaping @Sendable () async throws -> SendTransactionSubmissionOutcome) {
        guard !didStart else { return }
        didStart = true
        work = Task { [self] in
            // Synchronous UI-owned prefix records that this operation has started.
            phase = .submitting
            let result: Phase
            do {
                result = .submitted(try await submission())
            } catch let error as SendTransactionSubmissionError {
                result = .failed(error)
            } catch {
                result = .failed(.signing(code: "unexpected",
                    message: SendTransactionSubmissionError.sanitizedErrorType(error)))
            }
            finishSubmission(result)
            if monitoringAllowed, let monitoringReceipt {
                beginMonitoring(monitoringReceipt)
            }
            work = nil
        }
    }

    /// Stop reads without cancelling a broadcast that may already have reached the network.
    func stopMonitoring() {
        monitoringAllowed = false
        monitoringTask?.cancel()
        monitoringTask = nil
    }

    func waitUntilSettled() async {
        await work?.value
        await monitoringTask?.value
    }

    private func beginMonitoring(_ receipt: SendTransactionReceipt) {
        // A separate task releases the submission closure and its consumed capability promptly.
        monitoringTask = Task { [self] in
            monitoringWarningCode = nil
            await monitorTransaction(receipt)
            monitoringTask = nil
        }
    }

    var heroCopy: SendBroadcastHeroCopy {
        switch receiptVisualStatus {
        case .submitting:
            .submitting
        case .submitted:
            .submitted
        case .confirmed:
            .confirmed
        case .warning:
            .warning
        case .failed:
            networkStatus == .failed || submissionWasExecuted
                ? .executionFailed
                : .notSent
        }
    }

    var receiptVisualStatus: ReceiptVisualStatus {
        if networkStatus == .confirmed {
            return .confirmed
        }
        if networkStatus == .failed {
            return .failed
        }
        if networkStatus == .notFound || networkStatus == .replaced || networkStatus == .canceled {
            return .warning
        }
        switch phase {
        case .submitting:
            return .submitting
        case .submitted:
            return monitoringWarningCode == nil ? .submitted : .warning
        case let .failed(error):
            return error.submissionMayHaveSucceeded
                && !error.wasExecutedOnNetwork ? .warning : .failed
        }
    }

    var capsuleStatus: CapsuleStatus {
        switch receiptVisualStatus {
        case .submitting: .sending
        case .submitted: hasReadNetworkStatus ? .confirming : .sent
        case .confirmed: .confirmed
        case .warning: .warning
        case .failed: .failed
        }
    }

    private func announceTerminalStatusIfNeeded() {
        switch receiptVisualStatus {
        case .confirmed:
            guard !hasAnnouncedConfirmation else { return }
            hasAnnouncedConfirmation = true
        case .failed:
            guard !hasAnnouncedFailure else { return }
            hasAnnouncedFailure = true
        case .submitting, .submitted, .warning:
            return
        }
        // Keep a visible capsule mounted: fast confirmation updates its title
        // and badge in place. Only a previously hidden result needs a fresh
        // presentation, which also clears its completed dismissal gesture.
        if isAcknowledged { capsulePresentationID = UUID() }
        isAcknowledged = false
    }

    /// Acceptance alone is "Sent". A successful pending status read establishes
    /// "Confirming"; a failed read retains the explicit uncertain-status warning.
    func applyMonitoredStatus(_ status: SendTransactionNetworkStatus) {
        guard networkStatus?.isTerminal != true || status == networkStatus else { return }
        hasReadNetworkStatus = true
        monitoringWarningCode = nil
        networkStatus = status
    }

    var submissionWasExecuted: Bool {
        if case let .failed(error) = phase {
            return error.wasExecutedOnNetwork
        }
        return false
    }

    var receipt: SendTransactionReceipt? {
        switch phase {
        case let .submitted(outcome):
            return outcome.receipt
        case let .failed(error):
            return error.transactionEvidenceReceipt
        case .submitting:
            return nil
        }
    }

    var monitoringReceipt: SendTransactionReceipt? {
        switch phase {
        case let .submitted(outcome):
            return outcome.receipt
        case let .failed(error):
            guard error.submissionMayHaveSucceeded,
                  !error.wasExecutedOnNetwork else {
                return nil
            }
            return error.transactionEvidenceReceipt
        case .submitting:
            return nil
        }
    }

    @MainActor
    private func finishSubmission(_ completedPhase: Phase) {
        switch completedPhase {
        case let .submitted(outcome):
            networkStatus = .pending
            localTransactionID = outcome.localTransactionID
            localPersistenceWarningCode =
                outcome.localPersistenceWarningCode
            transactionNote = WalletTransactionNote.normalized(
                draft.note
            )
            UniHaptic.play(.success)
            onTransactionBroadcast(.init(receipt: outcome.receipt))
        case let .failed(error):
            networkStatus = error.wasExecutedOnNetwork ? .failed : .pending
            UniHaptic.play(.error)
            if let receipt = SendPostBroadcastChainRefreshPolicy
                .refreshReceipt(for: error) {
                onTransactionBroadcast(.init(receipt: receipt,
                    knownTerminalStatus: error.submissionMayHaveSucceeded ? nil : .failed))
            }
        case .submitting:
            break
        }
        phase = completedPhase
    }

    @MainActor
    func persistTransactionNote(_ rawNote: String) {
        guard !isPersistingNote,
              case let .submitted(outcome) = phase else {
            return
        }
        let note = WalletTransactionNote.normalized(rawNote)
        isPersistingNote = true
        noteFeedbackKey = nil

        Task { @MainActor in
            do {
                let transactionID: String
                if let localTransactionID {
                    transactionID = localTransactionID
                } else {
                    transactionID = try await database.recordSubmittedSend(
                        receipt: outcome.receipt,
                        draft: draft.replacingNote(nil),
                        outcome: .accepted
                    )
                    localTransactionID = transactionID
                    localPersistenceWarningCode = nil
                }
                try await database.setTransactionNote(
                    transactionID: transactionID,
                    note: note
                )
                transactionNote = note
                noteFeedbackIsSuccess = true
                noteFeedbackKey =
                    "wallet.transaction.details.notes.saved"
                UniHaptic.play(.successQuiet)

                if let networkStatus, networkStatus.isTerminal {
                    _ = try? await database.updateSubmittedSendStatus(
                        receipt: outcome.receipt,
                        status: networkStatus
                    )
                }
            } catch {
                noteFeedbackIsSuccess = false
                noteFeedbackKey = WalletTransactionNoteFailure
                    .messageKey(for: error)
                UniHaptic.play(.error)
            }
            isPersistingNote = false
        }
    }

    @MainActor
    private func monitorTransaction(
        _ receipt: SendTransactionReceipt
    ) async {
        var failures = 0
        var terminalStatus: SendTransactionNetworkStatus?
        while !Task.isCancelled {
            do {
                let status: SendTransactionNetworkStatus
                if let terminalStatus { status = terminalStatus }
                else if let stored = try await database.persistedTerminalSendStatus(receipt) { status = stored }
                else { status = try await statusReader(receipt) }
                try Task.checkCancellation()
                if status.isTerminal, networkStatus?.isTerminal != true {
                    onTransactionBroadcast(.init(receipt: receipt, knownTerminalStatus: status))
                }
                applyMonitoredStatus(status)
                if !status.isTerminal { failures = 0 }
                if status.isTerminal {
                    terminalStatus = status
                    if status == .confirmed,
                       try await reconcileUnknownSubmissionAsConfirmed(
                           receipt
                       ) {
                        return
                    }
                    statusPersistenceWarningCode = nil
                    do {
                        if localTransactionID == nil, case .submitted = phase {
                            localTransactionID = try await database.recordSubmittedSend(receipt: receipt,
                                draft: draft, outcome: status == .confirmed ? .confirmed : (status == .failed ? .executionFailed : .accepted))
                            localPersistenceWarningCode = nil
                        }
                        _ = try await database.updateSubmittedSendStatus(
                            receipt: receipt,
                            status: status
                        )
                    } catch is CancellationError {
                        return
                    } catch {
                        statusPersistenceWarningCode =
                            SendTransactionSubmissionService
                                .persistenceCode(error)
                        failures += 1
                    }
                    if statusPersistenceWarningCode == nil { return }
                }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                failures += 1
                monitoringWarningCode = SendTransactionStatusService
                    .diagnosticCode(error)
            }
            do {
                try await Task.sleep(
                    for: SendTransactionStatusPollingPolicy.interval(networkID: receipt.networkID, failures: failures)
                )
            } catch {
                return
            }
        }
    }

    @MainActor
    private func reconcileUnknownSubmissionAsConfirmed(
        _ receipt: SendTransactionReceipt
    ) async throws -> Bool {
        guard case let .failed(error) = phase,
              error.submissionMayHaveSucceeded,
              error.transactionEvidenceReceipt == receipt else {
            return false
        }

        statusPersistenceWarningCode = nil
        do {
            localTransactionID = try await database.recordSubmittedSend(
                receipt: receipt,
                draft: draft,
                outcome: .confirmed
            )
            localPersistenceWarningCode = nil
        } catch {
            statusPersistenceWarningCode =
                SendTransactionSubmissionService.persistenceCode(error)
            throw error
        }

        guard !Task.isCancelled else { return true }
        transactionNote = WalletTransactionNote.normalized(draft.note)
        phase = .submitted(
            SendTransactionSubmissionOutcome(
                receipt: receipt,
                localTransactionID: localTransactionID,
                localPersistenceWarningCode: nil
            )
        )
        UniHaptic.play(.successQuiet)
        return true
    }

}
