import Foundation
import GRDB
import Testing
@testable import Aperture

@Suite(.serialized)
struct SendTransactionStatusTests {
    @Test
    func receiptHeroEveryStateHasTransactionTitleAndDetail() {
        let englishBundle = WalletAppLanguage.localizedBundle(
            for: WalletAppLanguage.defaultIdentifier
        )
        func english(_ key: String) -> String {
            englishBundle.localizedString(
                forKey: key,
                value: key,
                table: nil
            )
        }

        for heroCopy in SendBroadcastHeroCopy.allCases {
            let title = english(heroCopy.titleKey)
            let detail = english(heroCopy.detailKey)

            #expect(!title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            #expect(!detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            #expect(title != heroCopy.titleKey)
            #expect(detail != heroCopy.detailKey)
        }

        #expect(
            english(SendBroadcastHeroCopy.confirmed.titleKey)
                == "Transaction Confirmed Successfully"
        )
        #expect(
            english(SendBroadcastHeroCopy.warning.titleKey)
                == "Confirmation Still Pending"
        )
    }

    @Test
    func confirmedStatusSuppressesAStaleSubmissionError() {
        #expect(
            !SendBroadcastReceiptPresentation.showsSubmissionError(
                networkStatus: .confirmed
            )
        )
        #expect(
            SendBroadcastReceiptPresentation.showsSubmissionError(
                networkStatus: .pending
            )
        )
        #expect(
            SendBroadcastReceiptPresentation.showsSubmissionError(
                networkStatus: nil
            )
        )
    }

    @Test
    func routeCoversEverySupportedMainnet() throws {
        let evmNetworkIDs = Set(
            SendAddressValidator.evmNetworks.map(\.id)
        )
        let nonEVMNetworkIDs = Set(
            BitcoinFamilyChain.allCases.map(\.networkID) + [
                SolanaConstants.networkID,
                TronConstants.networkID,
                TONConstants.networkID,
                SuiConstants.networkID,
                XRPConstants.networkID,
                NEARConstants.networkID,
                AptosConstants.networkID,
                StellarConstants.networkID
            ]
        )
        #expect(evmNetworkIDs.count == 14)
        #expect(nonEVMNetworkIDs.count == 12)
        #expect(evmNetworkIDs.isDisjoint(with: nonEVMNetworkIDs))

        for networkID in evmNetworkIDs {
            #expect(
                try SendTransactionStatusRoute.resolve(
                    networkID: networkID
                ) == .evm
            )
        }
        for chain in BitcoinFamilyChain.allCases {
            #expect(
                try SendTransactionStatusRoute.resolve(
                    networkID: chain.networkID
                ) == .bitcoinFamily(chain)
            )
        }
        for networkID in nonEVMNetworkIDs.subtracting(
            BitcoinFamilyChain.allCases.map(\.networkID)
        ) {
            _ = try SendTransactionStatusRoute.resolve(
                networkID: networkID
            )
        }
    }

    @Test
    func evmReceiptDistinguishesConfirmedAndFailedExecution() throws {
        let hash = "0x" + String(repeating: "a", count: 64)
        let confirmed = JSONValue.object([
            "transactionHash": .string(hash),
            "blockNumber": .string("0x2a"),
            "status": .string("0x1")
        ])
        let failed = JSONValue.object([
            "transactionHash": .string(hash),
            "blockNumber": .string("0x2a"),
            "status": .string("0x0")
        ])

        #expect(
            try SendEVMRPCClient.transactionStatus(
                from: confirmed,
                expectedHash: hash,
                networkID: "eth"
            ) == .confirmed
        )
        #expect(
            try SendEVMRPCClient.transactionStatus(
                from: failed,
                expectedHash: hash,
                networkID: "eth"
            ) == .failed
        )
    }

    @Test
    func canonicalBase58TransactionIdentifiersPassValidation() {
        #expect(
            SendTransactionStatusValidation.isBase58Hash(
                "3uqECqL29L4SCkKiFNYY1sMFf2Di74fjnTsF9EMt7bmLgWH8DhRw9PzLK62NcUW7e4TaGKCHWejtot3aevXMgPPY",
                byteCount: 64
            )
        )
        #expect(
            SendTransactionStatusValidation.isBase58Hash(
                "Auxh58uWkyeA99yWP6WdJ5tK1UTcJc4nw3GT3Jcw1B2k",
                byteCount: 32
            )
        )
        #expect(
            !SendTransactionStatusValidation.isBase58Hash(
                "not-a-transaction",
                byteCount: 32
            )
        )
    }

    @Test
    func solanaSignatureStatesAreExact() throws {
        let missing = SolanaJSONValue.object([
            "value": .array([.null])
        ])
        let confirmed = SolanaJSONValue.object([
            "value": .array([.object([
                "err": .null,
                "confirmationStatus": .string("finalized")
            ])])
        ])
        let failed = SolanaJSONValue.object([
            "value": .array([.object([
                "err": .object(["InstructionError": .string("1")]),
                "confirmationStatus": .string("finalized")
            ])])
        ])

        #expect(try SolanaTransactionStatusProvider.status(from: missing) == .notFound)
        #expect(try SolanaTransactionStatusProvider.status(from: confirmed) == .confirmed)
        #expect(try SolanaTransactionStatusProvider.status(from: failed) == .failed)
    }

    @Test
    func tronTransactionInfoStatesAreExact() throws {
        let hash = String(repeating: "b", count: 64)
        #expect(
            try TronTransactionStatusProvider.status(
                from: TronTransactionInfoStatus(
                    id: nil,
                    blockNumber: nil,
                    result: nil,
                    receipt: nil
                ),
                expectedHash: hash
            ) == .notFound
        )
        #expect(
            try TronTransactionStatusProvider.status(
                from: TronTransactionInfoStatus(
                    id: hash,
                    blockNumber: 42,
                    result: nil,
                    receipt: .init(result: "SUCCESS")
                ),
                expectedHash: hash
            ) == .confirmed
        )
        #expect(
            try TronTransactionStatusProvider.status(
                from: TronTransactionInfoStatus(
                    id: hash,
                    blockNumber: 42,
                    result: nil,
                    receipt: .init(result: "OUT_OF_ENERGY")
                ),
                expectedHash: hash
            ) == .failed
        )
    }

    @Test(arguments: ["missing", "pending", "wrongIdentity", "infoError", "presenceError", "malformedInfo", "malformedPresence"])
    func tronMissingLookupRequiresSuccessfulEmptyResponses(_ mode: String) async throws {
        let hash = String(repeating: "b", count: 64)
        let transport = TronAPITransport(restBaseURLs: [URL(string: "https://tron-status-\(UUID().uuidString).invalid")!]) { request in
            let info = request.url!.path.contains("gettransactioninfobyid")
            let payload: String
            if (info && mode == "infoError") || (!info && mode == "presenceError") {
                payload = "{\"Error\":\"provider temporarily unavailable\"}"
            } else if (info && mode == "malformedInfo") || (!info && mode == "malformedPresence") {
                payload = "{\"message\":\"unknown response\"}"
            } else if !info && (mode == "pending" || mode == "wrongIdentity") {
                let found = mode == "pending" ? hash : String(repeating: "c", count: 64)
                payload = "{\"txID\":\"\(found)\"}"
            } else { payload = "{}" }
            return (Data(payload.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let provider = TronTransactionStatusProvider(transport: transport)
        if mode == "missing" || mode == "pending" {
            #expect(try await provider.status(transactionHash: hash) == (mode == "missing" ? .notFound : .pending))
        } else {
            await #expect(throws: (any Error).self) { try await provider.status(transactionHash: hash) }
        }
    }

    @Test
    func nearFinalExecutionStatesAreExact() throws {
        let hash = "near-hash"
        func result(
            status: [String: NEARJSONValue],
            finality: String
        ) -> NEARJSONValue {
            .object([
                "transaction": .object(["hash": .string(hash)]),
                "status": .object(status),
                "final_execution_status": .string(finality)
            ])
        }

        #expect(
            try NEARTransactionStatusProvider.status(
                from: result(
                    status: ["SuccessValue": .string("")],
                    finality: "FINAL"
                ),
                expectedHash: hash
            ) == .confirmed
        )
        #expect(
            try NEARTransactionStatusProvider.status(
                from: result(
                    status: ["Failure": .object([:])],
                    finality: "FINAL"
                ),
                expectedHash: hash
            ) == .failed
        )
        #expect(
            try NEARTransactionStatusProvider.status(
                from: result(
                    status: ["SuccessReceiptId": .string("receipt")],
                    finality: "INCLUDED"
                ),
                expectedHash: hash
            ) == .pending
        )
    }

    @Test
    func tonTraceChecksWholeExecutionTree() throws {
        let externalHash = Data(repeating: 7, count: 32)
            .base64EncodedString()
        let confirmed = try Self.tonEnvelope(
            externalHash: externalHash,
            incomplete: false,
            computeSucceeded: true
        )
        let failed = try Self.tonEnvelope(
            externalHash: externalHash,
            incomplete: false,
            computeSucceeded: false
        )
        let pending = try Self.tonEnvelope(
            externalHash: externalHash,
            incomplete: true,
            computeSucceeded: true
        )

        #expect(
            try TONTransactionStatusProvider.status(
                from: confirmed,
                expectedExternalHashBase64: externalHash
            ) == .confirmed
        )
        #expect(
            try TONTransactionStatusProvider.status(
                from: failed,
                expectedExternalHashBase64: externalHash
            ) == .failed
        )
        #expect(
            try TONTransactionStatusProvider.status(
                from: pending,
                expectedExternalHashBase64: externalHash
            ) == .pending
        )
    }

    @Test
    func aptosXRPAndStellarTerminalStatesAreExact() throws {
        let hash = String(repeating: "c", count: 64)
        let aptosHash = "0x\(hash)"
        #expect(
            try AptosAPIClient.transactionStatus(
                from: AptosTransactionStatusResponse(
                    type: "user_transaction",
                    hash: aptosHash,
                    success: true
                ),
                expectedHash: aptosHash
            ) == .confirmed
        )
        #expect(
            try AptosAPIClient.transactionStatus(
                from: AptosTransactionStatusResponse(
                    type: "user_transaction",
                    hash: aptosHash,
                    success: false
                ),
                expectedHash: aptosHash
            ) == .failed
        )

        let xrpResult: [String: XRPJSONValue] = [
            "hash": .string(hash.uppercased()),
            "validated": .boolean(true),
            "meta": .object([
                "TransactionResult": .string("tesSUCCESS")
            ])
        ]
        #expect(
            try XRPAPIClient.transactionStatus(
                from: xrpResult,
                expectedHash: hash
            ) == .confirmed
        )
        var failedXRP = xrpResult
        failedXRP["meta"] = .object([
            "TransactionResult": .string("tecPATH_DRY")
        ])
        #expect(
            try XRPAPIClient.transactionStatus(
                from: failedXRP,
                expectedHash: hash
            ) == .failed
        )

        let stellar = StellarHorizonTransaction(
            hash: hash,
            ledger: 42,
            createdAt: "2026-08-27T00:00:00Z",
            feeCharged: "100",
            successful: true,
            memoType: "none",
            memo: nil,
            sourceAccount: "GTEST",
            sourceAccountSequence: "1"
        )
        #expect(
            try StellarAPIClient.transactionStatus(
                from: stellar,
                expectedHash: hash
            ) == .confirmed
        )
    }

    @Test
    func receiptUsesAssetOnlyForSingleNetworkTokens() throws {
        // Seed representative identities; the runtime catalog may be empty
        // before first sync and must not make receipt behavior tests vacuous.
        let previous = ReceiveAssetCatalogRuntime.snapshot
        defer { ReceiveAssetCatalogRuntime.install(previous.tokens, revision: previous.revision) }
        let contract = "0x0000000000000000000000000000000000000001"
        ReceiveAssetCatalogRuntime.install([
            ReceiveToken(id: "single-fixture", name: "Single", symbol: "SINGLE", rank: 1,
                isStablecoin: false, variants: [ReceiveTokenVariant(networkID: "eth",
                    contractAddress: contract, decimals: 18, networkRank: 1, logoURL: nil)]),
            ReceiveToken(id: "multi-fixture", name: "Multi", symbol: "MULTI", rank: 2,
                isStablecoin: false, variants: ["eth", "base"].map {
                    ReceiveTokenVariant(networkID: $0, contractAddress: "0x0000000000000000000000000000000000000002",
                        decimals: 18, networkRank: 2, logoURL: nil)
                })
        ], revision: 1)
        let single = try #require(
            ReceiveAssetCatalog.tokens.first {
                Set($0.variants.map(\.networkID)).count == 1
            }
        )
        let multi = try #require(
            ReceiveAssetCatalog.tokens.first { token in
                Set(
                    ReceiveAssetCatalog.tokens
                        .filter {
                            $0.name.caseInsensitiveCompare(token.name)
                                == .orderedSame
                                && $0.symbol.caseInsensitiveCompare(
                                    token.symbol
                                ) == .orderedSame
                        }
                        .flatMap { $0.variants.map(\.networkID) }
                ).count > 1
            }
        )
        let singleChoice = try Self.choice(
            token: single,
            variant: #require(single.variants.first)
        )
        let multiChoice = try Self.choice(
            token: multi,
            variant: #require(multi.variants.first)
        )

        #expect(
            !SendBroadcastReceiptPresentation.showsNetworkVariant(
                for: singleChoice
            )
        )
        #expect(
            SendBroadcastReceiptPresentation.showsNetworkVariant(
                for: multiChoice
            )
        )
    }

    @Test
    func terminalStatusUpdatesOnlyTheMatchingPendingReceipt() async throws {
        let database = try WalletDatabase.temporary()
        let asset = SendEntryTestFixtures.ethereum
        _ = try await SendRecipientHistoryTestFixtures.seed(
            database,
            asset: asset
        )
        let receipt = SendRecipientHistoryTestFixtures.receipt(
            asset: asset,
            hash: "0x" + String(repeating: "d", count: 64)
        )
        let recordID = try await database.recordSubmittedSend(
            receipt: receipt,
            draft: SendEntryTestFixtures.draft(
                asset: asset,
                recipient: receipt.toAddress,
                amount: receipt.amount
            ),
            outcome: .accepted
        )

        #expect(
            try await database.updateSubmittedSendStatus(
                receipt: receipt,
                status: .confirmed
            )
        )
        #expect(
            try await database.pool.read {
                try DBTransactionRecord.fetchOne($0, key: recordID)?.status
            } == "confirmed"
        )
        #expect(
            try await !database.updateSubmittedSendStatus(
                receipt: receipt,
                status: .failed
            )
        )
    }

    @Test(arguments: [SendTransactionNetworkStatus.confirmed, .failed])
    func staleHistoryCannotRevertVerifiedTerminalStatus(terminal: SendTransactionNetworkStatus) async throws {
        let database = try WalletDatabase.temporary()
        let asset = SendEntryTestFixtures.ethereum
        _ = try await SendRecipientHistoryTestFixtures.seed(database, asset: asset)
        let receipt = SendRecipientHistoryTestFixtures.receipt(asset: asset,
            hash: "0x" + String(repeating: "e", count: 64))
        let id = try await database.recordSubmittedSend(receipt: receipt,
            draft: SendEntryTestFixtures.draft(asset: asset, recipient: receipt.toAddress, amount: receipt.amount),
            outcome: .accepted)
        _ = try await database.updateSubmittedSendStatus(receipt: receipt, status: terminal)
        // Reproduce an in-flight history snapshot arriving after the exact status read.
        try await database.pool.write { db in
            try db.execute(sql: "UPDATE transactions SET status = 'pending', blockNumber = NULL WHERE id = ?",
                           arguments: [id])
        }
        let status = try await database.pool.read { try DBTransactionRecord.fetchOne($0, key: id)?.status }
        #expect(status == terminal.rawValue)
    }

    @Test
    func confirmedStellarReconciliationPromotesUnknownReceipt() async throws {
        let database = try WalletDatabase.temporary()
        let network = try #require(
            AssetNetworkSelectorOption.allSupported.first {
                $0.id == StellarConstants.networkID
            }
        )
        let asset = try SendEntryTestFixtures.nativeChoice(for: network)
        let scope = try await SendRecipientHistoryTestFixtures.seed(
            database,
            asset: asset
        )
        let recipient = SendEntryTestFixtures.address(
            for: network.blockchain
        )
        let receipt = SendRecipientHistoryTestFixtures.receipt(
            asset: asset,
            hash: String(repeating: "a", count: 64),
            address: recipient
        )
        let draft = SendEntryTestFixtures.draft(
            asset: asset,
            recipient: recipient,
            amount: receipt.amount
        )

        let pendingID = try await database.recordSubmittedSend(
            receipt: receipt,
            draft: draft,
            outcome: .outcomeUnknown
        )
        #expect(
            try await database.sendRecipientHistorySnapshot(
                scope: scope
            ).recentRecipients.isEmpty
        )

        let confirmedID = try await database.recordSubmittedSend(
            receipt: receipt,
            draft: draft,
            outcome: .confirmed
        )
        #expect(confirmedID == pendingID)
        #expect(
            try await database.pool.read {
                try DBTransactionRecord.fetchOne(
                    $0,
                    key: confirmedID
                )?.status
            } == "confirmed"
        )

        _ = try await database.recordSubmittedSend(
            receipt: receipt,
            draft: draft,
            outcome: .confirmed
        )
        let history = try await database.sendRecipientHistorySnapshot(
            scope: scope
        )
        #expect(history.recentRecipients.count == 1)
        #expect(history.recentRecipients.first?.sendCount == 1)
    }

    private static func tonEnvelope(
        externalHash: String,
        incomplete: Bool,
        computeSucceeded: Bool
    ) throws -> TONTraceStatusEnvelope {
        let json = """
        {
          "traces": [{
            "external_hash": "\(externalHash)",
            "is_incomplete": \(incomplete),
            "trace_info": {
              "trace_state": "complete",
              "pending_messages": 0
            },
            "transactions": {
              "tx": {
                "emulated": false,
                "finality": "finalized",
                "description": {
                  "aborted": false,
                  "compute_ph": {"success": \(computeSucceeded)},
                  "action": {"success": true}
                }
              }
            },
            "actions": [{"success": true, "finality": "finalized"}]
          }]
        }
        """
        return try JSONDecoder().decode(
            TONTraceStatusEnvelope.self,
            from: Data(json.utf8)
        )
    }

    private static func choice(
        token: ReceiveToken,
        variant: ReceiveTokenVariant
    ) throws -> SendAssetChoice {
        let network = try #require(variant.network)
        return SendAssetChoice(
            id: variant.assetIdentity,
            name: token.name,
            symbol: token.symbol,
            networkID: variant.networkID,
            networkName: network.localizedName,
            blockchain: network.blockchain,
            contractAddress: variant.contractAddress,
            decimals: variant.decimals,
            logoSource: variant.logoSource,
            networkLogoSource: network.logoSource,
            balance: 1,
            fiatValue: 1
        )
    }
}
