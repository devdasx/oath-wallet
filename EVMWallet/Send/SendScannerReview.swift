import Foundation

struct SendScannerReview: Hashable {
    let request: SendPaymentRequest
    let route: SendFlowRoute
    private let currencyCode: String
    private let currencyRatePerUSD: Decimal

    init(
        request: SendPaymentRequest,
        route: SendFlowRoute,
        currencyContext: WalletCurrencyContext = WalletCurrencyContext(
            code: WalletCurrencyPreference.defaultCode,
            ratePerUSD: 1
        )
    ) {
        self.request = request
        self.route = route
        currencyCode = currencyContext.code
        currencyRatePerUSD = currencyContext.ratePerUSD
    }

    var presentation: SmartScannerReviewPresentation {
        SmartScannerReviewPresentation(
            kind: request.source == .bareAddress
                ? .address : .payment,
            heroLogoSource: heroLogoSource,
            titleKey: titleKey,
            detailKey: detailKey,
            rows: rows,
            warningKey: "send.scan.review.warning",
            primaryActionKey: primaryActionKey
        )
    }

    private var heroLogoSource: AssetLogoSource? {
        if let draft = resolvedDraft {
            return draft.asset.logoSource
        }
        if let networkID = request.requestedNetworkID,
           let network = ReceiveNetworkCatalog.network(
               for: networkID
           ) {
            return network.logoSource
        }
        if request.candidateNetworkIDs.count == 1,
           let networkID = request.candidateNetworkIDs.first,
           let network = ReceiveNetworkCatalog.network(
               for: networkID
           ) {
            return network.logoSource
        }
        return nil
    }

    private var titleKey: String {
        switch route {
        case .textAddressEntry:
            return "send.scan.review.address.title"
        case .review:
            return "send.scan.review.ready.title"
        case .assetSelection:
            return "send.scan.review.selection.title"
        case let .recipient(_, failure), let .amount(_, failure):
            return failure == nil
                ? "send.scan.review.address.title"
                : "send.scan.review.details.title"
        }
    }

    private var detailKey: String {
        switch route {
        case .textAddressEntry:
            return "send.scan.review.address.detail"
        case .review:
            return "send.scan.review.ready.detail"
        case .assetSelection:
            return "send.scan.review.selection.detail"
        case let .recipient(_, failure), let .amount(_, failure):
            return failure == nil
                ? "send.scan.review.address.detail"
                : "send.scan.review.details.detail"
        }
    }

    private var primaryActionKey: String {
        switch route {
        case .textAddressEntry:
            return "common.continue"
        case .review:
            return "send.scan.review.action.review_send"
        case .assetSelection:
            return "send.scan.review.action.choose_asset"
        case let .recipient(_, failure):
            if failure?.recipientIssue != nil {
                return "send.scan.enter_text_address.action"
            }
            return "common.continue"
        case .amount:
            return "send.scan.review.action.enter_amount"
        }
    }

    private var rows: [SmartScannerReviewRow] {
        var values: [SmartScannerReviewRow] = [
            SmartScannerReviewRow(
                id: "type",
                titleKey: "smart_scanner.review.field.type",
                value: WalletLocalization.string(
                    request.source == .name
                        ? "smart_scanner.review.value.recipient_name"
                        : request.source == .bareAddress
                            ? "smart_scanner.review.value.wallet_address"
                            : "smart_scanner.review.value.payment_request"
                )
            ),
            SmartScannerReviewRow(
                id: "recipient",
                titleKey: "smart_scanner.review.field.address",
                value: request.recipient
            ),
            SmartScannerReviewRow(
                id: "network",
                titleKey: "smart_scanner.review.field.network",
                value: networkValue
            ),
            SmartScannerReviewRow(
                id: "asset",
                titleKey: "smart_scanner.review.field.asset",
                value: assetValue
            )
        ]

        if let amountRow {
            values.append(amountRow)
        }
        if let attentionMessage {
            values.append(
                SmartScannerReviewRow(
                    id: "attention",
                    titleKey:
                        "smart_scanner.review.field.attention",
                    value: attentionMessage,
                    valueStyle: .warning
                )
            )
        }
        if let label = request.label {
            values.append(
                SmartScannerReviewRow(
                    id: "label",
                    titleKey: "smart_scanner.review.field.label",
                    value: label
                )
            )
        }
        if let message = request.message {
            values.append(
                SmartScannerReviewRow(
                    id: "message",
                    titleKey: "smart_scanner.review.field.message",
                    value: message
                )
            )
        }
        if let memo = request.memo {
            values.append(
                SmartScannerReviewRow(
                    id: "memo",
                    titleKey: "smart_scanner.review.field.memo",
                    value: memo
                )
            )
        }
        if !request.references.isEmpty {
            values.append(
                SmartScannerReviewRow(
                    id: "references",
                    titleKey:
                        "smart_scanner.review.field.references",
                    value: EnglishNumbers.localized(
                        "smart_scanner.review.value.references",
                        Int64(request.references.count)
                    )
                )
            )
        }
        return values
    }

    private var attentionMessage: String? {
        let failure: SendDraftValidationFailure?
        switch route {
        case let .recipient(_, issue), let .amount(_, issue):
            failure = issue
        default:
            return nil
        }
        if let recipientIssue = failure?.recipientIssue {
            return recipientIssue.localizedMessage
        }
        return failure?.amountIssue?.localizedMessage
    }

    private var resolvedDraft: SendDraft? {
        switch route {
        case let .review(draft),
             let .recipient(draft, _),
             let .amount(draft, _):
            draft
        case .textAddressEntry, .assetSelection:
            nil
        }
    }

    private var networkValue: String {
        if let draft = resolvedDraft {
            return draft.asset.networkName
        }
        if let networkID = request.requestedNetworkID,
           let network = ReceiveNetworkCatalog.network(
               for: networkID
           ) {
            return network.localizedName
        }

        let names = request.candidateNetworkIDs.compactMap {
            ReceiveNetworkCatalog.network(for: $0)?.localizedName
        }
        if names.count == 1 {
            return names[0]
        }
        if 2...3 ~= names.count {
            return names.joined(separator: ", ")
        }
        return WalletLocalization.string(
            "smart_scanner.review.value.multiple_networks"
        )
    }

    private var assetValue: String {
        if let draft = resolvedDraft {
            return "\(draft.asset.name) (\(draft.asset.symbol))"
        }

        switch request.requestedAsset {
        case .unspecified:
            return WalletLocalization.string(
                "smart_scanner.review.value.choose_next"
            )
        case .native:
            if let networkID = request.requestedNetworkID,
               let network = ReceiveNetworkCatalog.network(
                   for: networkID
               ) {
                return "\(network.localizedName) (\(network.symbol))"
            }
            return WalletLocalization.string(
                "smart_scanner.review.value.native_coin"
            )
        case .contract:
            return WalletLocalization.string(
                "smart_scanner.review.value.token"
            )
        }
    }

    private var amountRow: SmartScannerReviewRow? {
        if let draft = resolvedDraft,
           let amount = draft.amount {
            let hasLocalCurrencyPrice = SendAmountPresentation
                .unitUSDPrice(for: draft.asset) != nil
            return SmartScannerReviewRow(
                id: "amount",
                titleKey: "smart_scanner.review.field.amount",
                value: SendAmountPresentation.formatted(
                    amount: amount,
                    asset: draft.asset,
                    currency: WalletCurrencyContext(
                        code: currencyCode,
                        ratePerUSD: currencyRatePerUSD
                    )
                ),
                valueStyle: hasLocalCurrencyPrice
                    ? .standard : .monospaced
            )
        }

        switch request.requestedAmount {
        case let .userUnits(value):
            return SmartScannerReviewRow(
                id: "amount",
                titleKey: "smart_scanner.review.field.amount",
                value: value,
                valueStyle: .monospaced
            )
        case let .atomicUnits(value):
            return SmartScannerReviewRow(
                id: "amount",
                titleKey:
                    "smart_scanner.review.field.amount_base_units",
                value: value,
                valueStyle: .monospaced
            )
        case nil:
            return nil
        }
    }
}
