import Foundation

enum WalletActionPreparationSource: Equatable, Sendable {
    case loading
    case content
}

struct WalletHomePortfolioPreparation: Sendable {
    let allAssets: [WalletAsset]
    let transactions: [WalletTransaction]
    let visibleHomeAssets: [WalletAsset]
    let searchAssets: [WalletAsset]
    let searchTransactions: [WalletTransaction]
}

struct WalletAssetListPreparation: Sendable {
    let assets: [WalletAsset]
    let transactions: [WalletTransaction]
    let browseIndex: WalletAssetDiscoveryIndex
    let manageIndex: WalletAssetDiscoveryIndex
    let networkSelectionOrdering: WalletNetworkSelectionOrdering
    let initialNetworkID: String?
    let initialBrowseSections:
        [WalletAssetSelectionCatalog.Section]
    let initialManageGroups: [WalletAssetSelectionGroup]

    static func make(
        assets: [WalletAsset],
        transactions: [WalletTransaction],
        capabilities: WalletCapabilities,
        visibleAssetIDs: Set<String>
    ) async -> WalletAssetListPreparation {
        let browseAssets = assets.filter {
            !$0.isSpam
                && (
                    !$0.requiresExplicitVisibility
                        || visibleAssetIDs.contains(
                            AssetIdentityKey.canonical($0.id)
                        )
                )
        }
        let manageAssets = assets.filter { !$0.isSpam }
        async let indexesTask = makeIndexes(
            browseAssets: browseAssets,
            manageAssets: manageAssets,
            transactions: transactions
        )
        async let orderingTask = makeNetworkOrdering(
            assets: manageAssets,
            transactions: transactions
        )
        let ((browseIndex, manageIndex), ordering) = await (
            indexesTask,
            orderingTask
        )
        let initialNetworkID = capabilities.showsNetworkSelector
            ? nil
            : capabilities.privateKeyNetwork?.networkID
        async let browseSectionsTask = makeBrowseSections(
            index: browseIndex,
            networkID: initialNetworkID
        )
        async let manageGroupsTask = makeManageGroups(
            index: manageIndex,
            networkID: initialNetworkID
        )
        let (browseSections, manageGroups) = await (
            browseSectionsTask,
            manageGroupsTask
        )
        return WalletAssetListPreparation(
            assets: manageAssets,
            transactions: transactions,
            browseIndex: browseIndex,
            manageIndex: manageIndex,
            networkSelectionOrdering: ordering,
            initialNetworkID: initialNetworkID,
            initialBrowseSections: browseSections,
            initialManageGroups: manageGroups
        )
    }

    private static func makeIndexes(
        browseAssets: [WalletAsset],
        manageAssets: [WalletAsset],
        transactions: [WalletTransaction]
    ) async -> (
        browse: WalletAssetDiscoveryIndex,
        manage: WalletAssetDiscoveryIndex
    ) {
        if browseAssets.count == manageAssets.count,
           zip(browseAssets, manageAssets).allSatisfy({
               AssetIdentityKey.canonical($0.id)
                   == AssetIdentityKey.canonical($1.id)
           }) {
            let shared = await makeIndex(
                assets: manageAssets,
                transactions: transactions
            )
            return (shared, shared)
        }

        async let browseIndexTask = makeIndex(
            assets: browseAssets,
            transactions: transactions
        )
        async let manageIndexTask = makeIndex(
            assets: manageAssets,
            transactions: transactions
        )
        return await (
            browseIndexTask,
            manageIndexTask
        )
    }

    private static func makeIndex(
        assets: [WalletAsset],
        transactions: [WalletTransaction]
    ) async -> WalletAssetDiscoveryIndex {
        WalletAssetDiscoveryIndex(
            walletAssets: assets,
            transactions: transactions
        )
    }

    private static func makeNetworkOrdering(
        assets: [WalletAsset],
        transactions: [WalletTransaction]
    ) async -> WalletNetworkSelectionOrdering {
        WalletNetworkSelectionOrdering(
            walletAssets: assets,
            transactions: transactions
        )
    }

    private static func makeBrowseSections(
        index: WalletAssetDiscoveryIndex,
        networkID: String?
    ) async -> [WalletAssetSelectionCatalog.Section] {
        WalletAssetSelectionCatalog.sections(
            fromOrderedAssets: initialAssets(
                index: index,
                networkID: networkID
            )
        )
    }

    private static func makeManageGroups(
        index: WalletAssetDiscoveryIndex,
        networkID: String?
    ) async -> [WalletAssetSelectionGroup] {
        WalletAssetSelectionCatalog.groups(
            fromOrderedAssets: initialAssets(
                index: index,
                networkID: networkID
            )
        )
    }

    private static func initialAssets(
        index: WalletAssetDiscoveryIndex,
        networkID: String?
    ) -> [WalletAsset] {
        let limit = networkID == nil
            ? ReceiveAssetSearchIndex.maximumVisibleResults
            : ReceiveAssetCatalog.defaultVisibleTokenLimit + 1
        return Array(
            index.assets(networkID: networkID, searchText: "")
                .prefix(limit)
        )
    }
}

enum WalletHomeUsagePolicy {
    static func isUsed(
        totalBalance: Decimal,
        hasStoredActivity: Bool
    ) -> Bool {
        totalBalance > 0 || hasStoredActivity
    }
}

struct WalletActionPresentationPreparation: Sendable {
    let requestID: UUID
    let identity: PersistedWalletIdentity
    let capabilities: WalletCapabilities
    let source: WalletActionPreparationSource
    let visibilityPreferencesJSON: String
    let stateRevision: UUID
    let home: WalletHomePortfolioPreparation
    let assetLists: WalletAssetListPreparation
    let flowAssets: [WalletAsset]
    let transactions: [WalletTransaction]
    let receive: ReceiveAssetSelectionPreparation
    let send: SendInitialAssetSelectionPreparation
    let directSingleCoinAsset: WalletAsset?
    let bitcoinFamilyAsset: WalletAsset?

    func matches(
        presentation: AppRootWalletPresentation,
        visibilityPreferencesJSON: String
    ) -> Bool {
        requestID == presentation.requestID
            && identity == presentation.identity
            && capabilities == presentation.capabilities
            && source == presentation.walletActionPreparationInput?.source
            && stateRevision == presentation.stateRevision
            && self.visibilityPreferencesJSON
                == visibilityPreferencesJSON
    }

    func matchesHomeDisplay(
        presentation: AppRootWalletPresentation,
        visibilityPreferencesJSON: String
    ) -> Bool {
        requestID == presentation.requestID
            && identity == presentation.identity
            && capabilities == presentation.capabilities
            && source == presentation.walletActionPreparationInput?.source
            && self.visibilityPreferencesJSON
                == visibilityPreferencesJSON
    }

    func matchesActionPresentation(
        presentation: AppRootWalletPresentation,
        visibilityPreferencesJSON: String
    ) -> Bool {
        requestID == presentation.requestID
            && identity == presentation.identity
            && capabilities == presentation.capabilities
            && source == presentation.walletActionPreparationInput?.source
            && stateRevision == presentation.stateRevision
            && self.visibilityPreferencesJSON
                == visibilityPreferencesJSON
    }

    func matchesStableActionPresentation(
        presentation: AppRootWalletPresentation,
        visibilityPreferencesJSON: String
    ) -> Bool {
        requestID == presentation.requestID
            && identity == presentation.identity
            && capabilities == presentation.capabilities
            && source == presentation.walletActionPreparationInput?.source
            && self.visibilityPreferencesJSON
                == visibilityPreferencesJSON
    }
}

struct WalletActionCPUPreparation: Sendable {
    let home: WalletHomePortfolioPreparation
    let assetLists: WalletAssetListPreparation
    let flowAssets: [WalletAsset]
    let transactions: [WalletTransaction]
    let receive: ReceiveAssetSelectionPreparation
    let send: SendInitialAssetSelectionPreparation
    let directSingleCoinAsset: WalletAsset?
}

enum WalletActionPresentationPreparationBuilder {
    static func make(
        snapshot: WalletHomeSnapshot,
        capabilities: WalletCapabilities,
        walletAddress: String,
        visibilityPreferencesJSON: String,
        accountAddresses: WalletAccountAddressIndex = .empty,
        eligibleSolanaTokenMints: Set<String> = [],
        stateRevision: UUID? = nil
    ) async -> WalletActionCPUPreparation {
        let searchAssets = WalletHomeAssetCatalog.availableAssets(
            from: snapshot.assets,
            accountAddresses: accountAddresses
        )
        let homeAssets = capabilities.filteredAssets(searchAssets)
        let homeTransactions = capabilities.filteredTransactions(
            snapshot.transactions
        )
        async let visibleHomeAssetsTask: [WalletAsset] = {
            let result = await makeVisibleHomeAssets(
                assets: homeAssets,
                transactions: homeTransactions,
                walletAddress: walletAddress,
                visibilityPreferencesJSON: visibilityPreferencesJSON
            )
            return result
        }()
        async let receiveTask: ReceiveAssetSelectionPreparation = {
            let result = await ReceiveAssetSelectionPreparation.makeIndexed(
                walletAssets:
                    WalletHomeAssetVisibility
                    .assetsAvailableOutsideManagement(
                        from: homeAssets,
                        walletAddress: walletAddress,
                        preferencesJSON:
                            visibilityPreferencesJSON
                    ),
                transactions: homeTransactions,
                capabilities: capabilities,
                accountAddresses: accountAddresses,
                eligibleSolanaTokenMints: eligibleSolanaTokenMints
            )
            return result
        }()
        let visibleHomeAssets = await visibleHomeAssetsTask
        let visibleAssetIDs = Set(
            visibleHomeAssets.map {
                AssetIdentityKey.canonical($0.id)
            }
        )
        async let assetListsTask: WalletAssetListPreparation = {
            let result = await WalletAssetListPreparation.make(
                assets: homeAssets,
                transactions: homeTransactions,
                capabilities: capabilities,
                visibleAssetIDs: visibleAssetIDs
            )
            return result
        }()
        let home = WalletHomePortfolioPreparation(
            allAssets: homeAssets,
            transactions: homeTransactions,
            visibleHomeAssets: visibleHomeAssets,
            searchAssets: searchAssets,
            searchTransactions: snapshot.transactions
        )
        let receive = await receiveTask
        if let stateRevision {
            _ = receive.projection(revision: stateRevision, balanceAssets: snapshot.assets)
        }
        let flowAssets = receive.walletAssets
        let send = SendInitialAssetSelectionPreparation(
            matching: receive
        )
        let directAsset: WalletAsset?
        if let network = capabilities.privateKeyNetwork,
           !network.supportsMultipleAssets {
            directAsset = homeAssets
                .filter { $0.network == network.blockchain }
                .max { lhs, rhs in lhs.fiatValue < rhs.fiatValue }
        } else {
            directAsset = nil
        }

        return WalletActionCPUPreparation(
            home: home,
            assetLists: await assetListsTask,
            flowAssets: flowAssets,
            transactions: homeTransactions,
            receive: receive,
            send: send,
            directSingleCoinAsset: directAsset
        )
    }

    private static func makeVisibleHomeAssets(
        assets: [WalletAsset],
        transactions: [WalletTransaction],
        walletAddress: String,
        visibilityPreferencesJSON: String
    ) async -> [WalletAsset] {
        WalletHomeAssetVisibility.homeAssets(
            from: assets,
            transactions: transactions,
            walletAddress: walletAddress,
            preferencesJSON: visibilityPreferencesJSON
        )
    }
}

actor WalletActionCatalogPrewarmer {
    static let shared = WalletActionCatalogPrewarmer()

    private var preparation:
        (generation: UInt64, task: Task<Void, Never>)?

    func prepare() async {
        let generation = ReceiveAssetCatalogRuntime.snapshot.generation
        if let preparation, preparation.generation == generation {
            await preparation.task.value
            return
        }
        let task = Task.detached(priority: .userInitiated) {
            ReceiveAssetSearchIndex.prepare()
            _ = ReceiveAssetCatalog.walletAssets
        }
        preparation = (generation, task)
        await task.value
    }
}

enum WalletTransactionRepeatFailure:
    Error,
    Hashable,
    Identifiable,
    Sendable {
    case notOutgoing
    case missingTransactionDetails
    case assetUnavailable
    case insufficientBalance
    case insufficientNetworkFeeBalance
    case preflightFailed(message: String)
    case presentationUnavailable

    var id: String { diagnosticReason }

    var localizedTitle: String {
        switch self {
        case .insufficientBalance, .insufficientNetworkFeeBalance:
            WalletLocalization.string(
                "wallet.transaction.details.repeat.insufficient.title"
            )
        case .notOutgoing, .missingTransactionDetails,
             .assetUnavailable, .presentationUnavailable, .preflightFailed:
            WalletLocalization.string(
                "wallet.transaction.details.repeat.unavailable.title"
            )
        }
    }

    var localizedMessage: String {
        switch self {
        case .notOutgoing, .missingTransactionDetails:
            WalletLocalization.string(
                "wallet.transaction.details.repeat.unavailable.message"
            )
        case .assetUnavailable:
            WalletLocalization.string(
                "wallet.transaction.details.repeat.asset_unavailable.message"
            )
        case .insufficientBalance:
            WalletLocalization.string(
                "wallet.transaction.details.repeat.insufficient.message"
            )
        case .insufficientNetworkFeeBalance:
            SendTransactionSubmissionError.insufficientNetworkFeeBalance.localizedMessage
        case let .preflightFailed(message):
            message
        case .presentationUnavailable:
            WalletLocalization.string(
                "wallet.transaction.details.repeat.presentation_unavailable.message"
            )
        }
    }

    var diagnosticReason: String {
        switch self {
        case .notOutgoing:
            "repeat_not_outgoing"
        case .missingTransactionDetails:
            "repeat_missing_transaction_details"
        case .assetUnavailable:
            "repeat_asset_unavailable"
        case .insufficientBalance:
            "repeat_insufficient_balance"
        case .insufficientNetworkFeeBalance:
            "repeat_insufficient_network_fee_balance"
        case .preflightFailed:
            "repeat_preflight_failed"
        case .presentationUnavailable:
            "repeat_presentation_unavailable"
        }
    }
}

struct WalletTransactionRepeatPlan: Hashable, Sendable {
    let draft: SendDraft
    let walletAsset: WalletAsset

    var initialRoute: SendFlowRoute {
        if let issue = SendFlowPlanner.recipientIssue(draft.recipient, asset: draft.asset) {
            return .recipient(draft, .init(recipientIssue: issue, amountIssue: nil))
        }
        return .review(draft)
    }
}

enum WalletTransactionRepeatPreparation {
    static func isEligible(_ transaction: WalletTransaction) -> Bool {
        switch transaction.kind {
        case .sent, .selfTransfer:
            true
        case .received, .swapped:
            false
        }
    }

    static func prepare(
        transaction: WalletTransaction,
        walletAssets: [WalletAsset],
        capabilities: WalletCapabilities
    ) -> Result<WalletTransactionRepeatPlan, WalletTransactionRepeatFailure> {
        guard isEligible(transaction) else {
            return .failure(.notOutgoing)
        }
        guard
            let networkID = WalletNetworkSelectionOrdering
                .canonicalNetworkID(
                    transaction.metadata.blockchainIdentifier
                ),
            let blockchain = AssetNetworkSelectorOption.blockchain(
                for: networkID
            )
        else {
            return .failure(.missingTransactionDetails)
        }

        let contractAddress = normalizedContractAddress(
            transaction.metadata.contractAddress
                ?? transaction.assetLogoSource
                    .checksummedContractAddress,
            networkID: networkID
        )
        guard let recipient = repeatRecipient(
            recordedRecipient: transaction.metadata.toAddress,
            contractAddress: contractAddress,
            inputData: transaction.metadata.inputData,
            blockchain: blockchain
        ) else {
            return .failure(.missingTransactionDetails)
        }
        let identity = AssetIdentityKey.make(
            networkID: networkID,
            contractAddress: contractAddress
        )
        let choices = SendAssetChoiceCatalog.choices(
            from: walletAssets,
            capabilities: capabilities
        )
        guard
            let choice = choices.first(where: {
                AssetIdentityKey.canonical($0.id) == identity
            }),
            let walletAsset = walletAssets.first(where: {
                AssetIdentityKey.canonical($0.id)
                    == AssetIdentityKey.canonical(choice.id)
            })
        else {
            return .failure(.assetUnavailable)
        }
        if contractAddress != nil,
           let recordedDecimals = transaction.metadata.tokenDecimals,
           recordedDecimals != choice.decimals {
            return .failure(.missingTransactionDetails)
        }
        guard let amountAtomic = exactAmountAtomic(
            transaction,
            decimals: choice.decimals
        ) else {
            return .failure(.missingTransactionDetails)
        }

        let amount = SendDecimalAmount.userUnits(
            fromAtomicUnits: amountAtomic,
            decimals: choice.decimals
        )
        // Check funds before routing an unsupported self-transfer back to
        // Recipient; that recovery route must not bypass the balance check.
        if SendFlowPlanner.amountIssue(amount, asset: choice) == .exceedsBalance {
            return .failure(.insufficientBalance)
        }
        var request = SendPaymentRequest.manualEntry(networkID: networkID)
        if networkID == XRPConstants.networkID
            || networkID == StellarConstants.networkID {
            request = request.replacingMemo(
                transaction.metadata.inputData
            )
        }
        let draft = SendDraft(
            request: request,
            asset: choice,
            recipient: recipient,
            amount: amount,
            note: nil,
            usesMaximumBalance: false
        )
        switch SendFlowPlanner.reviewDraft(
            from: draft,
            recipient: recipient,
            amount: amount,
            note: nil
        ) {
        case let .success(reviewedDraft):
            return .success(
                WalletTransactionRepeatPlan(
                    draft: reviewedDraft,
                    walletAsset: walletAsset
                )
            )
        case let .failure(failure):
            if failure.recipientIssue == .selfTransferNotSupported {
                // Keep the exact amount and routing metadata, but let the
                // Recipient screen explain and correct this invalid target.
                return .success(.init(draft: draft, walletAsset: walletAsset))
            }
            if failure.amountIssue == .exceedsBalance {
                return .failure(.insufficientBalance)
            }
            return .failure(.missingTransactionDetails)
        }
    }

    private static func normalizedRecipient(_ value: String?) -> String? {
        guard let value else { return nil }
        let recipient = value.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        return recipient.isEmpty ? nil : recipient
    }

    private static func repeatRecipient(
        recordedRecipient: String?,
        contractAddress: String?,
        inputData: String?,
        blockchain: WalletBlockchain
    ) -> String? {
        let recordedRecipient = normalizedRecipient(recordedRecipient)
        guard blockchain.isEVM, let contractAddress else {
            return recordedRecipient
        }
        guard recordedRecipient == nil
            || recordedRecipient?.caseInsensitiveCompare(contractAddress)
                == .orderedSame
        else {
            return recordedRecipient
        }
        guard
            let decodedRecipient = evmTokenTransferRecipient(
                from: inputData
            ),
            decodedRecipient.caseInsensitiveCompare(contractAddress)
                != .orderedSame
        else {
            return nil
        }
        return decodedRecipient
    }

    private static func evmTokenTransferRecipient(
        from inputData: String?
    ) -> String? {
        guard let inputData else { return nil }
        let trimmed = inputData.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let payload = trimmed.lowercased().hasPrefix("0x")
            ? String(trimmed.dropFirst(2)).lowercased()
            : trimmed.lowercased()
        guard payload.allSatisfy(\.isHexDigit), payload.count >= 72 else {
            return nil
        }

        let selector = String(payload.prefix(8))
        let recipientWordOffset: Int
        switch selector {
        case "a9059cbb":
            recipientWordOffset = 8
        case "23b872dd":
            recipientWordOffset = 72
        default:
            return nil
        }
        guard payload.count >= recipientWordOffset + 64 else {
            return nil
        }
        let wordStart = payload.index(
            payload.startIndex,
            offsetBy: recipientWordOffset
        )
        let wordEnd = payload.index(wordStart, offsetBy: 64)
        let addressWord = payload[wordStart..<wordEnd]
        guard
            addressWord.prefix(24).allSatisfy({ $0 == "0" }),
            addressWord.suffix(40).contains(where: { $0 != "0" })
        else {
            return nil
        }
        return "0x\(addressWord.suffix(40))"
    }

    private static func normalizedContractAddress(
        _ value: String?,
        networkID: String
    ) -> String? {
        guard let value else { return nil }
        let contractAddress = value.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !contractAddress.isEmpty else { return nil }
        if AssetNetworkSelectorOption.blockchain(for: networkID)?.isEVM
            == true,
           contractAddress.caseInsensitiveCompare(
               "0x0000000000000000000000000000000000000000"
           ) == .orderedSame {
            return nil
        }
        return contractAddress
    }

    private static func exactAmountAtomic(
        _ transaction: WalletTransaction,
        decimals: Int
    ) -> String? {
        if let amountAtomic = transaction.assetAmountAtomic,
           SendAtomicAmount.isCanonical(amountAtomic),
           amountAtomic != "0" {
            return amountAtomic
        }
        guard
            let amountText = transaction.assetAmountText,
            let magnitude = ExactDecimalText.canonicalMagnitude(amountText),
            magnitude != "0"
        else {
            return nil
        }
        return try? SendAtomicAmount.fromUserUnits(
            magnitude,
            decimals: decimals
        )
    }
}
