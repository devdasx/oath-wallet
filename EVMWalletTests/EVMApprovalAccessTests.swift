import Foundation
import Testing
import WalletCore
@testable import Aperture

@Suite(.serialized)
struct EVMApprovalAccessTests {
    private static let owner =
        "0xb92fe925dc43a0ecde6c8b1a2709c170ec4fff4f"
    private static let spender =
        "0x1111111254eeb25477b68fb85ed929f73a960582"
    private static let contract =
        "0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2"

    @Test
    func accessToolEligibilityCoversRecoveryAndEVMPrivateKeyWallets() {
        #expect(WalletCapabilities.fullWallet.usesEVMWalletAddress)
        #expect(
            WalletCapabilities(scope: .privateKey(.evm))
                .usesEVMWalletAddress
        )
        #expect(
            !WalletCapabilities(scope: .privateKey(.bitcoin))
                .usesEVMWalletAddress
        )
        #expect(
            !WalletCapabilities(scope: .privateKey(.solana))
                .usesEVMWalletAddress
        )
    }

    @Test
    func encodesCurrentAllowanceReadExactly() throws {
        let ownerWord = String(repeating: "0", count: 24)
            + String(Self.owner.dropFirst(2))
        let spenderWord = String(repeating: "0", count: 24)
            + String(Self.spender.dropFirst(2))

        #expect(
            try EVMApprovalABI.allowanceCall(
                ownerAddress: Self.owner,
                spenderAddress: Self.spender
            ) == "0xdd62ed3e" + ownerWord + spenderWord
        )
        #expect(
            try EVMApprovalABI.isApprovedForAllCall(
                ownerAddress: Self.owner,
                operatorAddress: Self.spender
            ) == "0xe985e9c5" + ownerWord + spenderWord
        )
    }

    @Test
    func encodesEveryRevocationWithoutMovingValue() throws {
        let spenderWord = String(repeating: "0", count: 24)
            + String(Self.spender.dropFirst(2))
        let zeroWord = String(repeating: "0", count: 64)

        let allowance = Self.approval(kind: .tokenAllowance)
        #expect(
            try EVMApprovalABI.revokeCalldata(approval: allowance)
                == "0x095ea7b3" + spenderWord + zeroWord
        )

        let nft = Self.approval(kind: .nftToken, tokenID: "42")
        let tokenWord = try SendAtomicAmount.fixedWidthData(
            "42",
            byteCount: 32
        ).hexString
        #expect(
            try EVMApprovalABI.revokeCalldata(approval: nft)
                == "0x095ea7b3" + zeroWord + tokenWord
        )

        let operatorApproval = Self.approval(kind: .operatorAccess)
        #expect(
            try EVMApprovalABI.revokeCalldata(
                approval: operatorApproval
            ) == "0xa22cb465" + spenderWord + zeroWord
        )
    }

    @Test
    func decodesLosslessCurrentStateValues() throws {
        let currentAllowance =
            "0x00000000000000000000000000000000000000000000000004475c56b4715004"
        #expect(
            try EVMApprovalABI.unsignedInteger(currentAllowance)
                == "308316626962436100"
        )
        #expect(try EVMApprovalABI.boolean("0x" + Self.word("1")))
        #expect(!(try EVMApprovalABI.boolean("0x" + Self.word("0"))))
        #expect(
            EVMApprovalABI.address(
                "0x" + String(repeating: "0", count: 24)
                    + String(Self.spender.dropFirst(2))
            ) == Self.spender
        )
        #expect(
            EVMApprovalABI.topicAddress(
                "0x" + String(repeating: "0", count: 24)
                    + String(Self.owner.dropFirst(2))
            ) == Self.owner
        )
    }

    @Test
    func stableIdentityTracksThePermissionBeingRevoked() {
        let alternateSpender =
            "0x2222222254eeb25477b68fb85ed929f73a960582"
        let allowanceA = EVMOnChainApproval.stableID(
            accountID: "account",
            networkID: "eth",
            contractAddress: Self.contract,
            spenderAddress: Self.spender,
            kind: .tokenAllowance,
            tokenID: nil
        )
        let allowanceB = EVMOnChainApproval.stableID(
            accountID: "account",
            networkID: "eth",
            contractAddress: Self.contract,
            spenderAddress: alternateSpender,
            kind: .tokenAllowance,
            tokenID: nil
        )
        #expect(allowanceA != allowanceB)

        let nftA = EVMOnChainApproval.stableID(
            accountID: "account",
            networkID: "eth",
            contractAddress: Self.contract,
            spenderAddress: Self.spender,
            kind: .nftToken,
            tokenID: "42"
        )
        let nftB = EVMOnChainApproval.stableID(
            accountID: "account",
            networkID: "eth",
            contractAddress: Self.contract,
            spenderAddress: alternateSpender,
            kind: .nftToken,
            tokenID: "42"
        )
        #expect(nftA == nftB)
    }

    @Test
    func signedRevokeContainsExactCalldataAndZeroNativeValue() throws {
        let keyData = try #require(Data(hexString:
            "608dcb1742bb3fb7aec002074e3420e4f"
            + "ab7d00cced79ccdac53ed5b27138151"
        ))
        let key = try #require(PrivateKey(data: keyData))
        let owner = CoinType.ethereum.deriveAddress(privateKey: key)
        let account = DBWalletAccountRecord(
            id: "evm-approval-test-account",
            walletID: "evm-approval-test-wallet",
            networkID: "eth",
            address: owner,
            normalizedAddress: owner.lowercased(),
            label: nil,
            derivationPath: nil,
            accountIndex: nil,
            publicKey: nil,
            isWatchOnly: false,
            isEnabled: true,
            createdAt: 0,
            updatedAt: 0,
            lastSyncedAt: nil
        )
        let material = SendResolvedSigningMaterial(
            walletID: account.walletID,
            account: account,
            privateKey: keyData
        )
        let approval = Self.approval(
            kind: .tokenAllowance,
            ownerAddress: owner
        )
        let calldata = try EVMApprovalABI.revokeCalldata(
            approval: approval
        )
        let network = try #require(
            ReceiveNetworkCatalog.network(for: "eth")
        )
        let signed = try EVMApprovalRevocationService.sign(
            network: network,
            material: material,
            contractAddress: Self.contract,
            calldata: calldata,
            nonce: "0",
            gasLimit: 50_000,
            fee: SendResolvedNetworkFee(
                model: .evmEIP1559,
                primaryValue: "3000000000",
                secondaryValue: "2000000000"
            )
        )

        #expect(!signed.isEmpty)
        #expect(signed.first == 0x02)
        #expect(signed.hexString.contains(String(calldata.dropFirst(2))))
        #expect(
            try SendEVMTransactionService
                .locallyDerivedTransactionHash(
                    from: signed,
                    networkID: "eth"
                ).count == 32
        )
    }

    @Test
    func revokeDraftIsBoundToOwnerNetworkAndContract() throws {
        let approval = Self.approval(kind: .tokenAllowance)
        let draft = try EVMApprovalDraftFactory.draft(
            approval: approval,
            preparedNetworkFee: SendResolvedNetworkFee(
                model: .evmLegacy,
                primaryValue: "1000000000",
                secondaryValue: nil
            )
        )

        #expect(draft.asset.networkID == "eth")
        #expect(draft.asset.sourceAddress == Self.owner)
        #expect(draft.recipient == Self.contract)
        #expect(draft.amount == "0")
        #expect(draft.request.requestedAmount == .atomicUnits("0"))
        #expect(draft.request.references.contains(approval.id))
    }

    @Test(arguments: [
        "insufficient funds for transfer",
        "insufficient funds for gas * price + value: balance 0, tx cost 120000",
        "Insufficient funds for intrinsic transaction cost",
        "insufficient balance for transaction gas",
        "insufficient funds"
    ])
    func recognizesNativeGasRejections(message: String) {
        let provider = SendTransactionSubmissionError.provider(
            networkID: "avalanche", code: "rpc_-32000", message: message
        )
        #expect(EVMApprovalGasFunding.isInsufficientGas(provider, networkID: "avalanche"))
        #expect(EVMApprovalGasFunding.isInsufficientGas(
            .broadcastRejected(code: "rpc_-32000", message: message), networkID: "avalanche"
        ))
        #expect(EVMApprovalGasFunding.isInsufficientGas(
            .insufficientNetworkFeeBalance, networkID: "avalanche"
        ))
    }

    @Test(arguments: [
        "execution reverted: insufficient funds",
        "execution reverted: ERC20: insufficient allowance",
        "insufficient funds in token contract",
        "out of gas",
        "request timed out",
        "nonce too low"
    ])
    func preservesUnrelatedFailures(message: String) {
        #expect(!EVMApprovalGasFunding.isInsufficientGas(
            .provider(networkID: "eth", code: "rpc_-32000", message: message),
            networkID: "eth"
        ))
        #expect(!EVMApprovalGasFunding.isInsufficientGas(
            .broadcastRejected(code: "rpc_-32000", message: message), networkID: "eth"
        ))
    }

    @Test
    func neverTurnsUncertainOrMismatchedErrorsIntoFundingAdvice() {
        #expect(!EVMApprovalGasFunding.isInsufficientGas(
            .broadcastOutcomeUnknown(networkID: "eth", code: "insufficient funds"), networkID: "eth"
        ))
        #expect(!EVMApprovalGasFunding.isInsufficientGas(
            .provider(networkID: "arbitrum", code: "rpc_-32000", message: "insufficient funds"),
            networkID: "eth"
        ))
        #expect(!EVMApprovalGasFunding.isInsufficientGas(
            .provider(networkID: "eth", code: "http_503", message: "insufficient funds"),
            networkID: "eth"
        ))
    }

    @Test
    func gasReceiveUsesReviewedOwnerAndNativeCoinOnEveryEVMNetwork() throws {
        let networks = ReceiveNetworkCatalog.all.filter { $0.blockchain.isEVM }
        #expect(!networks.isEmpty)
        for network in networks {
            let funding = try #require(EVMApprovalGasFunding(address: Self.owner, networkID: network.id))
            #expect(funding.address == Self.owner)
            #expect(funding.network.symbol == network.symbol)
            #expect(funding.network.chainID == network.chainID)
            #expect(funding.paymentPayload == "ethereum:\(Self.owner)@\(network.chainID)")
            #expect(!funding.paymentPayload.contains(Self.contract))
            #expect(!funding.paymentPayload.contains("/transfer"))
        }
        #expect(EVMApprovalGasFunding(address: Self.contract, networkID: "unsupported") == nil)
        #expect(EVMApprovalGasFunding(address: "invalid", networkID: "eth") == nil)
        #expect(EVMApprovalGasFunding(address: Self.owner, networkID: "tron") == nil)
    }

    @Test(arguments: [
        SendTransactionNetworkStatus.pending, .confirmed, .failed, .notFound, .replaced, .canceled
    ])
    func revocationReceiptUsesVerifiedStatus(status: SendTransactionNetworkStatus) {
        let presentation = EVMApprovalReceiptPresentation(status: status)
        switch status {
        case .pending:
            #expect(presentation.titleKey == "evm_access.status.success")
            #expect(presentation.detailKey == "send.broadcast.submitted.detail")
            #expect(presentation.statusKey == "send.broadcast.status.submitted")
        case .confirmed:
            #expect(presentation.titleKey == "send.broadcast.confirmed.title")
            #expect(presentation.statusKey == "wallet.activity.status.confirmed")
        case .failed:
            #expect(presentation.titleKey == "send.broadcast.execution_failed.title")
            #expect(presentation.statusKey == "wallet.activity.status.failed")
        case .notFound, .replaced, .canceled:
            #expect(presentation.statusKey == status.localizedKey)
            #expect(presentation.detailKey == nil)
        }
    }

    @Test
    func transactionIdentityActionsUseExactHashAndCorrectExplorer() {
        let hash = "0x" + String(repeating: "a", count: 64)
        let detail = EVMApprovalAddressDetail(kind: .transactionID, value: hash, networkID: "arbitrum")
        #expect(detail.value == hash)
        #expect(detail.explorerURL == WalletTransactionExplorer.url(transactionHash: hash, networkID: "arbitrum"))
        #expect(detail.explorerURL != nil)
        let spender = EVMApprovalAddressDetail(kind: .spender, value: Self.spender, networkID: "arbitrum")
        #expect(spender.explorerURL == nil)
    }

    @Test(arguments: ReceiveNetworkCatalog.all.filter { $0.blockchain.isEVM }.map(\.id))
    func balanceCappedGasEstimateRoutesToFundingOnEveryEVMChain(networkID: String) {
        let error = SendTransactionSubmissionError.provider(
            networkID: networkID, code: "rpc_-32000",
            message: "gas required exceeds allowance (25422)"
        )
        #expect(EVMApprovalGasFunding.isInsufficientGas(
            error, networkID: networkID,
            nativeBalance: "25422000000000", feePerGas: "1000000000"
        ))
        #expect(EVMApprovalGasFunding.isInsufficientGas(
            error, networkID: networkID,
            nativeBalance: "25422999999999", feePerGas: "1000000000"
        ))
        #expect(!EVMApprovalGasFunding.isInsufficientGas(
            error, networkID: networkID,
            nativeBalance: "25423000000000", feePerGas: "1000000000"
        ))
        #expect(!EVMApprovalGasFunding.isInsufficientGas(
            error, networkID: networkID,
            nativeBalance: "25421999999999", feePerGas: "1000000000"
        ))
        #expect(!EVMApprovalGasFunding.isInsufficientGas(error, networkID: networkID))
    }

    @Test(arguments: [
        "gas required exceeds allowance (30000000)",
        "gas required exceeds allowance (25422) or always failing transaction",
        "execution reverted: gas required exceeds allowance (25422)",
        "gas required exceeds allowance (-1)",
        "gas required exceeds allowance (18446744073709551616)",
        "out of gas"
    ])
    func unrelatedGasCapsDoNotBecomeDepositAdvice(message: String) {
        #expect(!EVMApprovalGasFunding.isInsufficientGas(
            .provider(networkID: "arbitrum", code: "rpc_-32000", message: message),
            networkID: "arbitrum", nativeBalance: "25422000000000", feePerGas: "1000000000"
        ))
    }

    @Test
    func gasCapVerificationIsLosslessAndRejectsInvalidEvidence() {
        let error = SendTransactionSubmissionError.provider(
            networkID: "eth", code: "rpc_-32000", message: "gas required exceeds allowance (0)"
        )
        #expect(EVMApprovalGasFunding.isInsufficientGas(
            error, networkID: "eth", nativeBalance: "0", feePerGas: "1000000000"
        ))
        #expect(!EVMApprovalGasFunding.isInsufficientGas(
            error, networkID: "eth", nativeBalance: "0", feePerGas: "0"
        ))
        #expect(!EVMApprovalGasFunding.isInsufficientGas(
            error, networkID: "eth", nativeBalance: "0x0", feePerGas: "1000000000"
        ))
        #expect(EVMApprovalGasFunding.isInsufficientGas(
            .provider(networkID: "eth", code: "rpc_-32000", message: "gas required exceeds allowance (25422)"),
            networkID: "eth",
            nativeBalance: "25422999999999999999999999999999999999999",
            feePerGas: "1000000000000000000000000000000000000"
        ))
    }

    @Test(arguments: ReceiveNetworkCatalog.all.filter { $0.blockchain.isEVM }.map(\.id))
    func revocationPreflightRoutesZeroAndDustBalancesToFunding(networkID: String) async throws {
        for balance in ["0", "340000000000", "20999999999999"] {
            var didEstimate = false
            do {
                _ = try await EVMApprovalGasFunding.validatedEstimate(
                    networkID: networkID, nativeBalance: balance, feePerGas: "1000000000"
                ) {
                    didEstimate = true
                    throw SendTransactionSubmissionError.provider(
                        networkID: networkID, code: "rpc__32000",
                        message: "gas required exceeds allowance (340)"
                    )
                }
                Issue.record("An unfunded revocation must not reach signing")
            } catch let error as SendTransactionSubmissionError {
                guard case .insufficientNetworkFeeBalance = error else {
                    Issue.record("Expected the typed funding-screen error")
                    return
                }
                #expect(EVMApprovalGasFunding.isInsufficientGas(error, networkID: networkID))
                #expect(EVMApprovalGasFunding(address: Self.owner, networkID: networkID) != nil)
            }
            #expect(!didEstimate)
        }
    }

    @Test
    func revocationPreflightPreservesFundedEstimatesAndRealFailures() async throws {
        var didEstimate = false
        let result = try await EVMApprovalGasFunding.validatedEstimate(
            networkID: "base", nativeBalance: "21000000000000", feePerGas: "1000000000"
        ) {
            didEstimate = true
            return "0xc350"
        }
        #expect(didEstimate)
        #expect(result == "0xc350")
        for message in ["execution reverted", "gas required exceeds allowance (30000000)"] {
            do {
                _ = try await EVMApprovalGasFunding.validatedEstimate(
                    networkID: "base", nativeBalance: "1000000000000000000", feePerGas: "1000000000"
                ) {
                    throw SendTransactionSubmissionError.provider(
                        networkID: "base", code: "rpc__32000", message: message
                    )
                }
                Issue.record("The provider failure must be preserved")
            } catch let error as SendTransactionSubmissionError {
                guard case let .provider(networkID, _, actualMessage) = error else {
                    Issue.record("A funded provider failure must not ask for a deposit")
                    return
                }
                #expect(networkID == "base")
                #expect(actualMessage == message)
            }
        }
    }

    @Test(arguments: ReceiveNetworkCatalog.all.filter { $0.blockchain.isEVM }.map(\.id))
    func revocationPreflightMapsEstimateFailuresToTypedFundingError(networkID: String) async throws {
        for message in ["insufficient funds for gas * price + value", "gas required exceeds allowance (25422)"] {
            do {
                _ = try await EVMApprovalGasFunding.validatedEstimate(
                    networkID: networkID, nativeBalance: "25422000000000", feePerGas: "1000000000"
                ) {
                    throw SendTransactionSubmissionError.provider(
                        networkID: networkID, code: "rpc__32000", message: message
                    )
                }
                Issue.record("Expected funding failure")
            } catch let error as SendTransactionSubmissionError {
                guard case .insufficientNetworkFeeBalance = error else {
                    Issue.record("Raw provider error escaped the preflight")
                    return
                }
            }
        }
    }

    private static func approval(
        kind: EVMApprovalKind,
        tokenID: String? = nil,
        ownerAddress: String = owner
    ) -> EVMOnChainApproval {
        let id = EVMOnChainApproval.stableID(
            accountID: "account",
            networkID: "eth",
            contractAddress: contract,
            spenderAddress: spender,
            kind: kind,
            tokenID: tokenID
        )
        return EVMOnChainApproval(
            id: id,
            accountID: "account",
            networkID: "eth",
            ownerAddress: ownerAddress,
            contractAddress: contract,
            spenderAddress: spender,
            kind: kind,
            tokenID: tokenID,
            amountAtomic: kind == .tokenAllowance ? "1" : nil,
            tokenName: "Fixture",
            tokenSymbol: "FIX",
            decimals: kind == .tokenAllowance ? 18 : nil,
            transactionHash: nil,
            blockNumber: "1",
            discoveredAt: Date(timeIntervalSince1970: 1),
            lastValidatedAt: Date(timeIntervalSince1970: 1),
            pendingRevocationTransactionHash: nil,
            pendingRevocationSubmittedAt: nil
        )
    }

    private static func word(_ hexadecimal: String) -> String {
        String(repeating: "0", count: 64 - hexadecimal.count)
            + hexadecimal
    }
}
