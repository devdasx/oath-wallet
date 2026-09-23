import Foundation
import Testing
import WalletCore
@testable import Aperture

@Suite(.serialized)
struct SendTransactionSubmissionTests {
    @Test
    func atomicAmountConversionAndArithmeticRemainLossless() throws {
        #expect(
            try SendAtomicAmount.fromUserUnits(
                "9007199254740993.000000001",
                decimals: 9
            ) == "9007199254740993000000001"
        )
        #expect(
            SendAtomicAmount.add(
                "999999999999999999999999",
                "1"
            ) == "1000000000000000000000000"
        )
        #expect(
            try SendAtomicAmount.subtract(
                "1000000000000000000000000",
                "1"
            ) == "999999999999999999999999"
        )
        #expect(
            try SendAtomicAmount.multiply(
                "18446744073709551616",
                by: 21_000
            ) == "387381625547900583936000"
        )
    }

    @Test
    func hexadecimalQuantityRoundTripPreservesLargeValues() throws {
        let decimal = "340282366920938463463374607431768211455"
        let hexadecimal = try SendAtomicAmount.hexQuantity(decimal)

        #expect(
            try SendAtomicAmount.decimalFromHexQuantity(hexadecimal)
                == decimal
        )
        #expect(
            try SendAtomicAmount.fixedWidthData(
                decimal,
                byteCount: 32
            ).count == 32
        )
    }

    @Test
    func abiUnsignedIntegerUsesTheLeadingReturnWord() throws {
        let leadingWord = String(repeating: "0", count: 62) + "2a"
        let trailingWords = String(repeating: "0", count: 128)

        #expect(
            try SendAtomicAmount.decimalFromABIUnsignedInteger(
                "0x" + leadingWord + trailingWords
            ) == "42"
        )
        #expect(
            throws: SendTransactionSubmissionError.self
        ) {
            try SendAtomicAmount.decimalFromABIUnsignedInteger("0x2a")
        }
        #expect(
            throws: SendTransactionSubmissionError.self
        ) {
            try SendAtomicAmount.decimalFromABIUnsignedInteger(
                "0x" + String(repeating: "z", count: 64)
            )
        }
    }

    @Test
    func invalidOrExcessiveAtomicAmountsAreRejected() {
        #expect(throws: SendTransactionSubmissionError.invalidAmount) {
            try SendAtomicAmount.fromUserUnits(
                "1.0000000001",
                decimals: 9
            )
        }
        #expect(
            throws: SendTransactionSubmissionError.amountOutOfRange
        ) {
            try SendAtomicAmount.uint64("18446744073709551616")
        }
        #expect(
            throws:
                SendTransactionSubmissionError
                    .insufficientAssetBalance
        ) {
            try SendAtomicAmount.subtract("1", "2")
        }
    }

    @Test
    func definiteRejectionCanRetryButUnknownOutcomeCannot() {
        let rejected = SendTransactionSubmissionError
            .broadcastRejected(
                code: "replacement_underpriced",
                message: "Rejected by the node"
            )
        let unknown = SendTransactionSubmissionError
            .broadcastOutcomeUnknown(
                networkID: "eth",
                code: "timed_out"
            )

        #expect(rejected.allowsRetry)
        #expect(!rejected.submissionMayHaveSucceeded)
        #expect(!unknown.allowsRetry)
        #expect(unknown.submissionMayHaveSucceeded)
        #expect(
            unknown.diagnosticCode
                == "broadcast_unknown_eth_timed_out"
        )
    }

    @Test
    func executedNetworkFailureRetainsHashAndCannotBeRetried() {
        let receipt = SendTransactionReceipt(
            transactionHash: "executed-failure-hash",
            accountID: "account",
            networkID: NEARConstants.networkID,
            fromAddress: "sender.near",
            toAddress: "recipient.near",
            assetID: NEARConstants.nativeAssetID,
            assetSymbol: NEARConstants.nativeSymbol,
            amount: "1",
            amountAtomic: "1000000000000000000000000",
            networkFee: "0.001",
            networkFeeAtomic: "1000000000000000000000",
            networkFeeSymbol: NEARConstants.nativeSymbol,
            submittedAt: Date(timeIntervalSince1970: 1_786_838_400)
        )
        let error = SendTransactionSubmissionError
            .broadcastExecutionFailed(
                code: "action_error",
                message: "Execution failed",
                receipt: receipt
            )

        #expect(error.wasExecutedOnNetwork)
        #expect(!error.submissionMayHaveSucceeded)
        #expect(!error.allowsRetry)
        #expect(error.transactionEvidenceReceipt == receipt)
        #expect(error.unconfirmedReceipt == nil)
        #expect(
            SendBroadcastReceiptPresentation.visibleTransactionHash(
                receipt.transactionHash,
                submissionWasAccepted: error.wasExecutedOnNetwork,
                submissionMayHaveSucceeded:
                    error.submissionMayHaveSucceeded
            ) == receipt.transactionHash
        )
    }

    @Test
    func broadcastReceiptPresentationUsesLocalFeeAndOnlySafeHashes() {
        #expect(
            SendBroadcastReceiptPresentation.compactIdentity("alice.near")
                == "alice.near"
        )
        #expect(
            SendBroadcastReceiptPresentation.compactIdentity(
                "12345678901234567890"
            ) == "12345678…567890"
        )
        #expect(
            SendBroadcastReceiptPresentation.networkFeeUSDValue(
                nativeFee: "0.125",
                nativeUnitUSDPrice: Decimal(string: "2.40")
            ) == Decimal(string: "0.30000")
        )
        #expect(
            SendBroadcastReceiptPresentation.networkFeeUSDValue(
                nativeFee: "not-a-number",
                nativeUnitUSDPrice: 2
            ) == nil
        )
        #expect(
            SendBroadcastReceiptPresentation.visibleTransactionHash(
                "accepted-hash",
                submissionWasAccepted: true,
                submissionMayHaveSucceeded: false
            ) == "accepted-hash"
        )
        #expect(
            SendBroadcastReceiptPresentation.visibleTransactionHash(
                "unknown-hash",
                submissionWasAccepted: false,
                submissionMayHaveSucceeded: true
            ) == "unknown-hash"
        )
        #expect(
            SendBroadcastReceiptPresentation.visibleTransactionHash(
                "rejected-hash",
                submissionWasAccepted: false,
                submissionMayHaveSucceeded: false
            ) == nil
        )
    }

    @Test
    func unknownTONOutcomeRetainsLocallyDerivedEvidence() {
        let receipt = SendTransactionReceipt(
            transactionHash: String(repeating: "ab", count: 32),
            accountID: "account",
            networkID: TONConstants.networkID,
            fromAddress: "sender",
            toAddress: "recipient",
            assetID: "ton:native",
            assetSymbol: TONConstants.nativeSymbol,
            amount: "24.9",
            amountAtomic: "24900000000",
            networkFee: "0.05",
            networkFeeAtomic: "50000000",
            networkFeeSymbol: TONConstants.nativeSymbol,
            submittedAt: Date(timeIntervalSince1970: 1_785_417_600)
        )
        let error = SendTransactionSubmissionError
            .broadcastOutcomeUnknown(
                networkID: TONConstants.networkID,
                code: "ton_provider_timeout",
                receipt: receipt
            )

        #expect(error.unconfirmedReceipt == receipt)
        #expect(error.submissionMayHaveSucceeded)
        #expect(!error.allowsRetry)
    }

    @Test
    func rejectedTONOutcomeRetainsEvidenceWithoutBecomingUnconfirmed() {
        let receipt = SendTransactionReceipt(
            transactionHash: String(repeating: "cd", count: 32),
            accountID: "account",
            networkID: TONConstants.networkID,
            fromAddress: "sender",
            toAddress: "recipient",
            assetID: TONConstants.nativeAssetID,
            assetSymbol: TONConstants.nativeSymbol,
            amount: "25.044973665",
            amountAtomic: "25044973665",
            networkFee: "0.05",
            networkFeeAtomic: "50000000",
            networkFeeSymbol: TONConstants.nativeSymbol,
            submittedAt: Date(timeIntervalSince1970: 1_785_417_600)
        )
        let error = SendTransactionSubmissionError.broadcastRejected(
            code: "ton_preflight_rejected_exit_36",
            message: "TON provider rejected the signed message.",
            receipt: receipt
        )

        #expect(error.transactionEvidenceReceipt == receipt)
        #expect(error.unconfirmedReceipt == nil)
        #expect(!error.submissionMayHaveSucceeded)
        #expect(error.allowsRetry)
    }

    @Test
    func resolvedEIP1559FeePreservesMaximumAndPriorityValues()
        throws
    {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let quote = try decoder.decode(
            SendNetworkFeeQuoteEnvelope.self,
            from: Data(
                """
                {
                  "quote": {
                    "networkID": "eth",
                    "provider": "ankr",
                    "fetchedAt": "2026-07-27T00:00:00Z",
                    "expiresAt": "2026-07-27T00:00:15Z",
                    "tiers": [
                      {
                        "preset": "fastest",
                        "model": "evm_eip1559",
                        "primaryValue": "42000000000",
                        "secondaryValue": "3000000000"
                      }
                    ]
                  }
                }
                """.utf8
            )
        ).quote

        let resolved = try SendResolvedNetworkFee.resolve(
            policy: .fastest,
            quote: quote
        )

        #expect(resolved.model == .evmEIP1559)
        #expect(resolved.primaryValue == "42000000000")
        #expect(resolved.secondaryValue == "3000000000")
    }

    @Test
    func evmBroadcastHashMustMatchLocallySignedBytes() throws {
        let signedTransaction = Data("abc".utf8)
        let knownKeccak256 =
            "4e03657aea45a94fc7d47ba826c8d667"
            + "c0d1e6e33a64a036ec44f58fa12d6c45"
        let localHash = try SendEVMTransactionService
            .locallyDerivedTransactionHash(
                from: signedTransaction,
                networkID: "eth"
            )

        #expect(localHash.hexString == knownKeccak256)
        let verified = try SendEVMTransactionService
            .verifiedBroadcastHash(
                "0x" + knownKeccak256.uppercased(),
                locallyDerivedHash: localHash,
                networkID: "eth"
            )
        #expect(verified == "0x" + knownKeccak256)
    }

    @Test
    func evmRejectsUnrelatedOrMalformedProviderHashes() throws {
        let localHash = try SendEVMTransactionService
            .locallyDerivedTransactionHash(
                from: Data("signed payload".utf8),
                networkID: "polygon"
            )
        #expect(
            throws: SendTransactionSubmissionError
                .broadcastOutcomeUnknown(
                    networkID: "polygon",
                    code: "broadcast_hash_mismatch"
                )
        ) {
            try SendEVMTransactionService.verifiedBroadcastHash(
                "0x" + String(repeating: "11", count: 32),
                locallyDerivedHash: localHash,
                networkID: "polygon"
            )
        }
        #expect(
            throws: SendTransactionSubmissionError
                .broadcastOutcomeUnknown(
                    networkID: "polygon",
                    code: "invalid_transaction_hash"
                )
        ) {
            try SendEVMTransactionService.verifiedBroadcastHash(
                "0x1234",
                locallyDerivedHash: localHash,
                networkID: "polygon"
            )
        }
    }

    @Test
    func evmRecognizesOnlyExplicitAlreadyKnownBroadcastResponses() {
        for message in [
            "already known",
            "Known transaction: 0x1234",
            "transaction already imported"
        ] {
            #expect(
                SendEVMTransactionService.isAlreadyKnownBroadcastRejection(
                    .broadcastRejected(code: "rpc_-32000", message: message)
                )
            )
        }
        #expect(
            !SendEVMTransactionService.isAlreadyKnownBroadcastRejection(
                .broadcastRejected(
                    code: "rpc_-32000",
                    message: "nonce too low"
                )
            )
        )
        #expect(
            !SendEVMSubmissionErrorClassifier.isDefinitiveRPCRejection(
                code: -32_000,
                message: "nonce too low"
            )
        )
        #expect(
            !SendEVMSubmissionErrorClassifier.isDefinitiveRPCRejection(
                code: -32_000,
                message: "replacement transaction underpriced"
            )
        )
        #expect(
            SendEVMSubmissionErrorClassifier.isDefinitiveRPCRejection(
                code: -32_000,
                message: "transaction underpriced"
            )
        )
        #expect(
            SendEVMSubmissionErrorClassifier.isDefinitiveRPCRejection(
                code: -32_000,
                message: "transaction already imported"
            )
        )
        #expect(
            SendEVMSubmissionErrorClassifier.isDefinitiveRPCRejection(
                code: -32_000,
                message: "insufficient funds for gas * price + value"
            )
        )
    }

    @Test
    func solanaBroadcastSignatureMustMatchSignedWireBytes() throws {
        let localSignature = Data((1...64).map(UInt8.init))
        let transaction = solanaTransaction(
            signature: localSignature
        )
        let extracted = try SendSolanaTransactionService
            .locallyEmbeddedSignature(
                fromBase64Transaction: transaction
            )
        let providerSignature = Base58.encodeNoCheck(
            data: localSignature
        )

        #expect(extracted == localSignature)
        #expect(
            try SendSolanaTransactionService
                .verifiedBroadcastSignature(
                    providerSignature,
                    locallyEmbeddedSignature: extracted
                ) == providerSignature
        )
    }

    @Test
    func solanaRejectsUnrelatedOrMalformedProviderSignatures()
        throws
    {
        let localSignature = Data((1...64).map(UInt8.init))
        let unrelated = Data(repeating: 0x7f, count: 64)
        #expect(
            throws: SendTransactionSubmissionError
                .broadcastOutcomeUnknown(
                    networkID: SolanaConstants.networkID,
                    code: "broadcast_signature_mismatch"
                )
        ) {
            try SendSolanaTransactionService
                .verifiedBroadcastSignature(
                    Base58.encodeNoCheck(data: unrelated),
                    locallyEmbeddedSignature: localSignature
                )
        }
        #expect(
            throws: SendTransactionSubmissionError
                .broadcastOutcomeUnknown(
                    networkID: SolanaConstants.networkID,
                    code: "invalid_signature"
                )
        ) {
            try SendSolanaTransactionService
                .verifiedBroadcastSignature(
                    "not-a-base58-signature",
                    locallyEmbeddedSignature: localSignature
                )
        }
    }

    @Test
    func solanaRejectsUnsignedOrTruncatedWireTransactions() {
        let unsigned = Data([1])
            + Data(repeating: 0, count: 64)
            + Data([1])
        let truncated = Data([1])
            + Data(repeating: 7, count: 63)

        #expect(throws: SendTransactionSubmissionError.self) {
            try SendSolanaTransactionService
                .locallyEmbeddedSignature(
                    fromBase64Transaction: unsigned
                        .base64EncodedString()
                )
        }
        #expect(throws: SendTransactionSubmissionError.self) {
            try SendSolanaTransactionService
                .locallyEmbeddedSignature(
                    fromBase64Transaction: truncated
                        .base64EncodedString()
                )
        }
    }

    @Test
    func solanaNonStringBroadcastResultIsOutcomeUnknown()
        async
    {
        await #expect(
            throws: SendTransactionSubmissionError
                .broadcastOutcomeUnknown(
                    networkID: SolanaConstants.networkID,
                    code: "invalid_transaction_signature_type"
                )
        ) {
            try await solanaBroadcastResponse(
                """
                {
                  "jsonrpc": "2.0",
                  "id": 1,
                  "result": {"signature": "not-a-string-result"}
                }
                """
            )
        }
        #expect(
            SolanaBroadcastResponseURLProtocol.lastRPCMethod()
                == "sendTransaction"
        )
    }

    @Test(
        arguments: [
            "",
            "   "
        ]
    )
    func solanaEmptyBroadcastResultIsOutcomeUnknown(
        signature: String
    ) async throws {
        let body = try JSONSerialization.data(
            withJSONObject: [
                "jsonrpc": "2.0",
                "id": 1,
                "result": signature
            ]
        )
        await #expect(
            throws: SendTransactionSubmissionError
                .broadcastOutcomeUnknown(
                    networkID: SolanaConstants.networkID,
                    code: "empty_transaction_signature"
                )
        ) {
            try await solanaBroadcastResponse(body)
        }
    }

    @Test
    func solanaMalformedBroadcastEnvelopeIsOutcomeUnknown()
        async
    {
        await #expect(
            throws: SendTransactionSubmissionError
                .broadcastOutcomeUnknown(
                    networkID: SolanaConstants.networkID,
                    code: "invalid_envelope"
                )
        ) {
            try await solanaBroadcastResponse(
                #"{"jsonrpc":"2.0","id":1,"result":"#
            )
        }
    }

    @Test
    func solanaMismatchedRPCErrorCannotProveRejection()
        async
    {
        await #expect(
            throws: SendTransactionSubmissionError
                .broadcastOutcomeUnknown(
                    networkID: SolanaConstants.networkID,
                    code: "invalid_envelope"
                )
        ) {
            try await solanaBroadcastResponse(
                """
                {
                  "jsonrpc": "2.0",
                  "id": 999,
                  "error": {
                    "code": -32002,
                    "message": "Transaction simulation failed"
                  }
                }
                """
            )
        }
    }

    @Test
    func solanaAmbiguousBroadcastEnvelopeIsOutcomeUnknown()
        async
    {
        await #expect(
            throws: SendTransactionSubmissionError
                .broadcastOutcomeUnknown(
                    networkID: SolanaConstants.networkID,
                    code: "ambiguous_envelope"
                )
        ) {
            try await solanaBroadcastResponse(
                """
                {
                  "jsonrpc": "2.0",
                  "id": 1,
                  "result": "5Sgn9YVYbFJ6Yt6R3usXwNThSUUEGXddJURtrPU7RDTNk5bH1uWnLDMMeLiRUqp4zz9zQ4DkqaC62yJfC3X7npQe",
                  "error": {
                    "code": -32002,
                    "message": "Transaction simulation failed"
                  }
                }
                """
            )
        }
    }

    @Test
    func solanaHTTPFailureWithResultIsOutcomeUnknown()
        async
    {
        await #expect(
            throws: SendTransactionSubmissionError
                .broadcastOutcomeUnknown(
                    networkID: SolanaConstants.networkID,
                    code: "http_502"
                )
        ) {
            try await solanaBroadcastResponse(
                """
                {
                  "jsonrpc": "2.0",
                  "id": 1,
                  "result": "5Sgn9YVYbFJ6Yt6R3usXwNThSUUEGXddJURtrPU7RDTNk5bH1uWnLDMMeLiRUqp4zz9zQ4DkqaC62yJfC3X7npQe"
                }
                """,
                statusCode: 502
            )
        }
    }

    @Test
    func solanaMissingBroadcastResultIsOutcomeUnknown()
        async
    {
        await #expect(
            throws: SendTransactionSubmissionError
                .broadcastOutcomeUnknown(
                    networkID: SolanaConstants.networkID,
                    code: "invalid_envelope"
                )
        ) {
            try await solanaBroadcastResponse(
                """
                {
                  "jsonrpc": "2.0",
                  "id": 1
                }
                """
            )
        }
    }

    @Test
    func solanaMatchingRPCErrorIsDefiniteRejection()
        async
    {
        let rejection = SendTransactionSubmissionError
            .broadcastRejected(
                code: "rpc_-32002",
                message: "Transaction simulation failed"
            )
        await #expect(throws: rejection) {
            try await solanaBroadcastResponse(
                """
                {
                  "jsonrpc": "2.0",
                  "id": 1,
                  "error": {
                    "code": -32002,
                    "message": "Transaction simulation failed"
                  }
                }
                """
            )
        }
        #expect(rejection.allowsRetry)
        #expect(!rejection.submissionMayHaveSucceeded)
    }

    @Test
    func solanaStringBroadcastResultContinuesToIdentifierCheck()
        async throws
    {
        let signature = Base58.encodeNoCheck(
            data: Data((1...64).map(UInt8.init))
        )
        let body = try JSONSerialization.data(
            withJSONObject: [
                "jsonrpc": "2.0",
                "id": 1,
                "result": signature
            ]
        )

        #expect(
            try await solanaBroadcastResponse(body) == signature
        )
    }

    @Test
    func nativeSolanaPaySigningKeepsMemoAndReferences() throws {
        let privateKey = try #require(
            PrivateKey(data: Data(repeating: 7, count: 32))
        )
        let sender = CoinType.solana.deriveAddress(privateKey: privateKey)
        let recipient = "11111111111111111111111111111111"
        let reference =
            "SysvarC1ock11111111111111111111111111111111"
        let baseDraft = solanaDraft(sourceAddress: sender)
        let request = SendPaymentRequest(
            source: .solanaPayURI,
            recipient: recipient,
            candidateNetworkIDs: [SolanaConstants.networkID],
            requestedNetworkID: SolanaConstants.networkID,
            requestedAsset: .native,
            requestedAmount: .userUnits("0.000001"),
            label: nil,
            message: nil,
            memo: "invoice-42",
            references: [reference]
        )
        let draft = SendDraft(
            request: request,
            asset: baseDraft.asset,
            recipient: recipient,
            amount: "0.000001",
            note: nil
        )
        let material = SendResolvedSigningMaterial(
            walletID: "wallet",
            account: account(id: "solana", address: sender),
            privateKey: privateKey.data
        )

        let encoded = try SendSolanaTransactionService().sign(
            draft: draft,
            material: material,
            context: .native(1_000),
            blockhash: recipient,
            priorityPrice: 0,
            computeLimit: 200_000,
            senderAddress: sender,
            recipientAddress: recipient
        )
        let transaction = try #require(Data(base64Encoded: encoded))
        let referenceData = try #require(
            Base58.decodeNoCheck(string: reference)
        )

        #expect(transaction.range(of: Data("invoice-42".utf8)) != nil)
        #expect(transaction.range(of: referenceData) != nil)
    }

    @Test
    func signingAccountSelectionNeverFallsBackPastExplicitSource() {
        let primaryAddress =
            "11111111111111111111111111111111"
        let alternativeAddress =
            "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA"
        let accounts = [
            account(
                id: "alternative",
                address: alternativeAddress
            ),
            account(
                id: "primary",
                address: primaryAddress
            )
        ]

        let exact = SendSigningAccountSelector.matchingAccount(
            in: accounts,
            draft: solanaDraft(sourceAddress: primaryAddress)
        )
        let missing = SendSigningAccountSelector.matchingAccount(
            in: accounts,
            draft: solanaDraft(sourceAddress: "missing-source")
        )

        #expect(exact?.id == "primary")
        #expect(missing == nil)
    }

    private func solanaDraft(
        sourceAddress: String?
    ) -> SendDraft {
        let asset = SendAssetChoice(
            id: "solana:native",
            name: "Solana",
            symbol: "SOL",
            networkID: SolanaConstants.networkID,
            networkName: "Solana",
            blockchain: .solana,
            contractAddress: nil,
            decimals: 9,
            logoSource: .nativeCoin(blockchain: .solana),
            networkLogoSource: .nativeCoin(blockchain: .solana),
            balance: 1,
            fiatValue: 1,
            balanceAtomic: "1000000000",
            sourceAddress: sourceAddress
        )
        return SendDraft(
            request: .manualEntry(
                networkID: SolanaConstants.networkID
            ),
            asset: asset,
            recipient: "11111111111111111111111111111111",
            amount: "1",
            note: nil
        )
    }

    private func solanaTransaction(
        signature: Data
    ) -> String {
        Data([1])
            .appending(signature)
            .appending(Data([0x80, 0x00, 0x00]))
            .base64EncodedString()
    }

    private func solanaBroadcastResponse(
        _ body: String,
        statusCode: Int = 200
    ) async throws -> String {
        try await solanaBroadcastResponse(
            Data(body.utf8),
            statusCode: statusCode
        )
    }

    private func solanaBroadcastResponse(
        _ body: Data,
        statusCode: Int = 200
    ) async throws -> String {
        SolanaBroadcastResponseURLProtocol.install(
            statusCode: statusCode,
            body: body
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [
            SolanaBroadcastResponseURLProtocol.self
        ]
        let session = URLSession(configuration: configuration)
        defer {
            session.invalidateAndCancel()
        }
        let rpc = SendSolanaRPCClient(session: session)
        return try await rpc.broadcast(
            base64Transaction: "AQ=="
        )
    }

    private func account(
        id: String,
        address: String
    ) -> DBWalletAccountRecord {
        DBWalletAccountRecord(
            id: id,
            walletID: "wallet",
            networkID: SolanaConstants.networkID,
            address: address,
            normalizedAddress: address,
            label: nil,
            derivationPath:
                SolanaDerivationKind.phantom.derivationPath,
            accountIndex: 0,
            publicKey: nil,
            isWatchOnly: false,
            isEnabled: true,
            createdAt: 1,
            updatedAt: 1,
            lastSyncedAt: nil
        )
    }
}

private final class SolanaBroadcastResponseURLProtocol:
    URLProtocol,
    @unchecked Sendable
{
    private struct Fixture: Sendable {
        let statusCode: Int
        let body: Data
    }

    private static let fixtureLock = NSLock()
    nonisolated(unsafe) private static var fixture = Fixture(
        statusCode: 500,
        body: Data()
    )
    nonisolated(unsafe) private static var recordedRPCMethod:
        String?

    static func install(
        statusCode: Int,
        body: Data
    ) {
        fixtureLock.lock()
        fixture = Fixture(
            statusCode: statusCode,
            body: body
        )
        recordedRPCMethod = nil
        fixtureLock.unlock()
    }

    static func lastRPCMethod() -> String? {
        fixtureLock.lock()
        defer {
            fixtureLock.unlock()
        }
        return recordedRPCMethod
    }

    override class func canInit(
        with request: URLRequest
    ) -> Bool {
        true
    }

    override class func canonicalRequest(
        for request: URLRequest
    ) -> URLRequest {
        request
    }

    override func startLoading() {
        let currentFixture: Fixture
        Self.fixtureLock.lock()
        if let body = URLRequestBodyReader.data(from: request),
           let object = try? JSONSerialization.jsonObject(
               with: body
           ) as? [String: Any] {
            Self.recordedRPCMethod = object["method"] as? String
        }
        currentFixture = Self.fixture
        Self.fixtureLock.unlock()

        guard let url = request.url,
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: currentFixture.statusCode,
                  httpVersion: "HTTP/1.1",
                  headerFields: [
                      "Content-Type": "application/json"
                  ]
              )
        else {
            client?.urlProtocol(
                self,
                didFailWithError: URLError(.badServerResponse)
            )
            return
        }
        client?.urlProtocol(
            self,
            didReceive: response,
            cacheStoragePolicy: .notAllowed
        )
        client?.urlProtocol(
            self,
            didLoad: currentFixture.body
        )
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private extension Data {
    func appending(_ other: Data) -> Data {
        var result = self
        result.append(other)
        return result
    }
}
