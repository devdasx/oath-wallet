import CryptoKit
import Foundation

enum SendTransactionAuthorizationError: Error, Hashable, Sendable {
    case expired
    case alreadyConsumed
    case bindingMismatch
    case invalidDraft
}

struct SendTransactionAuthorizationIssuer: Sendable {
    let database: WalletDatabase

    func issue(
        reviewedDraft: SendDraft,
        walletID: String,
        authenticationGrant: WalletAuthenticationGrant
    ) async throws -> SendTransactionAuthorization {
        let secretAuthorization = try await database
            .authorizeSecretExport(
                walletID: walletID,
                authenticationGrant: authenticationGrant
            )
        return try await SendTransactionAuthorization.issue(
            reviewedDraft: reviewedDraft,
            secretAuthorization: secretAuthorization,
            database: database
        )
    }

    func issueWithoutProtection(
        reviewedDraft: SendDraft,
        walletID: String
    ) async throws -> SendTransactionAuthorization {
        let secretAuthorization = try await database
            .authorizeUnprotectedSecretExport(walletID: walletID)
        return try await SendTransactionAuthorization.issue(
            reviewedDraft: reviewedDraft,
            secretAuthorization: secretAuthorization,
            database: database
        )
    }
}

struct SendTransactionAuthorization: Hashable, Sendable {
    private static let validityDuration: TimeInterval = 30

    private let grantID: UUID
    private let authority: SendTransactionAuthorizationAuthority

    private init(
        grantID: UUID,
        authority: SendTransactionAuthorizationAuthority
    ) {
        self.grantID = grantID
        self.authority = authority
    }

    static func issue(
        reviewedDraft: SendDraft,
        secretAuthorization: WalletSecretExportAuthorization,
        database: WalletDatabase,
        dataStore: WalletDataStore? = nil
    ) async throws -> SendTransactionAuthorization {
        guard let identity = try await database.selectedWalletIdentity()
        else {
            throw SendTransactionSubmissionError.walletUnavailable
        }
        guard secretAuthorization.permits(
            walletID: identity.walletID
        ) else {
            throw SendTransactionSubmissionError.authorizationExpired
        }

        let store = dataStore ?? WalletDataStore(database: database)
        let accounts = try await store.accounts(
            walletID: identity.walletID
        )
        guard let account = try await SendSigningAccountSelector
            .matchingOwnedAccount(
                in: accounts,
                draft: reviewedDraft,
                walletID: identity.walletID,
                database: database
            ) else {
            throw SendTransactionSubmissionError.accountUnavailable
        }
        guard !account.isWatchOnly else {
            throw SendTransactionSubmissionError.watchOnlyAccount
        }

        let digest: Data
        do {
            digest = try SendReviewedDraftDigest.make(
                reviewedDraft
            )
        } catch {
            throw SendTransactionAuthorizationError.invalidDraft
        }

        let grantID = UUID()
        let authority = SendTransactionAuthorizationAuthority(
            grantID: grantID,
            walletID: identity.walletID,
            accountID: account.id,
            networkID: reviewedDraft.asset.networkID,
            reviewedDraftDigest: digest,
            expiresAt: Date().addingTimeInterval(validityDuration),
            secretAuthorization: secretAuthorization
        )
        return SendTransactionAuthorization(
            grantID: grantID,
            authority: authority
        )
    }

    func consume(
        reviewedDraft: SendDraft,
        walletID: String,
        accountID: String,
        networkID: String
    ) async throws -> WalletSecretExportAuthorization {
        let digest: Data
        do {
            digest = try SendReviewedDraftDigest.make(
                reviewedDraft
            )
        } catch {
            try await authority.invalidate(grantID: grantID)
            throw SendTransactionAuthorizationError.invalidDraft
        }
        return try await authority.consume(
            grantID: grantID,
            walletID: walletID,
            accountID: accountID,
            networkID: networkID,
            reviewedDraftDigest: digest
        )
    }

    static func == (
        lhs: SendTransactionAuthorization,
        rhs: SendTransactionAuthorization
    ) -> Bool {
        lhs.grantID == rhs.grantID
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(grantID)
    }
}

private actor SendTransactionAuthorizationAuthority {
    private enum State {
        case issued
        case consumed
    }

    private let grantID: UUID
    private let walletID: String
    private let accountID: String
    private let networkID: String
    private let reviewedDraftDigest: Data
    private let expiresAt: Date
    private let secretAuthorization: WalletSecretExportAuthorization
    private var state = State.issued

    init(
        grantID: UUID,
        walletID: String,
        accountID: String,
        networkID: String,
        reviewedDraftDigest: Data,
        expiresAt: Date,
        secretAuthorization: WalletSecretExportAuthorization
    ) {
        self.grantID = grantID
        self.walletID = walletID
        self.accountID = accountID
        self.networkID = networkID
        self.reviewedDraftDigest = reviewedDraftDigest
        self.expiresAt = expiresAt
        self.secretAuthorization = secretAuthorization
    }

    func consume(
        grantID candidateGrantID: UUID,
        walletID candidateWalletID: String,
        accountID candidateAccountID: String,
        networkID candidateNetworkID: String,
        reviewedDraftDigest candidateDigest: Data
    ) throws -> WalletSecretExportAuthorization {
        guard state == .issued else {
            throw SendTransactionAuthorizationError.alreadyConsumed
        }

        // Every consumption attempt is terminal. A failed binding check cannot
        // be used as an oracle and cannot leave a reusable signing capability.
        state = .consumed

        guard Date() <= expiresAt,
              secretAuthorization.permits(walletID: walletID)
        else {
            throw SendTransactionAuthorizationError.expired
        }
        guard candidateGrantID == grantID,
              candidateWalletID == walletID,
              candidateAccountID == accountID,
              candidateNetworkID == networkID,
              candidateDigest == reviewedDraftDigest
        else {
            throw SendTransactionAuthorizationError.bindingMismatch
        }
        return secretAuthorization
    }

    func invalidate(grantID candidateGrantID: UUID) throws {
        guard state == .issued else {
            throw SendTransactionAuthorizationError.alreadyConsumed
        }
        state = .consumed
        guard candidateGrantID == grantID else {
            throw SendTransactionAuthorizationError.bindingMismatch
        }
    }
}

enum SendReviewedDraftDigest {
    private static let formatVersion = 5

    static func make(_ draft: SendDraft) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let encoded = try encoder.encode(
            CanonicalDraft(draft: draft)
        )
        return Data(SHA256.hash(data: encoded))
    }

    private struct CanonicalDraft: Encodable {
        let formatVersion: Int
        let request: CanonicalRequest
        let asset: CanonicalAsset
        let recipient: String
        let amount: String?
        let note: String?
        let feePolicy: CanonicalFeePolicy
        let preparedNetworkFee: CanonicalPreparedNetworkFee?
        let bitcoinFamilyOptions: CanonicalBitcoinFamilyOptions
        let usesMaximumBalance: Bool

        init(draft: SendDraft) {
            formatVersion = SendReviewedDraftDigest.formatVersion
            request = CanonicalRequest(request: draft.request)
            asset = CanonicalAsset(asset: draft.asset)
            recipient = draft.recipient
            amount = draft.amount
            note = draft.note
            feePolicy = CanonicalFeePolicy(policy: draft.feePolicy)
            preparedNetworkFee = draft.preparedNetworkFee.map(
                CanonicalPreparedNetworkFee.init
            )
            bitcoinFamilyOptions = CanonicalBitcoinFamilyOptions(
                options: draft.bitcoinFamilyOptions
            )
            usesMaximumBalance = draft.usesMaximumBalance
        }
    }

    private struct CanonicalRequest: Encodable {
        let source: String
        let recipient: String
        let candidateNetworkIDs: [String]
        let requestedNetworkID: String?
        let requestedAssetKind: String
        let requestedContract: String?
        let requestedAmountKind: String?
        let requestedAmount: String?
        let label: String?
        let message: String?
        let memo: String?
        let references: [String]

        init(request: SendPaymentRequest) {
            source = request.source.rawValue
            recipient = request.recipient
            candidateNetworkIDs = request.candidateNetworkIDs
            requestedNetworkID = request.requestedNetworkID
            switch request.requestedAsset {
            case .unspecified:
                requestedAssetKind = "unspecified"
                requestedContract = nil
            case .native:
                requestedAssetKind = "native"
                requestedContract = nil
            case let .contract(contract):
                requestedAssetKind = "contract"
                requestedContract = contract
            }
            switch request.requestedAmount {
            case .none:
                requestedAmountKind = nil
                requestedAmount = nil
            case let .userUnits(value):
                requestedAmountKind = "user_units"
                requestedAmount = value
            case let .atomicUnits(value):
                requestedAmountKind = "atomic_units"
                requestedAmount = value
            }
            label = request.label
            message = request.message
            memo = request.memo
            references = request.references
        }
    }

    private struct CanonicalAsset: Encodable {
        let id: String
        let name: String
        let symbol: String
        let networkID: String
        let networkName: String
        let blockchain: String
        let contractAddress: String?
        let decimals: Int
        let balance: String
        let fiatValue: String
        let balanceAtomic: String?
        let sourceAddress: String?

        init(asset: SendAssetChoice) {
            id = asset.id
            name = asset.name
            symbol = asset.symbol
            networkID = asset.networkID
            networkName = asset.networkName
            blockchain = asset.blockchain.rawValue
            contractAddress = asset.contractAddress
            decimals = asset.decimals
            balance = Self.decimalText(asset.balance)
            fiatValue = Self.decimalText(asset.fiatValue)
            balanceAtomic = asset.balanceAtomic
            sourceAddress = asset.sourceAddress
        }

        private static func decimalText(_ value: Decimal) -> String {
            var mutableValue = value
            return NSDecimalString(
                &mutableValue,
                Locale(identifier: "en_US_POSIX") as NSLocale
            )
        }
    }

    private struct CanonicalFeePolicy: Encodable {
        let preset: String
        let customModel: String?
        let customPrimaryValue: String?
        let customSecondaryValue: String?
        let customTotalBudgetAtomic: String?

        init(policy: SendNetworkFeePolicy) {
            preset = policy.preset.rawValue
            customModel = policy.customValue?.model.rawValue
            customPrimaryValue = policy.customValue?.primaryValue
            customSecondaryValue = policy.customValue?.secondaryValue
            customTotalBudgetAtomic = policy.customValue?
                .totalBudgetAtomic
        }
    }

    private struct CanonicalPreparedNetworkFee: Encodable {
        let model: String
        let primaryValue: String
        let secondaryValue: String?
        let totalBudgetAtomic: String?
        let provider: String?
        let expiresAtMilliseconds: Int64?
        let tronParameters: SendTronProtocolParameters?

        init(fee: SendResolvedNetworkFee) {
            model = fee.model.rawValue
            primaryValue = fee.primaryValue
            secondaryValue = fee.secondaryValue
            totalBudgetAtomic = fee.totalBudgetAtomic
            provider = fee.provider
            tronParameters = fee.tronParameters
            expiresAtMilliseconds = fee.expiresAt.map {
                Int64(($0.timeIntervalSince1970 * 1_000).rounded())
            }
        }
    }

    private struct CanonicalBitcoinFamilyOptions: Encodable {
        let selectionKind: String
        let selectedOutputs: [CanonicalBitcoinOutput]
        let replaceByFee: Bool
        let opReturnMessage: String?

        init(options: SendBitcoinFamilyOptions) {
            switch options.coinSelection {
            case .automatic:
                selectionKind = "automatic"
                selectedOutputs = []
            case let .manual(outputs):
                selectionKind = "manual"
                selectedOutputs = outputs.map(
                    CanonicalBitcoinOutput.init
                )
            }
            replaceByFee = options.replaceByFee
            opReturnMessage = options.opReturnMessage
        }
    }

    private struct CanonicalBitcoinOutput: Encodable {
        let networkID: String
        let transactionHash: String
        let outputIndex: Int
        let valueAtomic: String
        let blockHeight: Int64
        let confirmations: Int64

        init(output: SendBitcoinUTXO) {
            networkID = output.networkID
            transactionHash = output.outpoint.transactionHash
            outputIndex = output.outpoint.outputIndex
            valueAtomic = output.valueAtomic
            blockHeight = output.blockHeight
            confirmations = output.confirmations
        }
    }
}
