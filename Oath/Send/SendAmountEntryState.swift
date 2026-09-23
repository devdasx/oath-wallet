import Foundation

/// A value snapshot owned by the Amount screen. The flow retains it for Back
/// navigation without converting an unfinished local-currency input to crypto.
struct SendAmountEntryState: Equatable {
    var input: String
    private(set) var mode: SendAmountEntryMode = .asset
    private(set) var usesMaximumBalance: Bool
    private(set) var hasEditedAmount = false
    private(set) var hasAppliedPreferredMode = false
    var note: String
    var feePolicy: SendNetworkFeePolicy
    var bitcoinFamilyOptions: SendBitcoinFamilyOptions

    init(draft: SendDraft) {
        input = draft.amount ?? ""
        usesMaximumBalance = draft.usesMaximumBalance
        note = draft.note ?? ""
        feePolicy = draft.feePolicy
        bitcoinFamilyOptions = draft.bitcoinFamilyOptions
    }

    func maximumFractionDigits(for asset: SendAssetChoice) -> Int {
        mode == .asset ? max(asset.decimals, 0)
            : SendAmountEntryConverter.maximumLocalFractionDigits
    }

    @discardableResult
    mutating func press(_ key: SendAmountKey, asset: SendAssetChoice) -> Bool {
        guard let next = SendAmountKeypadInput.applying(
            key, to: input,
            maximumFractionDigits: maximumFractionDigits(for: asset)
        ), next != input else { return false }
        input = next
        usesMaximumBalance = false
        hasEditedAmount = true
        return true
    }

    func assetAmount(asset: SendAssetChoice, currency: WalletCurrencyContext, unitUSDPrice: Decimal? = nil) -> String? {
        try? SendAmountEntryConverter.assetAmount(
            from: SendAmountKeypadInput.submittableInput(input),
            mode: mode,
            usesMaximumBalance: usesMaximumBalance,
            asset: asset,
            currency: currency, unitUSDPrice: unitUSDPrice
        )
    }

    func amountIssue(asset: SendAssetChoice, currency: WalletCurrencyContext, unitUSDPrice: Decimal? = nil)
        -> SendAmountValidationIssue? {
        guard !input.isEmpty else { return .required }
        if mode == .localCurrency,
           SendAmountEntryConverter.pricing(asset: asset, currency: currency, unitUSDPrice: unitUSDPrice) == nil {
            return .localCurrencyUnavailable
        }
        guard let amount = assetAmount(asset: asset, currency: currency, unitUSDPrice: unitUSDPrice) else {
            return .invalid
        }
        return SendFlowPlanner.amountIssue(amount, asset: asset)
    }

    func coinControlIssue(asset: SendAssetChoice, currency: WalletCurrencyContext, unitUSDPrice: Decimal? = nil)
        -> SendBitcoinFamilyOptionsError? {
        guard case let .manual(outputs) = bitcoinFamilyOptions.coinSelection,
              let amount = assetAmount(asset: asset, currency: currency, unitUSDPrice: unitUSDPrice),
              let requested = try? SendNetworkFeeBaseUnitConverter.baseUnits(
                  from: amount, decimals: asset.decimals, permitsZero: false
              )
        else { return nil }
        let selected = SendBitcoinAtomicAmount.sum(outputs.map(\.valueAtomic))
        return SendBitcoinAtomicAmount.compare(selected, requested) == .orderedAscending
            ? .insufficientSelectedValue : nil
    }

    mutating func applyMaximum(asset: SendAssetChoice, currency: WalletCurrencyContext, unitUSDPrice: Decimal? = nil) throws {
        input = try SendAmountEntryConverter.maximumInput(
            mode: mode, asset: asset, currency: currency, unitUSDPrice: unitUSDPrice
        )
        usesMaximumBalance = true
        hasEditedAmount = true
    }

    mutating func changeMode(
        to nextMode: SendAmountEntryMode,
        asset: SendAssetChoice,
        currency: WalletCurrencyContext, unitUSDPrice: Decimal? = nil
    ) throws {
        guard mode != nextMode else { return }
        if nextMode == .localCurrency,
           SendAmountEntryConverter.pricing(asset: asset, currency: currency, unitUSDPrice: unitUSDPrice) == nil {
            throw SendAmountEntryConversionError.pricingUnavailable
        }
        let converted: String
        if usesMaximumBalance {
            converted = try SendAmountEntryConverter.maximumInput(
                mode: nextMode, asset: asset, currency: currency, unitUSDPrice: unitUSDPrice
            )
        } else if input.isEmpty {
            converted = ""
        } else {
            converted = try SendAmountEntryConverter.convertedInput(
                SendAmountKeypadInput.submittableInput(input),
                from: mode, to: nextMode, asset: asset, currency: currency, unitUSDPrice: unitUSDPrice
            )
        }
        input = converted
        mode = nextMode
        hasEditedAmount = true
    }

    mutating func applyPreferredMode(
        _ preferredMode: SendAmountEntryMode,
        asset: SendAssetChoice,
        currency: WalletCurrencyContext, unitUSDPrice: Decimal? = nil
    ) {
        guard !hasAppliedPreferredMode else { return }
        hasAppliedPreferredMode = true
        let previouslyEdited = hasEditedAmount
        try? changeMode(to: preferredMode, asset: asset, currency: currency, unitUSDPrice: unitUSDPrice)
        hasEditedAmount = previouslyEdited
    }

    func reviewDraft(from draft: SendDraft, currency: WalletCurrencyContext, unitUSDPrice: Decimal? = nil) -> SendDraft? {
        guard amountIssue(asset: draft.asset, currency: currency, unitUSDPrice: unitUSDPrice) == nil,
              coinControlIssue(asset: draft.asset, currency: currency, unitUSDPrice: unitUSDPrice) == nil,
              let amount = assetAmount(asset: draft.asset, currency: currency, unitUSDPrice: unitUSDPrice),
              SendAddressValidator.isValid(draft.recipient, for: draft.asset.networkID)
        else { return nil }
        return SendDraft(
            request: draft.request,
            asset: draft.asset,
            recipient: draft.recipient,
            amount: amount,
            note: WalletTransactionNote.normalized(note),
            feePolicy: feePolicy,
            bitcoinFamilyOptions: bitcoinFamilyOptions,
            usesMaximumBalance: usesMaximumBalance
        )
    }
}

enum SendAmountKey: Hashable {
    case digit(String)
    case decimal
    case delete
    case clear
}

enum SendAmountKeypadInput {
    static func applying(
        _ key: SendAmountKey, to input: String, maximumFractionDigits: Int
    ) -> String? {
        let next: String
        switch key {
        case let .digit(digit):
            guard digit.utf8.count == 1, let byte = digit.utf8.first,
                  (48...57).contains(byte) else { return nil }
            next = input == "0" ? digit : input + digit
        case .decimal:
            guard maximumFractionDigits > 0, !input.contains(".") else { return nil }
            next = input.isEmpty ? "0." : input + "."
        case .delete:
            // Deletion must also repair an over-precision amount from a URI.
            return input.isEmpty ? input : String(input.dropLast())
        case .clear:
            return ""
        }
        return SendDecimalAmount.acceptsEditableInput(
            next, maximumFractionDigits: maximumFractionDigits
        ) ? next : nil
    }

    static func submittableInput(_ input: String) -> String {
        // "1." is an unfinished fractional entry, but an exact whole-unit amount.
        input.hasSuffix(".") ? String(input.dropLast()) : input
    }
}
