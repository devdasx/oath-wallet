import Foundation
import Testing
import WalletCore
@testable import Aperture

struct SendBitcoinCoinControlTests {
    @Test
    func HTTPBroadcastClassifierKeepsProviderFailuresAmbiguous() {
        #expect(SendBitcoinFamilyHTTPAPIClient.isDefinitiveRejectionMessage(
            "mandatory-script-verify-flag-failed"
        ))
        #expect(!SendBitcoinFamilyHTTPAPIClient.isDefinitiveRejectionMessage(
            "internal server error"
        ))
        #expect(!SendBitcoinFamilyHTTPAPIClient.isDefinitiveRejectionMessage(
            "server overloaded"
        ))
        #expect(!SendBitcoinFamilyHTTPAPIClient.isDefinitiveRejectionMessage(
            "txn-mempool-conflict"
        ))
        #expect(!SendBitcoinFamilyHTTPAPIClient.isDefinitiveRejectionMessage(
            "missing inputs"
        ))
        #expect(!SendBitcoinFamilyHTTPAPIClient.isDefinitiveRejectionMessage(
            "inputs missing or spent"
        ))
        #expect(SendBitcoinFamilyHTTPAPIClient.isDefinitiveRejectionMessage(
            "min relay fee not met"
        ))
    }

    @Test
    func replaceByFeeSupportMatchesMainnetNodePolicies() {
        #expect(BitcoinFamilyChain.bitcoin.supportsReplaceByFee)
        #expect(BitcoinFamilyChain.litecoin.supportsReplaceByFee)
        #expect(BitcoinFamilyChain.dogecoin.supportsReplaceByFee)
        #expect(!BitcoinFamilyChain.bitcoinCash.supportsReplaceByFee)
    }

    @Test(arguments: BitcoinFamilyChain.allCases)
    func replaceByFeeDraftOptionEnablesOnlyWhenSupportedAndAlwaysDisables(
        chain: BitcoinFamilyChain
    ) {
        let enabled = SendBitcoinFamilyOptions.automatic
            .replacingReplaceByFee(true, chain: chain)
        #expect(enabled.replaceByFee == chain.supportsReplaceByFee)

        let disabled = enabled.replacingReplaceByFee(
            false,
            chain: chain
        )
        #expect(!disabled.replaceByFee)
        #expect(disabled.coinSelection == .automatic)
    }

    @Test(arguments: BitcoinFamilyChain.allCases)
    func transactionControlsTitleUsesSelectedChain(
        chain: BitcoinFamilyChain
    ) {
        #expect(chain.transactionControlsTitle.contains(chain.name))
    }

    @Test
    func inputSequencesOptInOnlyOnSupportedChains() throws {
        let requested = SendBitcoinFamilyOptions(
            coinSelection: .automatic,
            replaceByFee: true
        )

        #expect(
            requested.inputSequence(for: .bitcoin) == 0xffff_fffd
        )
        #expect(
            requested.inputSequence(for: .litecoin) == 0xffff_fffd
        )
        #expect(
            requested.inputSequence(for: .dogecoin) == 0xffff_fffd
        )
        #expect(
            requested.inputSequence(for: .bitcoinCash)
                == 0xffff_fffe
        )
        #expect(
            try requested.normalized(for: .bitcoinCash).replaceByFee
                == false
        )
    }

    @Test
    func automaticSelectionIsTheDefault() {
        #expect(
            SendBitcoinFamilyOptions.automatic.coinSelection
                == .automatic
        )
        #expect(!SendBitcoinFamilyOptions.automatic.replaceByFee)
        #expect(SendBitcoinFamilyOptions.automatic.opReturnMessage == nil)
    }

    @Test(arguments: BitcoinFamilyChain.allCases)
    func outputPresentationShowsLocalThenNativeForEveryUTXOChain(
        chain: BitcoinFamilyChain
    ) throws {
        let hash = String(repeating: "a", count: 64)
        let output = Self.output(
            hash: hash,
            index: 2,
            value: "125000",
            networkID: chain.networkID
        )
        let asset = SendAssetChoice(
            id: AssetIdentityKey.make(
                networkID: chain.networkID,
                contractAddress: nil
            ),
            name: chain.name,
            symbol: chain.symbol,
            networkID: chain.networkID,
            networkName: chain.name,
            blockchain: chain.blockchain,
            contractAddress: nil,
            decimals: 8,
            logoSource: .nativeCoin(blockchain: chain.blockchain),
            networkLogoSource: .network(
                blockchain: chain.blockchain
            ),
            balance: 1,
            fiatValue: 200,
            balanceAtomic: "100000000"
        )
        let currency = WalletCurrencyContext(
            code: "USD",
            ratePerUSD: 1
        )
        let presentation = SendBitcoinCoinControlOutputPresentation(
            output: output,
            asset: asset,
            unitUSDPrice: 200,
            currency: currency
        )

        #expect(
            presentation.localAmount
                == EnglishNumbers.currency(
                    Decimal(string: "0.25")!,
                    using: currency
                )
        )
        #expect(
            presentation.nativeAmount
                == EnglishNumbers.localized(
                    "wallet.format.asset_amount",
                    "0.00125",
                    chain.symbol
                )
        )
        #expect(
            presentation.confirmation
                == EnglishNumbers.localized(
                    "send.coin_control.confirmations",
                    1
                )
        )
        #expect(!presentation.localAmount.contains(hash))
        #expect(!presentation.nativeAmount.contains(hash))
        #expect(!presentation.confirmation.contains(hash))
    }

    @Test
    func outputPresentationFormatsMissingFiatValueAsZero() {
        let chain = BitcoinFamilyChain.bitcoin
        let output = Self.output(
            hash: String(repeating: "b", count: 64),
            index: 0,
            value: "100000000",
            networkID: chain.networkID
        )
        let asset = SendAssetChoice(
            id: AssetIdentityKey.make(
                networkID: chain.networkID,
                contractAddress: nil
            ),
            name: chain.name,
            symbol: chain.symbol,
            networkID: chain.networkID,
            networkName: chain.name,
            blockchain: chain.blockchain,
            contractAddress: nil,
            decimals: 8,
            logoSource: .nativeCoin(blockchain: chain.blockchain),
            networkLogoSource: .network(
                blockchain: chain.blockchain
            ),
            balance: 1,
            fiatValue: 0,
            balanceAtomic: "100000000"
        )
        let presentation = SendBitcoinCoinControlOutputPresentation(
            output: output,
            asset: asset,
            unitUSDPrice: nil,
            currency: WalletCurrencyContext(
                code: "USD",
                ratePerUSD: 1
            )
        )

        #expect(presentation.localAmount == "$0.00")
        #expect(presentation.nativeAmount.contains(chain.symbol))
    }

    @Test
    func manualSelectionRejectsDuplicatesAndWrongNetworks() {
        let output = Self.output(
            hash: String(repeating: "a", count: 64),
            index: 1,
            value: "50000",
            networkID: "bitcoin"
        )
        let duplicate = SendBitcoinFamilyOptions(
            coinSelection: .manual([output, output]),
            replaceByFee: false
        )
        #expect(
            throws: SendBitcoinFamilyOptionsError.duplicateOutput
        ) {
            try duplicate.normalized(for: .bitcoin)
        }

        let wrongNetwork = SendBitcoinFamilyOptions(
            coinSelection: .manual([
                Self.output(
                    hash: String(repeating: "b", count: 64),
                    index: 0,
                    value: "1000",
                    networkID: "litecoin"
                )
            ]),
            replaceByFee: false
        )
        #expect(
            throws: SendBitcoinFamilyOptionsError.invalidOutput
        ) {
            try wrongNetwork.normalized(for: .bitcoin)
        }
    }

    @Test
    func atomicAmountMathIsLosslessBeyondFloatingPointRange() {
        let sum = SendBitcoinAtomicAmount.sum([
            "9007199254740993",
            "7",
            "100000000000000000000"
        ])
        #expect(sum == "100009007199254741000")
        #expect(
            SendBitcoinAtomicAmount.compare(
                sum,
                "100009007199254740999"
            ) == .orderedDescending
        )
    }

    @Test
    func electrumParserValidatesSortsAndCountsConfirmations()
        throws
    {
        let firstHash = String(repeating: "1", count: 64)
        let secondHash = String(repeating: "2", count: 64)
        let outputs = JSONValue.array([
            .object([
                "tx_hash": .string(firstHash),
                "tx_pos": .number(Decimal(2)),
                "value": .number(Decimal(12_500)),
                "height": .number(Decimal(100))
            ]),
            .object([
                "tx_hash": .string(secondHash),
                "tx_pos": .number(Decimal(0)),
                "value": .number(Decimal(50_000)),
                "height": .number(Decimal(0))
            ])
        ])
        let tip = JSONValue.object([
            "height": .number(Decimal(110))
        ])

        let parsed = try SendBitcoinUTXORepository.parse(
            outputs: outputs,
            tip: tip,
            chain: .bitcoin
        )

        #expect(parsed.count == 2)
        #expect(parsed[0].outpoint.transactionHash == firstHash)
        #expect(parsed[0].confirmations == 11)
        #expect(parsed[0].valueAtomic == "12500")
        #expect(parsed[1].confirmations == 0)
    }

    @Test
    func electrumParserRejectsFractionalOrDuplicateOutputs() {
        let hash = String(repeating: "3", count: 64)
        let fractional = JSONValue.array([
            .object([
                "tx_hash": .string(hash),
                "tx_pos": .number(Decimal(0)),
                "value": .number(Decimal(string: "1.5")!),
                "height": .number(Decimal(1))
            ])
        ])
        let tip = JSONValue.object([
            "height": .number(Decimal(5))
        ])
        #expect(throws: SendBitcoinUTXORepositoryError.self) {
            try SendBitcoinUTXORepository.parse(
                outputs: fractional,
                tip: tip,
                chain: .bitcoin
            )
        }

        let item = JSONValue.object([
            "tx_hash": .string(hash),
            "tx_pos": .number(Decimal(0)),
            "value": .number(Decimal(1)),
            "height": .number(Decimal(1))
        ])
        #expect(throws: SendBitcoinUTXORepositoryError.self) {
            try SendBitcoinUTXORepository.parse(
                outputs: .array([item, item]),
                tip: tip,
                chain: .bitcoin
            )
        }
    }

    @Test
    func electrumParserAcceptsMaximumWireOutputIndex() throws {
        let hash = String(repeating: "4", count: 64)
        let outputs = try JSONDecoder().decode(
            JSONValue.self,
            from: Data(
                """
                [{
                  "tx_hash": "\(hash)",
                  "tx_pos": 4294967295,
                  "value": 1,
                  "height": 1
                }]
                """.utf8
            )
        )

        let parsed = try SendBitcoinUTXORepository.parse(
            outputs: outputs,
            tip: .object(["height": .number(Decimal(1))]),
            chain: .bitcoin
        )

        #expect(parsed.count == 1)
        #expect(parsed[0].outpoint.outputIndex == Int(UInt32.max))
        #expect(parsed[0].outpoint.wireOutputIndex == UInt32.max)
    }

    @Test(
        arguments: [
            Int64(-1),
            Int64(UInt32.max) + 1
        ]
    )
    func electrumParserRejectsOutputIndexesOutsideWireRange(
        outputIndex: Int64
    ) {
        let hash = String(repeating: "5", count: 64)
        let outputs = JSONValue.array([
            .object([
                "tx_hash": .string(hash),
                "tx_pos": .number(Decimal(outputIndex)),
                "value": .number(Decimal(1)),
                "height": .number(Decimal(1))
            ])
        ])

        #expect(
            throws: SendBitcoinUTXORepositoryError
                .invalidResponse("output_index_range")
        ) {
            try SendBitcoinUTXORepository.parse(
                outputs: outputs,
                tip: .object(["height": .number(Decimal(1))]),
                chain: .bitcoin
            )
        }
    }

    @Test
    func transactionConstructionConvertsOutputIndexWithoutTrap()
        throws
    {
        #expect(
            try SendBitcoinTransactionService.checkedWireOutputIndex(
                Int(UInt32.max),
                networkID: BitcoinFamilyChain.bitcoin.networkID
            ) == UInt32.max
        )

        for invalidIndex in [-1, Int(UInt32.max) + 1] {
            do {
                _ = try SendBitcoinTransactionService
                    .checkedWireOutputIndex(
                        invalidIndex,
                        networkID: BitcoinFamilyChain.bitcoin.networkID
                    )
                Issue.record(
                    "An invalid Bitcoin output index was accepted"
                )
            } catch let error as SendTransactionSubmissionError {
                #expect(
                    error.diagnosticCode
                        == "signing_invalid_utxo_output_index"
                )
            } catch {
                Issue.record(
                    "Unexpected output-index error: \(type(of: error))"
                )
            }
        }
    }

    @Test
    func bitcoinCashListUnspentExcludesTokenBearingOutputs()
        throws
    {
        let request = ElectrumRequest(
            id: 1,
            method: "blockchain.scripthash.listunspent",
            params: SendBitcoinUTXORepository
                .listUnspentParameters(
                    chain: .bitcoinCash,
                    scriptHash: "fixture"
                )
        )
        let data = try JSONEncoder().encode(request)
        let object = try #require(
            JSONSerialization.jsonObject(with: data)
                as? [String: Any]
        )
        let params = try #require(object["params"] as? [String])
        #expect(params == ["fixture", "exclude_tokens"])
    }

    @Test
    func explicitMaximumIntentUsesExactAtomicBalanceAcrossRoutes()
        throws
    {
        let recipient = "LT2KVaAy1ppRuxRgrS5RNU3vBsy7RibPeA"
        let asset = Self.asset(
            networkID: BitcoinFamilyChain.litecoin.networkID,
            blockchain: .litecoin,
            balance: "0.11268874",
            balanceAtomic: "11268875"
        )
        #expect(
            SendMaximumBalanceIntent.exactBalanceUserUnits(
                for: asset
            ) == "0.11268875"
        )

        let draft = SendDraft(
            request: .manualEntry(networkID: asset.networkID),
            asset: asset,
            recipient: recipient,
            amount: "0.11268875",
            note: nil,
            usesMaximumBalance: true
        )
        #expect(draft.usesMaximumBalance)

        let reviewed = try SendFlowPlanner.reviewDraft(
            from: draft,
            recipient: recipient,
            amount: "0.11268875",
            note: nil
        ).get()
        #expect(reviewed.usesMaximumBalance)

        let request = try SendPaymentRequestParser.parse(
            "litecoin:\(recipient)?amount=0.11268875"
        )
        let route = try SendFlowPlanner.route(
            afterSelecting: asset,
            for: request
        )
        guard case let .review(scannedDraft) = route else {
            Issue.record("A valid full-balance request did not reach Review")
            return
        }
        #expect(!scannedDraft.usesMaximumBalance)
    }

    @Test
    func rankedUTXOReadRejectsStalePartialSetAndPrefersFundedSet()
        throws
    {
        let minimum = try BitcoinFamilyAtomicInteger(
            validating: "22699953"
        )
        let low = try SendBitcoinUTXORepository.readRating(
            outputs: Self.electrumOutputs([
                (String(repeating: "a", count: 64), 0, 11_268_875)
            ]),
            chain: .litecoin,
            minimumExpectedValue: minimum,
            requiredOutpointIDs: []
        )
        let funded = try SendBitcoinUTXORepository.readRating(
            outputs: Self.electrumOutputs([
                (String(repeating: "a", count: 64), 0, 11_268_875),
                (String(repeating: "b", count: 64), 1, 11_431_078)
            ]),
            chain: .litecoin,
            minimumExpectedValue: minimum,
            requiredOutpointIDs: []
        )

        #expect(!low.satisfiesRequirement)
        #expect(low.availableValue.decimalText == "11268875")
        #expect(funded.satisfiesRequirement)
        #expect(funded.availableValue.decimalText == "22699953")
        #expect(funded.isPreferred(over: low))
    }

    @Test
    func liveUTXOsRemainSpendableWhenCachedBalanceIsPreBroadcast()
        throws
    {
        let staleCachedBalance: Int64 = 22_699_953
        let livePostBroadcastBalance: Int64 = 11_268_875
        let requested: Int64 = 5_000_000
        let asset = Self.asset(
            networkID: BitcoinFamilyChain.litecoin.networkID,
            blockchain: .litecoin,
            balance: "0.22699953",
            balanceAtomic: String(staleCachedBalance)
        )
        let draft = SendDraft(
            request: .manualEntry(networkID: asset.networkID),
            asset: asset,
            recipient:
                "ltc1q0dvup9kzplv6yulzgzzxkge8d35axkq4n45hum",
            amount: "0.05",
            note: nil
        )
        let rawOutputs = Self.electrumOutputs([
            (
                String(repeating: "9", count: 64),
                0,
                livePostBroadcastBalance
            )
        ])
        let rating = try SendBitcoinUTXORepository.readRating(
            outputs: rawOutputs,
            chain: .litecoin,
            minimumExpectedValue: BitcoinFamilyAtomicInteger(
                staleCachedBalance
            ),
            requiredOutpointIDs: []
        )
        #expect(!rating.satisfiesRequirement)
        #expect(
            rating.availableValue.decimalText
                == String(livePostBroadcastBalance)
        )

        let input = try SendBitcoinTransactionService.signingInput(
            draft: draft,
            accountMarker: nil,
            nestedSegwitPublicKey: nil,
            chain: .litecoin,
            outputs: [
                Self.output(
                    hash: String(repeating: "9", count: 64),
                    index: 0,
                    value: String(livePostBroadcastBalance),
                    networkID: asset.networkID
                )
            ],
            requestedAtomic: requested,
            byteFee: 2,
            options: .automatic,
            senderAddress:
                "ltc1qt36tu30tgk35tyzsve6jjq3dnhu2rm8l8v5q00",
            recipientAddress: draft.recipient
        )
        let plan: BitcoinTransactionPlan = AnySigner.plan(
            input: input,
            coin: .litecoin
        )

        #expect(plan.error == .ok)
        #expect(plan.amount == requested)
        #expect(plan.fee > 0)
        #expect(plan.change > 0)
    }

    @Test
    func rankedUTXOReadRequiresEveryManualOutpoint() throws {
        let firstHash = String(repeating: "c", count: 64)
        let secondHash = String(repeating: "d", count: 64)
        let required = Set([
            "\(firstHash):0",
            "\(secondHash):1"
        ])
        let partial = try SendBitcoinUTXORepository.readRating(
            outputs: Self.electrumOutputs([
                (firstHash, 0, 20_000_000)
            ]),
            chain: .litecoin,
            minimumExpectedValue: try BitcoinFamilyAtomicInteger(
                validating: "10000000"
            ),
            requiredOutpointIDs: required
        )
        let complete = try SendBitcoinUTXORepository.readRating(
            outputs: Self.electrumOutputs([
                (firstHash, 0, 20_000_000),
                (secondHash, 1, 1_000_000)
            ]),
            chain: .litecoin,
            minimumExpectedValue: try BitcoinFamilyAtomicInteger(
                validating: "10000000"
            ),
            requiredOutpointIDs: required
        )

        #expect(!partial.satisfiesRequirement)
        #expect(partial.requiredMatchCount == 1)
        #expect(complete.satisfiesRequirement)
        #expect(complete.requiredMatchCount == 2)
        #expect(complete.isPreferred(over: partial))
    }

    @Test
    func repositoryErrorTypeIsOneSanitizedCodeNotACharacterArray() {
        let code = SendBitcoinUTXORepository.errorTypeCode(
            BitcoinSilentPaymentScanError.invalidResponse
        )

        #expect(code.contains("bitcoinsilentpaymentscanerror"))
        #expect(!code.contains("["))
        #expect(!code.contains("]"))
        #expect(!code.contains("\""))
        #expect(!code.contains(","))
    }

    @Test
    func litecoinPartialBalancePlanUsesFundedUTXOSet() throws {
        let sender =
            "ltc1qt36tu30tgk35tyzsve6jjq3dnhu2rm8l8v5q00"
        let recipient =
            "ltc1q0dvup9kzplv6yulzgzzxkge8d35axkq4n45hum"
        let available: Int64 = 22_699_953
        let requested: Int64 = 11_268_875
        let asset = Self.asset(
            networkID: BitcoinFamilyChain.litecoin.networkID,
            blockchain: .litecoin,
            balance: "0.22699953",
            balanceAtomic: String(available)
        )
        let draft = SendDraft(
            request: .manualEntry(networkID: asset.networkID),
            asset: asset,
            recipient: recipient,
            amount: "0.11268875",
            note: nil
        )
        #expect(
            SendBitcoinTransactionService.minimumExpectedUTXOValue(
                draft: draft,
                requestedAtomic: String(requested)
            ) == String(available)
        )
        let input = try SendBitcoinTransactionService.signingInput(
            draft: draft,
            accountMarker: nil,
            nestedSegwitPublicKey: nil,
            chain: .litecoin,
            outputs: [
                Self.output(
                    hash: String(repeating: "e", count: 64),
                    index: 0,
                    value: String(available),
                    networkID: asset.networkID
                )
            ],
            requestedAtomic: requested,
            byteFee: 2,
            options: .automatic,
            senderAddress: sender,
            recipientAddress: recipient
        )
        #expect(!input.useMaxAmount)

        let plan: BitcoinTransactionPlan = AnySigner.plan(
            input: input,
            coin: .litecoin
        )
        #expect(plan.error == .ok)
        #expect(plan.amount == requested)
        #expect(plan.fee > 0)
        #expect(plan.change > 0)
    }

    @Test
    func litecoinFullBalancePlanSubtractsFeeInsteadOfFailing()
        throws
    {
        let sender =
            "ltc1qt36tu30tgk35tyzsve6jjq3dnhu2rm8l8v5q00"
        let recipient =
            "ltc1q0dvup9kzplv6yulzgzzxkge8d35axkq4n45hum"
        let available: Int64 = 11_268_875
        let asset = Self.asset(
            networkID: BitcoinFamilyChain.litecoin.networkID,
            blockchain: .litecoin,
            balance: "0.11268875",
            balanceAtomic: String(available)
        )
        let draft = SendDraft(
            request: .manualEntry(networkID: asset.networkID),
            asset: asset,
            recipient: recipient,
            amount: "0.11268875",
            note: nil,
            usesMaximumBalance: true
        )
        let input = try SendBitcoinTransactionService.signingInput(
            draft: draft,
            accountMarker: nil,
            nestedSegwitPublicKey: nil,
            chain: .litecoin,
            outputs: [
                Self.output(
                    hash: String(repeating: "a", count: 64),
                    index: 0,
                    value: String(available),
                    networkID: asset.networkID
                )
            ],
            requestedAtomic: available,
            byteFee: 2,
            options: .automatic,
            senderAddress: sender,
            recipientAddress: recipient
        )
        #expect(input.useMaxAmount)

        let plan: BitcoinTransactionPlan = AnySigner.plan(
            input: input,
            coin: .litecoin
        )
        #expect(plan.error == .ok)
        #expect(plan.availableAmount == available)
        #expect(plan.amount > 0)
        #expect(plan.fee > 0)
        #expect(plan.amount + plan.fee == available)
        #expect(plan.change == 0)
    }

    @Test(arguments: BitcoinFamilyChain.allCases)
    func everyBitcoinFamilyMaxPlanSubtractsFee(
        chain: BitcoinFamilyChain
    ) throws {
        let sourceKey = try #require(
            PrivateKey(
                data: Data(repeating: 0x11, count: 32)
            )
        )
        let recipientKey = try #require(
            PrivateKey(
                data: Data(repeating: 0x22, count: 32)
            )
        )
        let senderAddress = chain.coin.deriveAddress(
            privateKey: sourceKey
        )
        let recipientAddress = chain.coin.deriveAddress(
            privateKey: recipientKey
        )
        let available: Int64 = 200_000_000
        let asset = Self.asset(
            networkID: chain.networkID,
            blockchain: chain.blockchain,
            balance: "2",
            balanceAtomic: String(available)
        )
        let draft = SendDraft(
            request: .manualEntry(networkID: chain.networkID),
            asset: asset,
            recipient: recipientAddress,
            amount: "2",
            note: nil,
            usesMaximumBalance: true
        )
        let byteFee: Int64 = chain == .dogecoin ? 1_000 : 2
        let input = try SendBitcoinTransactionService.signingInput(
            draft: draft,
            accountMarker: nil,
            nestedSegwitPublicKey: nil,
            chain: chain,
            outputs: [
                Self.output(
                    hash: String(repeating: "f", count: 64),
                    index: 0,
                    value: String(available),
                    networkID: chain.networkID
                )
            ],
            requestedAtomic: available,
            byteFee: byteFee,
            options: .automatic,
            senderAddress: senderAddress,
            recipientAddress: recipientAddress
        )

        let plan: BitcoinTransactionPlan = AnySigner.plan(
            input: input,
            coin: chain.coin
        )

        #expect(plan.error == .ok)
        #expect(plan.amount > 0)
        #expect(plan.fee > 0)
        #expect(plan.amount + plan.fee == available)
        #expect(plan.change == 0)
    }

    private static func output(
        hash: String,
        index: Int,
        value: String,
        networkID: String
    ) -> SendBitcoinUTXO {
        SendBitcoinUTXO(
            networkID: networkID,
            outpoint: SendBitcoinOutpoint(
                transactionHash: hash,
                outputIndex: index
            ),
            valueAtomic: value,
            blockHeight: 1,
            confirmations: 1
        )
    }

    private static func electrumOutputs(
        _ fixtures: [(hash: String, index: Int64, value: Int64)]
    ) -> JSONValue {
        .array(fixtures.map { fixture in
            .object([
                "tx_hash": .string(fixture.hash),
                "tx_pos": .number(Decimal(fixture.index)),
                "value": .number(Decimal(fixture.value)),
                "height": .number(Decimal(1))
            ])
        })
    }

    private static func asset(
        networkID: String,
        blockchain: WalletBlockchain,
        balance: String,
        balanceAtomic: String,
        contractAddress: String? = nil,
        decimals: Int = 8
    ) -> SendAssetChoice {
        SendAssetChoice(
            id: AssetIdentityKey.make(
                networkID: networkID,
                contractAddress: contractAddress
            ),
            name: "Fixture",
            symbol: contractAddress == nil ? "LTC" : "TOKEN",
            networkID: networkID,
            networkName: "Fixture",
            blockchain: blockchain,
            contractAddress: contractAddress,
            decimals: decimals,
            logoSource: contractAddress == nil
                ? .nativeCoin(blockchain: blockchain)
                : .unavailable,
            networkLogoSource: .network(blockchain: blockchain),
            balance: Decimal(
                string: balance,
                locale: Locale(identifier: "en_US_POSIX")
            )!,
            fiatValue: 0,
            balanceAtomic: balanceAtomic
        )
    }
}
