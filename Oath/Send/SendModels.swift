import Foundation

enum SendPaymentRequestSource: String, Hashable, Sendable {
    case bareAddress
    case name
    case bitcoinURI
    case bitcoinCashURI
    case litecoinURI
    case dogecoinURI
    case ethereumURI
    case solanaPayURI
    case tronURI
    case tonURI
    case suiURI
    case aptosURI
    case nearURI
    case xrpURI
    case stellarURI
}

enum SendRequestedAsset: Hashable, Sendable {
    case unspecified
    case native
    case contract(String)
}

enum SendRequestedAmount: Hashable, Sendable {
    case userUnits(String)
    case atomicUnits(String)
}

struct SendPaymentRequest: Hashable, Sendable {
    let source: SendPaymentRequestSource
    let recipient: String
    let candidateNetworkIDs: [String]
    let requestedNetworkID: String?
    let requestedAsset: SendRequestedAsset
    let requestedAmount: SendRequestedAmount?
    let label: String?
    let message: String?
    let memo: String?
    let references: [String]

    var hasRequestedAmount: Bool {
        requestedAmount != nil
    }

    static func manualEntry(networkID: String) -> SendPaymentRequest {
        SendPaymentRequest(
            source: .bareAddress,
            recipient: "",
            candidateNetworkIDs: [networkID],
            requestedNetworkID: networkID,
            requestedAsset: .unspecified,
            requestedAmount: nil,
            label: nil,
            message: nil,
            memo: nil,
            references: []
        )
    }

    func replacingMemo(_ memo: String?) -> SendPaymentRequest {
        SendPaymentRequest(
            source: source,
            recipient: recipient,
            candidateNetworkIDs: candidateNetworkIDs,
            requestedNetworkID: requestedNetworkID,
            requestedAsset: requestedAsset,
            requestedAmount: requestedAmount,
            label: label,
            message: message,
            memo: memo,
            references: references
        )
    }
}

enum SendPaymentRequestError: Error, Equatable, Sendable {
    case emptyPayload
    case payloadTooLarge
    case unsupportedFormat
    case unsupportedScheme
    case unsupportedInteractiveRequest
    case missingRecipient
    case invalidMainnetAddress
    case invalidContractAddress
    case unsupportedNetwork
    case invalidAmount
    case amountTooLarge
    case duplicateParameter
    case unsupportedRequiredParameter
    case unsupportedParameter
    case unsupportedContractFunction
    case invalidReference

    var localizedMessage: String {
        WalletLocalization.string(localizationKey)
    }

    private var localizationKey: String {
        switch self {
        case .emptyPayload:
            "send.error.empty_payload"
        case .payloadTooLarge:
            "send.error.payload_too_large"
        case .unsupportedFormat:
            "send.error.unsupported_format"
        case .unsupportedScheme:
            "send.error.unsupported_scheme"
        case .unsupportedInteractiveRequest:
            "send.error.unsupported_interactive_request"
        case .missingRecipient:
            "send.error.missing_recipient"
        case .invalidMainnetAddress:
            "send.error.invalid_mainnet_address"
        case .invalidContractAddress:
            "send.error.invalid_contract_address"
        case .unsupportedNetwork:
            "send.error.unsupported_network"
        case .invalidAmount:
            "send.error.invalid_amount"
        case .amountTooLarge:
            "send.error.amount_too_large"
        case .duplicateParameter:
            "send.error.duplicate_parameter"
        case .unsupportedRequiredParameter:
            "send.error.unsupported_required_parameter"
        case .unsupportedParameter:
            "send.error.unsupported_parameter"
        case .unsupportedContractFunction:
            "send.error.unsupported_contract_function"
        case .invalidReference:
            "send.error.invalid_reference"
        }
    }
}

struct SendAssetChoice: Hashable, Sendable, Identifiable {
    let id: String
    let name: String
    let symbol: String
    let networkID: String
    let networkName: String
    let blockchain: WalletBlockchain
    let contractAddress: String?
    let decimals: Int
    let logoSource: AssetLogoSource
    let networkLogoSource: AssetLogoSource
    let balance: Decimal
    let fiatValue: Decimal
    let balanceAtomic: String?
    let sourceAddress: String?
    let isVerified: Bool

    /// The curated family of this asset in the installed catalog, if any.
    var family: AssetFamily? {
        ReceiveAssetCatalog.family(forAssetIdentity: id)
    }

    var familyLogoSource: AssetLogoSource? {
        family?.logoSource
    }

    var isNative: Bool {
        contractAddress == nil
    }

    init(
        id: String,
        name: String,
        symbol: String,
        networkID: String,
        networkName: String,
        blockchain: WalletBlockchain,
        contractAddress: String?,
        decimals: Int,
        logoSource: AssetLogoSource,
        networkLogoSource: AssetLogoSource,
        balance: Decimal,
        fiatValue: Decimal,
        balanceAtomic: String? = nil,
        sourceAddress: String? = nil,
        isVerified: Bool = true
    ) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.networkID = networkID
        self.networkName = networkName
        self.blockchain = blockchain
        self.contractAddress = contractAddress
        self.decimals = decimals
        self.logoSource = logoSource
        self.networkLogoSource = networkLogoSource
        self.balance = balance
        self.fiatValue = fiatValue
        self.balanceAtomic = balanceAtomic
        self.sourceAddress = sourceAddress
        self.isVerified = isVerified
    }
}

enum SendAmountValidationIssue: Hashable, Sendable {
    case required
    case invalid
    case zero
    case precision(Int)
    case exceedsBalance
    case localCurrencyUnavailable

    var localizedMessage: String {
        switch self {
        case .required:
            WalletLocalization.string("send.amount.error.required")
        case .invalid:
            WalletLocalization.string("send.amount.error.invalid")
        case .zero:
            WalletLocalization.string("send.amount.error.zero")
        case let .precision(decimals):
            EnglishNumbers.localized(
                "send.amount.error.precision",
                decimals
            )
        case .exceedsBalance:
            WalletLocalization.string(
                "send.amount.error.exceeds_balance"
            )
        case .localCurrencyUnavailable:
            WalletLocalization.string(
                "send.amount.error.local_currency_unavailable"
            )
        }
    }
}

enum SendRecipientValidationIssue: Hashable, Sendable {
    case required
    case invalidForNetwork
    case selfTransferNotSupported
    case name(SendRecipientNameError)

    var localizedMessage: String {
        switch self {
        case .required:
            WalletLocalization.string("send.recipient.error.required")
        case .invalidForNetwork:
            WalletLocalization.string(
                "send.recipient.error.invalid_network"
            )
        case let .name(error):
            error.localizedMessage
        case .selfTransferNotSupported:
            WalletLocalization.string("send.recipient.error.self_transfer")
        }
    }
}

struct SendDraft: Hashable, Sendable {
    let request: SendPaymentRequest
    let asset: SendAssetChoice
    let recipient: String
    let amount: String?
    let note: String?
    let feePolicy: SendNetworkFeePolicy
    let preparedNetworkFee: SendResolvedNetworkFee?
    let bitcoinFamilyOptions: SendBitcoinFamilyOptions
    let usesMaximumBalance: Bool

    init(
        request: SendPaymentRequest,
        asset: SendAssetChoice,
        recipient: String,
        amount: String?,
        note: String?,
        feePolicy: SendNetworkFeePolicy = .fastest,
        preparedNetworkFee: SendResolvedNetworkFee? = nil,
        bitcoinFamilyOptions: SendBitcoinFamilyOptions = .automatic,
        usesMaximumBalance: Bool = false
    ) {
        self.request = request
        self.asset = asset
        self.recipient = recipient
        self.amount = amount
        self.note = note
        self.feePolicy = feePolicy
        self.preparedNetworkFee = preparedNetworkFee
        self.bitcoinFamilyOptions = bitcoinFamilyOptions
        self.usesMaximumBalance = usesMaximumBalance
    }

    func replacing(
        recipient: String,
        amount: String,
        note: String?
    ) -> SendDraft {
        SendDraft(
            request: request,
            asset: asset,
            recipient: recipient,
            amount: amount,
            note: WalletTransactionNote.normalized(note),
            feePolicy: feePolicy,
            preparedNetworkFee: preparedNetworkFee,
            bitcoinFamilyOptions: bitcoinFamilyOptions,
            usesMaximumBalance: usesMaximumBalance
        )
    }

    func replacingNote(_ note: String?) -> SendDraft {
        SendDraft(
            request: request,
            asset: asset,
            recipient: recipient,
            amount: amount,
            note: WalletTransactionNote.normalized(note),
            feePolicy: feePolicy,
            preparedNetworkFee: preparedNetworkFee,
            bitcoinFamilyOptions: bitcoinFamilyOptions,
            usesMaximumBalance: usesMaximumBalance
        )
    }

    func replacingFeePolicy(
        _ feePolicy: SendNetworkFeePolicy
    ) -> SendDraft {
        SendDraft(
            request: request,
            asset: asset,
            recipient: recipient,
            amount: amount,
            note: note,
            feePolicy: feePolicy,
            preparedNetworkFee: nil,
            bitcoinFamilyOptions: bitcoinFamilyOptions,
            usesMaximumBalance: usesMaximumBalance
        )
    }

    func replacingPreparedNetworkFee(
        _ preparedNetworkFee: SendResolvedNetworkFee?
    ) -> SendDraft {
        SendDraft(
            request: request,
            asset: asset,
            recipient: recipient,
            amount: amount,
            note: note,
            feePolicy: feePolicy,
            preparedNetworkFee: preparedNetworkFee,
            bitcoinFamilyOptions: bitcoinFamilyOptions,
            usesMaximumBalance: usesMaximumBalance
        )
    }

    func replacingBitcoinFamilyOptions(
        _ bitcoinFamilyOptions: SendBitcoinFamilyOptions
    ) -> SendDraft {
        SendDraft(
            request: request,
            asset: asset,
            recipient: recipient,
            amount: amount,
            note: note,
            feePolicy: feePolicy,
            preparedNetworkFee: preparedNetworkFee,
            bitcoinFamilyOptions: bitcoinFamilyOptions,
            usesMaximumBalance: usesMaximumBalance
        )
    }

    func replacingMaximumBalance(
        _ usesMaximumBalance: Bool
    ) -> SendDraft {
        SendDraft(
            request: request,
            asset: asset,
            recipient: recipient,
            amount: amount,
            note: note,
            feePolicy: feePolicy,
            preparedNetworkFee: preparedNetworkFee,
            bitcoinFamilyOptions: bitcoinFamilyOptions,
            usesMaximumBalance: usesMaximumBalance
        )
    }
}

enum SendFlowRoute: Hashable {
    case textAddressEntry
    case assetSelection(SendPaymentRequest)
    case recipient(
        SendDraft,
        SendDraftValidationFailure?
    )
    case amount(
        SendDraft,
        SendDraftValidationFailure?
    )
    case review(SendDraft)
}

enum SendScanPreparation {
    case ready(SendFlowRoute)
    case failed(String)
}

enum SendFlowPlanningError: Error, Equatable, Sendable {
    case unsupportedByWallet
    case requestedAssetUnavailable
    case invalidRecipientForSelection

    var localizedMessage: String {
        switch self {
        case .unsupportedByWallet:
            WalletLocalization.string(
                "send.error.network_not_available_in_wallet"
            )
        case .requestedAssetUnavailable:
            WalletLocalization.string(
                "send.error.asset_not_available"
            )
        case .invalidRecipientForSelection:
            WalletLocalization.string(
                "send.recipient.error.invalid_network"
            )
        }
    }
}
