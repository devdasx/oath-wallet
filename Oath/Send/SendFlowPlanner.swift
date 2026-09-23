import Foundation

enum SendFlowPreparation {
    static func prepare(
        _ request: SendPaymentRequest,
        walletAssets: [WalletAsset],
        capabilities: WalletCapabilities,
        selectedAsset: SendAssetChoice? = nil
    ) -> SendScanPreparation {
        do {
            if let selectedAsset {
                guard SendAssetChoiceCatalog.request(
                    request,
                    matches: selectedAsset
                ) else {
                    return .failed(
                        SendRecipientPasteError
                            .selectedAssetMismatch.localizedMessage
                    )
                }
                return .ready(
                    try SendFlowPlanner.recipientEntryRoute(
                        afterSelecting: selectedAsset,
                        for: request
                    )
                )
            }
            let choices = SendAssetChoiceCatalog.choices(
                from: walletAssets,
                capabilities: capabilities,
                for: request
            )
            return .ready(
                try SendFlowPlanner.initialRoute(
                    for: request,
                    choices: choices
                )
            )
        } catch let error as SendFlowPlanningError {
            return .failed(error.localizedMessage)
        } catch {
            return .failed(
                WalletLocalization.string(
                    "send.error.unsupported_format"
                )
            )
        }
    }
}

enum SendFlowPlanner {
    static let automaticallySelectedNativeNetworkIDs = Set(
        BitcoinFamilyChain.allCases.map(\.networkID)
    )

    static func manualEntryRoute(
        for asset: SendAssetChoice
    ) -> SendFlowRoute {
        let request = SendPaymentRequest.manualEntry(
            networkID: asset.networkID
        )
        return .recipient(
            SendDraft(
                request: request,
                asset: asset,
                recipient: "",
                amount: nil,
                note: nil
            ),
            nil
        )
    }

    static func recipientEntryRoute(
        afterSelecting asset: SendAssetChoice,
        for request: SendPaymentRequest
    ) throws -> SendFlowRoute {
        let resolvedRoute = try route(
            afterSelecting: asset,
            for: request
        )
        switch resolvedRoute {
        case let .review(draft), let .amount(draft, nil):
            return .recipient(draft, nil)
        case let .amount(draft, failure):
            return .recipient(draft, failure)
        default:
            return resolvedRoute
        }
    }

    static func initialRoute(
        for request: SendPaymentRequest,
        choices: [SendAssetChoice]
    ) throws -> SendFlowRoute {
        guard !choices.isEmpty else {
            switch request.requestedAsset {
            case .contract:
                throw SendFlowPlanningError
                    .requestedAssetUnavailable
            case .native, .unspecified:
                throw SendFlowPlanningError.unsupportedByWallet
            }
        }

        switch request.requestedAsset {
        case .native, .contract:
            if choices.count == 1, let choice = choices.first {
                return try route(
                    afterSelecting: choice,
                    for: request
                )
            }
            return .assetSelection(request)
        case .unspecified:
            let singleNetworkID = request.candidateNetworkIDs.count == 1
                ? request.candidateNetworkIDs.first
                : nil
            if let singleNetworkID,
               automaticallySelectedNativeNetworkIDs.contains(
                   singleNetworkID
               ),
               let nativeChoice = choices.first(where: {
                   $0.networkID == singleNetworkID && $0.isNative
               }) {
                return try route(
                    afterSelecting: nativeChoice,
                    for: request
                )
            }
            return .assetSelection(request)
        }
    }

    static func route(
        afterSelecting asset: SendAssetChoice,
        for request: SendPaymentRequest
    ) throws -> SendFlowRoute {
        let amount = try resolvedAmount(
            request.requestedAmount,
            asset: asset
        )
        let draft = SendDraft(
            request: request,
            asset: asset,
            recipient: request.recipient,
            amount: amount,
            note: nil
        )
        let recipientValidationIssue = recipientRouteIssue(
            request: request,
            asset: asset
        )
        let amountValidationIssue = amount.flatMap {
            amountIssue($0, asset: asset)
        }
        // Names must finish resolving, and networks with destination tags or
        // memos must give the user a Recipient step before entering the amount.
        if recipientValidationIssue != nil || request.source == .name
            || asset.networkID == XRPConstants.networkID
            || asset.networkID == StellarConstants.networkID {
            let failure = recipientValidationIssue != nil || amountValidationIssue != nil
                ? SendDraftValidationFailure(
                    recipientIssue: recipientValidationIssue,
                    amountIssue: amountValidationIssue
                ) : nil
            return .recipient(draft, failure)
        }
        if let amountValidationIssue {
            return .amount(
                draft,
                SendDraftValidationFailure(
                    recipientIssue: nil,
                    amountIssue: amountValidationIssue
                )
            )
        }
        guard amount != nil else {
            return .amount(draft, nil)
        }
        if SendRecipientRequirementNetworkRule.requiresLiveLookup(
                for: asset,
                recipient: request.recipient
            ) {
            return .amount(draft, nil)
        }
        return .review(draft)
    }

    static func amountEntryRoute(afterRecipient draft: SendDraft) -> SendFlowRoute {
        let recipientValidationIssue = recipientIssue(draft.recipient, asset: draft.asset)
        guard recipientValidationIssue == nil,
              SendAddressValidator.isValid(draft.recipient, for: draft.asset.networkID) else {
            return .recipient(draft, SendDraftValidationFailure(
                recipientIssue: recipientValidationIssue ?? .invalidForNetwork,
                amountIssue: nil
            ))
        }
        let issue = draft.amount.flatMap { amountIssue($0, asset: draft.asset) }
        return .amount(draft, issue.map {
            SendDraftValidationFailure(recipientIssue: nil, amountIssue: $0)
        })
    }

    static func amountIssue(
        _ amount: String,
        asset: SendAssetChoice
    ) -> SendAmountValidationIssue? {
        let parsed: SendDecimalAmount.Parsed
        do {
            parsed = try SendDecimalAmount.parseUserUnits(amount)
        } catch {
            return .invalid
        }
        if parsed.fractionDigits > asset.decimals {
            return .precision(asset.decimals)
        }
        if parsed.isZero {
            return .zero
        }

        let exceedsBalance: Bool
        if let balanceAtomic = asset.balanceAtomic,
           SendAtomicAmount.isCanonical(balanceAtomic),
           let requestedAtomic = try? SendAtomicAmount.fromUserUnits(
               parsed.canonical,
               decimals: asset.decimals
           ) {
            exceedsBalance = SendAtomicAmount.compare(
                requestedAtomic,
                balanceAtomic
            ) == .orderedDescending
        } else {
            let balance = SendDecimalAmount.decimalStorageText(
                max(asset.balance, 0)
            )
            exceedsBalance = SendDecimalAmount.compare(
                parsed.canonical,
                balance
            ) == .orderedDescending
        }
        if exceedsBalance {
            return .exceedsBalance
        }
        return nil
    }

    static func recipientIssue(
        _ recipient: String,
        asset: SendAssetChoice
    ) -> SendRecipientValidationIssue? {
        let trimmed = recipient.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !trimmed.isEmpty else { return .required }
        if SendAddressValidator.isValid(
            trimmed,
            for: asset.networkID
        ) {
            return SendSelfTransferPolicy.recipientIssue(trimmed, asset: asset)
        }
        if let nameIssue = SendRecipientNameParser.issue(
            for: trimmed,
            networkID: asset.networkID
        ) {
            return .name(nameIssue)
        }
        do {
            if let descriptor = try SendRecipientNameParser.descriptor(
                for: trimmed
            ) {
                return descriptor.candidateNetworkIDs.contains(
                    asset.networkID
                )
                    ? nil
                    : .name(.networkMismatch)
            }
        } catch let error as SendRecipientNameError {
            return .name(error)
        } catch {
            return .name(.invalidName)
        }
        return .invalidForNetwork
    }

    private static func recipientRouteIssue(
        request: SendPaymentRequest,
        asset: SendAssetChoice
    ) -> SendRecipientValidationIssue? {
        if request.source == .name {
            return recipientIssue(
                request.recipient,
                asset: asset
            )
        }
        guard request.candidateNetworkIDs.contains(
            asset.networkID
        ) else {
            return .invalidForNetwork
        }
        return SendAddressValidator.isValid(
            request.recipient,
            for: asset.networkID
        )
            ? SendSelfTransferPolicy.recipientIssue(request.recipient, asset: asset)
            : .invalidForNetwork
    }

    static func reviewDraft(
        from draft: SendDraft,
        recipient: String,
        amount: String,
        note: String?
    ) -> Result<SendDraft, SendDraftValidationFailure> {
        if let recipientIssue = recipientIssue(
            recipient,
            asset: draft.asset
        ) {
            return .failure(
                SendDraftValidationFailure(
                    recipientIssue: recipientIssue,
                    amountIssue: nil
                )
            )
        }
        if let amountIssue = amountIssue(
            amount,
            asset: draft.asset
        ) {
            return .failure(
                SendDraftValidationFailure(
                    recipientIssue: nil,
                    amountIssue: amountIssue
                )
            )
        }

        let canonicalAmount = try? SendDecimalAmount
            .parseUserUnits(
                amount,
                maximumFractionDigits: draft.asset.decimals
            )
            .canonical
        guard let canonicalAmount else {
            return .failure(
                SendDraftValidationFailure(
                    recipientIssue: nil,
                    amountIssue: .invalid
                )
            )
        }
        let reviewedDraft = draft.replacing(
            recipient: recipient.trimmingCharacters(
                in: .whitespacesAndNewlines
            ),
            amount: canonicalAmount,
            note: note
        )
        return .success(reviewedDraft)
    }

    private static func resolvedAmount(
        _ requestedAmount: SendRequestedAmount?,
        asset: SendAssetChoice
    ) throws -> String? {
        guard let requestedAmount else { return nil }
        switch requestedAmount {
        case let .userUnits(amount):
            return amount
        case let .atomicUnits(amount):
            return SendDecimalAmount.userUnits(
                fromAtomicUnits: amount,
                decimals: asset.decimals
            )
        }
    }
}

struct SendDraftValidationFailure:
    Error,
    Hashable,
    Sendable {
    let recipientIssue: SendRecipientValidationIssue?
    let amountIssue: SendAmountValidationIssue?
}

struct SendRecipientPasteFields: Hashable, Sendable {
    let request: SendPaymentRequest
    let recipient: String
    let amount: String?
}

enum SendRecipientPasteError: Error, Hashable, Sendable {
    case selectedAssetMismatch

    var localizedMessage: String {
        WalletLocalization.string(
            "send.recipient.error.paste_asset_mismatch"
        )
    }
}

enum SendRecipientPastePreparation {
    static func fields(
        from payload: String,
        selectedAsset asset: SendAssetChoice
    ) throws -> SendRecipientPasteFields {
        let request = try SendPaymentRequestParser.parse(payload)
        guard SendAssetChoiceCatalog.request(
            request,
            matches: asset
        ) else {
            throw SendRecipientPasteError.selectedAssetMismatch
        }

        let route = try SendFlowPlanner.route(
            afterSelecting: asset,
            for: request
        )
        let pastedDraft: SendDraft
        switch route {
        case let .recipient(draft, _),
             let .amount(draft, _),
             let .review(draft):
            pastedDraft = draft
        case .textAddressEntry, .assetSelection:
            throw SendRecipientPasteError.selectedAssetMismatch
        }
        return SendRecipientPasteFields(
            request: request,
            recipient: pastedDraft.recipient,
            amount: pastedDraft.amount
        )
    }
}
