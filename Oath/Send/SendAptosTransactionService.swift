import Foundation
import WalletCore

struct SendAptosTransactionService: Sendable {
    private let api: AptosAPIClient
    private let quoteLoader:
        @Sendable (String) async throws -> SendNetworkFeeQuote

    init(
        api: AptosAPIClient = .shared,
        quoteLoader: @escaping @Sendable (String) async throws
            -> SendNetworkFeeQuote = SendSubmissionNetworkFee.builtInQuote
    ) {
        self.api = api
        self.quoteLoader = quoteLoader
    }

    func submit(
        draft: SendDraft,
        material: SendResolvedSigningMaterial,
        reservation: any SendSpendSubmissionReserving
    ) async throws -> SendTransactionReceipt {
        guard draft.asset.networkID == AptosConstants.networkID else {
            throw SendTransactionSubmissionError.unsupportedNetwork
        }
        let normalizedRecipient = draft.recipient.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let normalizedSender = material.account.address.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard let recipient = AptosAddress.canonical(normalizedRecipient) else {
            throw SendTransactionSubmissionError.invalidRecipient
        }
        guard let sender = AptosAddress.canonical(normalizedSender) else {
            throw SendTransactionSubmissionError.derivedAddressMismatch
        }
        guard let requestedAmount = draft.amount else {
            throw SendTransactionSubmissionError.invalidAmount
        }
        let requestedAtomic = try SendAtomicAmount.uint64(
            SendAtomicAmount.fromUserUnits(
                requestedAmount,
                decimals: draft.asset.decimals
            )
        )
        let asset = try Self.asset(from: draft.asset)
        let fee: SendResolvedNetworkFee
        do {
            fee = try await SendSubmissionNetworkFee.resolve(
                draft: draft,
                quoteLoader: quoteLoader
            )
        } catch let error as SendNetworkFeeAPIError {
            throw SendTransactionSubmissionError.feeQuoteUnavailable(
                error.diagnosticCode
            )
        }

        async let accountValue = api.accountState(address: sender)
        async let nativeBalanceValue = api.nativeBalance(address: sender)
        async let assetStateValue = liveAssetState(
            asset: asset,
            sender: sender
        )
        let account: AptosAccountState
        let nativeBalanceAtomic: String
        let assetState: AptosAssetSendState?
        do {
            (account, nativeBalanceAtomic, assetState) = try await (
                accountValue,
                nativeBalanceValue,
                assetStateValue
            )
        } catch let error as AptosProviderError {
            throw Self.providerError(error)
        }

        guard account.authenticationKey.lowercased() == sender.lowercased()
        else {
            throw SendTransactionSubmissionError.derivedAddressMismatch
        }
        guard account.sequenceNumber <= UInt64(Int64.max) else {
            throw SendTransactionSubmissionError.amountOutOfRange
        }
        guard fee.model == .aptosProtocol,
              let maximumFee = UInt64(fee.primaryValue),
              let gasUnitPriceText = fee.secondaryValue,
              let gasUnitPrice = UInt64(gasUnitPriceText),
              maximumFee > 0,
              gasUnitPrice > 0
        else {
            throw SendTransactionSubmissionError.feeQuoteUnavailable(
                "wrong_aptos_fee_model"
            )
        }
        let amountAtomic = try Self.resolvedAmount(
            draft: draft,
            asset: asset,
            requested: requestedAtomic,
            nativeBalanceAtomic: nativeBalanceAtomic,
            assetState: assetState,
            maximumFee: maximumFee
        )
        let maximumGas = maximumFee / gasUnitPrice
        let reconstructedFee = maximumGas.multipliedReportingOverflow(
            by: gasUnitPrice
        )
        guard maximumGas > 0,
              !reconstructedFee.overflow,
              reconstructedFee.partialValue == maximumFee
        else {
            throw SendTransactionSubmissionError.feeQuoteUnavailable(
                "invalid_aptos_gas_budget"
            )
        }

        var signingInput = AptosSigningInput.with {
            $0.sender = sender
            $0.sequenceNumber = Int64(account.sequenceNumber)
            $0.maxGasAmount = maximumGas
            $0.gasUnitPrice = gasUnitPrice
            $0.expirationTimestampSecs = UInt64(
                Date().timeIntervalSince1970
                    + AptosConstants.transactionExpirationInterval
            )
            $0.chainID = AptosConstants.chainID
            $0.privateKey = material.privateKey
            switch asset {
            case .native:
                $0.transfer = .with {
                    $0.to = recipient
                    $0.amount = amountAtomic
                }
            case let .coin(tag):
                $0.tokenTransferCoins = .with {
                    $0.to = recipient
                    $0.amount = amountAtomic
                    $0.function = tag.walletCoreValue
                }
            case let .fungibleAsset(metadataAddress):
                $0.fungibleAssetTransfer = .with {
                    $0.metadataAddress = metadataAddress
                    $0.to = recipient
                    $0.amount = amountAtomic
                }
            }
        }
        var output: AptosSigningOutput = AnySigner.sign(input: signingInput, coin: .aptos)
        guard output.error == .ok, !output.encoded.isEmpty else {
            throw SendTransactionSubmissionError.signing(
                code: String(output.error.rawValue),
                message: SendTransactionSubmissionError.sanitizedMessage(
                    output.errorMessage
                )
            )
        }

        let simulation: AptosSimulationResult
        do {
            simulation = try await api.simulate(
                signedTransaction: output.encoded
            )
        } catch let error as AptosProviderError {
            throw Self.providerError(error)
        }
        guard simulation.sender == sender,
              simulation.sequenceNumber == account.sequenceNumber,
              simulation.maximumGasAmount == maximumGas,
              simulation.gasUnitPrice == gasUnitPrice
        else {
            throw SendTransactionSubmissionError.provider(
                networkID: AptosConstants.networkID,
                code: "aptos_simulation_mismatch",
                message: WalletLocalization.string(
                    "send.submit.error.aptos_provider"
                )
            )
        }
        guard simulation.succeeded else {
            throw SendTransactionSubmissionError.provider(
                networkID: AptosConstants.networkID,
                code: "aptos_simulation_\(AptosRESTTransport.publicCode(simulation.vmStatus))",
                message: WalletLocalization.string(
                    "send.submit.error.aptos_provider"
                )
            )
        }

        let sequence = try await SendAtomicAmount.uint64(
            reservation.nextSequence(networkValue: String(account.sequenceNumber))
        )
        guard sequence <= UInt64(Int64.max) else {
            throw SendTransactionSubmissionError.amountOutOfRange
        }
        if sequence != account.sequenceNumber {
            signingInput.sequenceNumber = Int64(sequence)
            output = AnySigner.sign(input: signingInput, coin: .aptos)
            guard output.error == .ok, !output.encoded.isEmpty else {
                throw SendTransactionSubmissionError.signing(
                    code: String(output.error.rawValue),
                    message: SendTransactionSubmissionError.sanitizedMessage(output.errorMessage)
                )
            }
        }
        let localHash = Self.transactionHash(output.encoded)
        var receipt = SendTransactionReceipt(
            transactionHash: localHash,
            accountID: material.account.id,
            networkID: AptosConstants.networkID,
            fromAddress: sender,
            toAddress: recipient,
            assetID: draft.asset.id,
            assetSymbol: draft.asset.symbol,
            amount: SendDecimalAmount.userUnits(
                fromAtomicUnits: String(amountAtomic),
                decimals: draft.asset.decimals
            ),
            amountAtomic: String(amountAtomic),
            networkFee: SendDecimalAmount.userUnits(
                fromAtomicUnits: String(maximumFee),
                decimals: AptosConstants.decimals
            ),
            networkFeeAtomic: String(maximumFee),
            networkFeeSymbol: AptosConstants.nativeSymbol,
            submittedAt: Date()
        )

        receipt.spendResources = [.sequence(String(sequence))]
        try await reservation.markSubmissionStarted(receipt: receipt)
        let providerHash: String
        do {
            providerHash = try await api.submit(
                signedTransaction: output.encoded
            ).transactionHash
        } catch let error as AptosProviderError {
            if AptosSubmissionErrorClassifier
                .isDefinitiveRejection(error) {
                throw SendTransactionSubmissionError.broadcastRejected(
                    code: error.diagnosticDescription,
                    message: WalletLocalization.string(
                        "send.submit.error.aptos_rejected"
                    ),
                    receipt: receipt
                )
            }
            throw SendTransactionSubmissionError.broadcastOutcomeUnknown(
                networkID: AptosConstants.networkID,
                code: error.diagnosticDescription,
                receipt: receipt
            )
        } catch {
            throw SendTransactionSubmissionError.broadcastOutcomeUnknown(
                networkID: AptosConstants.networkID,
                code: SendTransactionSubmissionError.sanitizedErrorType(error),
                receipt: receipt
            )
        }
        guard providerHash.lowercased() == localHash else {
            throw SendTransactionSubmissionError.broadcastOutcomeUnknown(
                networkID: AptosConstants.networkID,
                code: "broadcast_hash_mismatch",
                receipt: receipt
            )
        }
        return receipt
    }

    private static func resolvedAmount(
        draft: SendDraft,
        asset: AptosSendAsset,
        requested: UInt64,
        nativeBalanceAtomic: String,
        assetState: AptosAssetSendState?,
        maximumFee: UInt64
    ) throws -> UInt64 {
        let nativeBalance = try SendAtomicAmount.uint64(nativeBalanceAtomic)
        switch asset {
        case .native:
            return try SendNativeTransferAmountResolver.uint64(
                requestedAtomic: requested,
                balanceAtomic: nativeBalance,
                unavailableAtomic: maximumFee,
                usesMaximumBalance: draft.usesMaximumBalance
            )
        case .coin, .fungibleAsset:
            guard nativeBalance >= maximumFee else {
                throw SendTransactionSubmissionError
                    .insufficientNetworkFeeBalance
            }
            guard let assetState else {
                throw SendTransactionSubmissionError.insufficientAssetBalance
            }
            guard !assetState.isFrozen else {
                throw SendTransactionSubmissionError.provider(
                    networkID: AptosConstants.networkID,
                    code: "aptos_asset_frozen",
                    message: WalletLocalization.string(
                        "send.submit.error.aptos_provider"
                    )
                )
            }
            let tokenBalance = try SendAtomicAmount.uint64(
                assetState.atomicAmount
            )
            let amount = draft.usesMaximumBalance
                ? tokenBalance : requested
            guard amount > 0 else {
                throw SendTransactionSubmissionError.invalidAmount
            }
            guard amount <= tokenBalance else {
                throw SendTransactionSubmissionError.insufficientAssetBalance
            }
            return amount
        }
    }

    private func liveAssetState(
        asset: AptosSendAsset,
        sender: String
    ) async throws -> AptosAssetSendState? {
        guard let assetType = asset.assetType else { return nil }
        return try await api.assetSendState(
            address: sender,
            assetType: assetType
        )
    }

    private static func asset(
        from choice: SendAssetChoice
    ) throws -> AptosSendAsset {
        guard let contract = choice.contractAddress else { return .native }
        guard let canonical = AptosAssetType.canonical(contract),
              canonical != AptosConstants.nativeCoinType,
              canonical != AptosConstants.nativeMetadataAddress
        else { throw SendTransactionSubmissionError.unsupportedAsset }
        if let tag = AptosCoinTag(canonical) {
            return .coin(tag)
        }
        guard let address = AptosAddress.canonical(canonical) else {
            throw SendTransactionSubmissionError.unsupportedAsset
        }
        return .fungibleAsset(address)
    }

    static func transactionHash(_ signedTransaction: Data) -> String {
        let domain = Hash.sha3_256(data: Data("APTOS::Transaction".utf8))
        // Aptos hashes the BCS `Transaction` enum, not a bare
        // `SignedTransaction`. `UserTransaction` is enum variant zero, whose
        // ULEB128 discriminator is the single 0x00 byte.
        return "0x" + Hash.sha3_256(
            data: domain + Data([0]) + signedTransaction
        ).map { String(format: "%02x", $0) }.joined()
    }

    private static func providerError(
        _ error: AptosProviderError
    ) -> SendTransactionSubmissionError {
        switch error {
        case .insufficientFunds:
            .insufficientAssetBalance
        default:
            .provider(
                networkID: AptosConstants.networkID,
                code: error.diagnosticDescription,
                message: error.diagnosticDescription
            )
        }
    }
}

private enum AptosSendAsset: Sendable {
    case native
    case coin(AptosCoinTag)
    case fungibleAsset(String)

    var assetType: String? {
        switch self {
        case .native:
            nil
        case let .coin(tag):
            tag.canonicalValue
        case let .fungibleAsset(metadataAddress):
            metadataAddress
        }
    }
}

private struct AptosCoinTag: Sendable {
    let address: String
    let module: String
    let name: String

    init?(_ value: String) {
        let parts = value.split(separator: "::", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let address = AptosAddress.canonical(String(parts[0]))
        else { return nil }
        self.address = address
        module = String(parts[1])
        name = String(parts[2])
    }

    var walletCoreValue: AptosStructTag {
        .with {
            $0.accountAddress = address
            $0.module = module
            $0.name = name
        }
    }

    var canonicalValue: String {
        "\(address)::\(module)::\(name)"
    }
}
