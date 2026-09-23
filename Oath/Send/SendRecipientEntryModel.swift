import Foundation
import Observation

@MainActor
@Observable
final class SendRecipientEntryModel {
    let draft: SendDraft
    let initialValidationFailure: SendDraftValidationFailure?
    let nameResolution: SendRecipientNameResolutionModel
    private(set) var recipient: String
    private(set) var networkMemo: String
    private(set) var activeRequest: SendPaymentRequest
    private(set) var requestedAmount: String?
    private var usesMaximumBalance: Bool
    private(set) var hasEditedRecipient = false
    private(set) var hasEditedMemo = false
    private(set) var hasAttemptedContinue = false
    private(set) var actionError: String?
    var note: String
    var feePolicy: SendNetworkFeePolicy
    var bitcoinFamilyOptions: SendBitcoinFamilyOptions

    init(
        draft: SendDraft,
        initialValidationFailure: SendDraftValidationFailure? = nil,
        nameResolution: SendRecipientNameResolutionModel = .init()
    ) {
        self.draft = draft
        self.initialValidationFailure = initialValidationFailure
        self.nameResolution = nameResolution
        recipient = draft.recipient
        networkMemo = draft.request.memo ?? ""
        activeRequest = draft.request
        requestedAmount = draft.amount
        usesMaximumBalance = draft.usesMaximumBalance
        note = draft.note ?? ""
        feePolicy = draft.feePolicy
        bitcoinFamilyOptions = draft.bitcoinFamilyOptions
    }

    var isXRP: Bool { draft.asset.networkID == XRPConstants.networkID }
    var isStellar: Bool { draft.asset.networkID == StellarConstants.networkID }

    var requestMemo: String? {
        isXRP ? XRPDestinationTag.normalized(networkMemo)
            : isStellar ? StellarMemoTextValidator.normalized(networkMemo) : activeRequest.memo
    }

    var isResolvingName: Bool {
        nameResolution.isResolving(sourceRecipient: recipient, networkID: draft.asset.networkID)
    }

    var resolvedRecipient: String? {
        nameResolution.validatedRecipient(
            sourceRecipient: recipient, networkID: draft.asset.networkID
        )
    }

    var recipientIssue: SendRecipientValidationIssue? {
        if let issue = nameResolution.issue(
            sourceRecipient: recipient, networkID: draft.asset.networkID
        ) { return .name(issue) }
        // Validate the resolved address as well as direct entry. A name can
        // resolve successfully to the sender's own account.
        return SendFlowPlanner.recipientIssue(resolvedRecipient ?? recipient, asset: draft.asset)
    }

    var displayedRecipientIssue: SendRecipientValidationIssue? {
        // Prefilled requests and names must explain this block immediately,
        // even before the user edits the field or taps Continue.
        if recipientIssue == .selfTransferNotSupported { return recipientIssue }
        guard hasEditedRecipient || hasAttemptedContinue
                || initialValidationFailure?.recipientIssue != nil else { return nil }
        return recipientIssue
    }

    var hasInvalidMemo: Bool {
        if isXRP {
            return XRPDestinationTag.normalized(networkMemo) != nil
                && (try? XRPDestinationTag.parsed(networkMemo)) == nil
        }
        if isStellar {
            return StellarMemoTextValidator.normalized(networkMemo) != nil
                && StellarMemoTextValidator.validated(networkMemo) == nil
        }
        return false
    }

    var displayedMemoIssue: Bool {
        hasInvalidMemo && (hasEditedMemo || hasAttemptedContinue || !networkMemo.isEmpty)
    }

    var canContinue: Bool {
        actionError == nil && recipientIssue == nil && !hasInvalidMemo && !isResolvingName
            && resolvedRecipient != nil
    }

    func setRecipient(_ value: String) {
        guard value.utf8.count <= 255, !value.contains(where: \.isNewline),
              value != recipient else { return }
        recipient = value
        hasEditedRecipient = true
        actionError = nil
        scheduleNameResolution()
    }

    func setMemo(_ value: String) {
        let accepts = isXRP ? XRPDestinationTag.acceptsEditableInput(value)
            : StellarMemoTextValidator.acceptsEditableInput(value)
        guard accepts else { return }
        networkMemo = value
        hasEditedMemo = true
    }

    func scheduleNameResolution() {
        nameResolution.schedule(sourceRecipient: recipient, networkID: draft.asset.networkID)
    }

    @discardableResult
    func paste(_ payload: String) -> Bool {
        actionError = nil
        do {
            let fields = try SendRecipientPastePreparation.fields(
                from: payload, selectedAsset: draft.asset
            )
            nameResolution.cancel()
            activeRequest = fields.request
            if isXRP || isStellar {
                networkMemo = fields.request.memo ?? ""
                hasEditedMemo = fields.request.memo != nil
            }
            recipient = fields.recipient
            hasEditedRecipient = true
            if let amount = fields.amount {
                requestedAmount = amount
                usesMaximumBalance = false
            }
            scheduleNameResolution()
            return true
        } catch let error as SendPaymentRequestError {
            actionError = error.localizedMessage
        } catch let error as SendFlowPlanningError {
            actionError = error.localizedMessage
        } catch let error as SendRecipientNameError {
            actionError = error.localizedMessage
        } catch let error as SendRecipientPasteError {
            actionError = error.localizedMessage
        } catch {
            actionError = WalletLocalization.string("send.error.unsupported_format")
        }
        hasEditedRecipient = true
        return false
    }

    func applyScannedRecipient(_ value: String) {
        nameResolution.cancel()
        actionError = nil
        activeRequest = .manualEntry(networkID: draft.asset.networkID)
        recipient = value
        hasEditedRecipient = true
        scheduleNameResolution()
    }

    func applyRecentRecipient(_ saved: SendRecentRecipient) {
        guard let identity = SendRecipientIdentity(
            address: saved.address, networkID: draft.asset.networkID,
            memo: saved.networkMemo, memoRecorded: saved.id.memoRecorded
        ), identity == saved.id else { return }
        applyScannedRecipient(saved.address)
        // Restore exactly this recipient's routing, including an explicitly
        // absent memo. Never carry the previous recipient's tag across.
        activeRequest = activeRequest.replacingMemo(saved.networkMemo)
        networkMemo = saved.networkMemo ?? ""
        hasEditedMemo = saved.networkMemo != nil
    }

    func continueDraft() -> SendDraft? {
        hasAttemptedContinue = true
        guard canContinue, let resolvedRecipient else { return nil }
        return SendDraft(
            request: activeRequest.replacingMemo(requestMemo),
            asset: draft.asset,
            recipient: resolvedRecipient,
            amount: requestedAmount,
            note: WalletTransactionNote.normalized(note),
            feePolicy: feePolicy,
            bitcoinFamilyOptions: bitcoinFamilyOptions,
            usesMaximumBalance: usesMaximumBalance
        )
    }
}
