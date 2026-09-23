import Foundation
import Testing
import WalletCore
@testable import Aperture

struct SendPaymentRequestParserTests {
    private let evmRecipient =
        "0x71C7656EC7ab88b098defB751B7401B5f6d8976F"
    private let polygonUSDC =
        "0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174"
    private let solanaRecipient =
        "mvines9iiHiQTysrwkJjGf2gb9Ex9jXJX8ns3qwf2kN"
    private let solanaUSDC =
        "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v"

    @Test
    func bitcoinPaymentURIResolvesNativeCoinAmountAndMetadata()
        throws
    {
        let request = try SendPaymentRequestParser.parse(
            """
            bitcoin:1BoatSLRHtKNngkdXEeobR76b53LETtpyT\
            ?amount=0.00125000&label=Coffee%20Shop&message=Invoice%2042
            """
        )

        #expect(request.source == .bitcoinURI)
        #expect(request.recipient == "1BoatSLRHtKNngkdXEeobR76b53LETtpyT")
        #expect(request.candidateNetworkIDs == ["bitcoin"])
        #expect(request.requestedNetworkID == "bitcoin")
        #expect(request.requestedAsset == .native)
        #expect(request.requestedAmount == .userUnits("0.00125"))
        #expect(request.label == "Coffee Shop")
        #expect(request.message == "Invoice 42")
    }

    @Test
    func bitcoinRequiredAmountVariantIsHonored() throws {
        let request = try SendPaymentRequestParser.parse(
            """
            bitcoin:1BoatSLRHtKNngkdXEeobR76b53LETtpyT\
            ?req-amount=0.25
            """
        )

        #expect(request.requestedAmount == .userUnits("0.25"))
    }

    @Test
    func duplicateNormalAndRequiredAmountsAreRejected() {
        #expect(throws: SendPaymentRequestError.duplicateParameter) {
            try SendPaymentRequestParser.parse(
                """
                bitcoin:1BoatSLRHtKNngkdXEeobR76b53LETtpyT\
                ?amount=1&req-amount=1
                """
            )
        }
    }

    @Test
    func bitcoinAddressFamiliesAreValidatedByWalletCore() throws {
        let mainnetAddresses = [
            "1BoatSLRHtKNngkdXEeobR76b53LETtpyT",
            "3CMNFxN1oHBc4R1EpboAL5yzHGgE611Xou",
            "bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4",
            """
            bc1p0xlxvlhemja6c4dqv22uapctqupfhlxm9h8z3k2e72q4k9hcz7\
            vqzk5jj0
            """
        ]

        for address in mainnetAddresses {
            let request = try SendPaymentRequestParser.parse(address)
            #expect(
                request.candidateNetworkIDs.contains(
                    BitcoinFamilyChain.bitcoin.networkID
                )
            )
        }
    }

    @Test
    func eachBitcoinFamilySchemePinsItsMainnet() throws {
        let fixtures = [
            (
                payload:
                    "litecoin:LT2KVaAy1ppRuxRgrS5RNU3vBsy7RibPeA?amount=2",
                source: SendPaymentRequestSource.litecoinURI,
                networkID: BitcoinFamilyChain.litecoin.networkID
            ),
            (
                payload:
                    "dogecoin:DD4KSSuBJqcjuTcvUg1CgUKeurPUFeEZkE?amount=3",
                source: SendPaymentRequestSource.dogecoinURI,
                networkID: BitcoinFamilyChain.dogecoin.networkID
            ),
            (
                payload:
                    """
                    bitcoincash:qpm2qsznhks23z7629mms6s4cwef74vcw\
                    vy22gdx6a?amount=4
                    """,
                source: SendPaymentRequestSource.bitcoinCashURI,
                networkID: BitcoinFamilyChain.bitcoinCash.networkID
            )
        ]

        for fixture in fixtures {
            let request = try SendPaymentRequestParser.parse(
                fixture.payload
            )
            #expect(request.source == fixture.source)
            #expect(request.candidateNetworkIDs == [fixture.networkID])
            #expect(request.requestedAsset == .native)
        }
    }

    @Test
    func ethereumNativePaymentResolvesPolygonAndAtomicValue() throws {
        let request = try SendPaymentRequestParser.parse(
            "ethereum:\(evmRecipient)@137?value=1e18"
        )

        #expect(request.source == .ethereumURI)
        #expect(request.recipient == evmRecipient)
        #expect(request.requestedNetworkID == "polygon")
        #expect(request.candidateNetworkIDs == ["polygon"])
        #expect(request.requestedAsset == .native)
        #expect(
            request.requestedAmount
                == .atomicUnits("1000000000000000000")
        )
    }

    @Test
    func ethereumERC20TransferResolvesContractRecipientAndAmount()
        throws
    {
        let request = try SendPaymentRequestParser.parse(
            """
            ethereum:\(polygonUSDC)@137/transfer\
            ?address=\(evmRecipient)&uint256=1250000
            """
        )

        #expect(request.recipient == evmRecipient)
        #expect(request.requestedNetworkID == "polygon")
        #expect(request.requestedAsset == .contract(polygonUSDC))
        #expect(request.requestedAmount == .atomicUnits("1250000"))
    }

    @Test
    func bareEVMAddressRemainsNetworkAmbiguous() throws {
        let request = try SendPaymentRequestParser.parse(evmRecipient)

        #expect(request.source == .bareAddress)
        #expect(request.requestedNetworkID == nil)
        #expect(request.requestedAsset == .unspecified)
        #expect(request.candidateNetworkIDs.count > 1)
        #expect(request.candidateNetworkIDs.contains("eth"))
        #expect(request.candidateNetworkIDs.contains("polygon"))
    }

    @Test
    func solanaPayTransferResolvesMintAndUserUnitAmount() throws {
        let request = try SendPaymentRequestParser.parse(
            """
            solana:\(solanaRecipient)?amount=1.25\
            &spl-token=\(solanaUSDC)&label=Store&memo=order-42
            """
        )

        #expect(request.source == .solanaPayURI)
        #expect(request.recipient == solanaRecipient)
        #expect(request.candidateNetworkIDs == ["solana"])
        #expect(request.requestedAsset == .contract(solanaUSDC))
        #expect(request.requestedAmount == .userUnits("1.25"))
        #expect(request.label == "Store")
        #expect(request.memo == "order-42")
    }

    @Test
    func solanaInteractiveTransactionRequestIsRejected() {
        #expect(
            throws:
                SendPaymentRequestError.unsupportedInteractiveRequest
        ) {
            try SendPaymentRequestParser.parse(
                "solana:https%3A%2F%2Fmerchant.example%2Ftransaction"
            )
        }
    }

    @Test
    func tronPaymentURIResolvesNativeAmount() throws {
        let request = try SendPaymentRequestParser.parse(
            "tron:TNPeeaaFB7K9cmo4uQpcU32zGK8G1NYqeL?amount=2.5"
        )

        #expect(request.source == .tronURI)
        #expect(request.candidateNetworkIDs == ["tron"])
        #expect(request.requestedAsset == .native)
        #expect(request.requestedAmount == .userUnits("2.5"))
    }

    @Test
    func testnetAndMalformedPayloadsAreRejected() {
        #expect(
            throws: SendPaymentRequestError.invalidMainnetAddress
        ) {
            try SendPaymentRequestParser.parse(
                "bitcoin:tb1qw508d6qejxtdg4y5r3zarvary0c5xw7kxpjzsx"
            )
        }
        #expect(throws: SendPaymentRequestError.unsupportedNetwork) {
            try SendPaymentRequestParser.parse(
                "ethereum:\(evmRecipient)@11155111?value=1"
            )
        }
        #expect(
            throws:
                SendPaymentRequestError.unsupportedRequiredParameter
        ) {
            try SendPaymentRequestParser.parse(
                """
                bitcoin:1BoatSLRHtKNngkdXEeobR76b53LETtpyT\
                ?req-unknown=1
                """
            )
        }
        #expect(throws: SendPaymentRequestError.invalidAmount) {
            try SendPaymentRequestParser.parse(
                """
                bitcoin:1BoatSLRHtKNngkdXEeobR76b53LETtpyT\
                ?amount=١
                """
            )
        }
    }

    @Test
    func exactDecimalUtilitiesPreserveValuesWithoutFloatingPoint()
        throws
    {
        let parsed = try SendDecimalAmount.parseUserUnits(
            "00042.1200"
        )

        #expect(parsed.canonical == "42.12")
        #expect(
            try SendDecimalAmount.parseUInt256Expression("1.25e6")
                == "1250000"
        )
        #expect(
            try SendDecimalAmount.parseUInt256Expression("+1e18")
                == "1000000000000000000"
        )
        #expect(throws: SendPaymentRequestError.invalidAmount) {
            try SendDecimalAmount.parseUInt256Expression("10e-1")
        }
        #expect(
            SendDecimalAmount.userUnits(
                fromAtomicUnits: "1250000",
                decimals: 6
            ) == "1.25"
        )
        #expect(
            SendDecimalAmount.compare(
                "999999999999999999999.9",
                "1000000000000000000000"
            ) == .orderedAscending
        )
        #expect(
            !SendDecimalAmount.acceptsEditableInput(
                "١.٢",
                maximumFractionDigits: 6
            )
        )
        #expect(
            SendDecimalAmount.normalizedDecimalKeyboardInput(
                "12,50",
                decimalSeparator: ","
            ) == "12.50"
        )
        #expect(
            SendDecimalAmount.acceptsEditableInput(
                SendDecimalAmount.normalizedDecimalKeyboardInput(
                    "12,50",
                    decimalSeparator: ","
                ),
                maximumFractionDigits: 2
            )
        )
        #expect(
            !SendDecimalAmount.acceptsEditableInput(
                SendDecimalAmount.normalizedDecimalKeyboardInput(
                    "١,٢",
                    decimalSeparator: ","
                ),
                maximumFractionDigits: 2
            )
        )
    }

    @Test
    func plannerRoutesCompleteAffordableRequestToReview() throws {
        let request = try SendPaymentRequestParser.parse(
            "ethereum:\(evmRecipient)@137?value=1e18"
        )
        let route = try SendFlowPlanner.initialRoute(
            for: request,
            choices: [
                choice(
                    networkID: "polygon",
                    blockchain: .polygon,
                    decimals: 18,
                    balance: "2"
                )
            ]
        )

        guard case let .review(draft) = route else {
            Issue.record("Expected the completed request to reach review.")
            return
        }
        #expect(draft.amount == "1")
        #expect(draft.recipient == evmRecipient)
    }

    @Test
    func plannerReturnsScannedOverBalanceAmountToEditableForm()
        throws
    {
        let request = try SendPaymentRequestParser.parse(
            """
            bitcoin:1BoatSLRHtKNngkdXEeobR76b53LETtpyT\
            ?amount=1.25
            """
        )
        let route = try SendFlowPlanner.initialRoute(
            for: request,
            choices: [
                choice(
                    networkID: "bitcoin",
                    blockchain: .bitcoin,
                    decimals: 8,
                    balance: "0.5"
                )
            ]
        )

        guard case let .amount(
            draft,
            failure
        ) = route else {
            Issue.record("Expected the request to return to the form.")
            return
        }
        #expect(draft.amount == "1.25")
        #expect(failure?.recipientIssue == nil)
        #expect(failure?.amountIssue == .exceedsBalance)
    }

    @Test
    func plannerRequiresAssetSelectionForBareEVMAndSolana()
        throws
    {
        let evmRequest = try SendPaymentRequestParser.parse(evmRecipient)
        let evmRoute = try SendFlowPlanner.initialRoute(
            for: evmRequest,
            choices: [
                choice(
                    networkID: "eth",
                    blockchain: .ethereum,
                    decimals: 18,
                    balance: "1"
                ),
                choice(
                    networkID: "polygon",
                    blockchain: .polygon,
                    decimals: 18,
                    balance: "1"
                )
            ]
        )
        guard case .assetSelection = evmRoute else {
            Issue.record("Bare EVM addresses must remain ambiguous.")
            return
        }

        let solanaRequest = try SendPaymentRequestParser.parse(
            solanaRecipient
        )
        let solanaRoute = try SendFlowPlanner.initialRoute(
            for: solanaRequest,
            choices: [
                choice(
                    networkID: "solana",
                    blockchain: .solana,
                    decimals: 9,
                    balance: "1"
                )
            ]
        )
        guard case .assetSelection = solanaRoute else {
            Issue.record("Bare Solana addresses must choose an asset.")
            return
        }
    }

    @Test
    func textAddressEntryAcceptsOnlyValidatedBareMainnetAddresses()
        throws
    {
        let request = try SendTextAddressPreparation.request(
            from: evmRecipient,
            amount: "0.25"
        )

        #expect(request.source == .bareAddress)
        #expect(request.recipient == evmRecipient)
        #expect(request.candidateNetworkIDs.contains("eth"))
        #expect(request.candidateNetworkIDs.contains("polygon"))
        #expect(request.requestedAmount == .userUnits("0.25"))
        #expect(
            SendTextAddressPreparation.amountIssue("") == .required
        )
        #expect(
            SendTextAddressPreparation.amountIssue("0") == .zero
        )
        #expect(
            SendTextAddressPreparation.amountIssue("1.2.3") == .invalid
        )

        #expect(
            throws: SendPaymentRequestError.invalidMainnetAddress
        ) {
            try SendTextAddressPreparation.request(
                from: "ethereum:\(evmRecipient)@1",
                amount: "0.25"
            )
        }
        #expect(
            throws: SendPaymentRequestError.invalidMainnetAddress
        ) {
            try SendTextAddressPreparation.request(
                from:
                    "tb1qw508d6qejxtdg4y5r3zarvary0c5xw7kxpjzsx",
                amount: "0.25"
            )
        }
    }

    @Test
    func supportedRecipientNamesAreParsedWithoutGuessingAChain()
        throws
    {
        let ensRequest = try SendPaymentRequestParser.parse(
            "Vitalik.ETH"
        )
        let expectedENSNetworks = Set(
            ENSAddressCodec.supportedNetworkIDs
        )

        #expect(ensRequest.source == .name)
        #expect(ensRequest.recipient == "Vitalik.ETH")
        #expect(
            Set(ensRequest.candidateNetworkIDs)
                == expectedENSNetworks
        )

        let solanaRequest = try SendPaymentRequestParser.parse(
            "bonfida.sol"
        )
        #expect(solanaRequest.source == .name)
        #expect(solanaRequest.candidateNetworkIDs == ["solana"])

        let spaceIDFixtures: [(String, String)] = [
            ("spaceid.bnb", "bsc"),
            ("spaceid.four", "bsc"),
            ("0x5206.arb", "arbitrum"),
            ("resolver.gno", "gnosis"),
            ("resolver.taiko", "taiko")
        ]
        for (name, networkID) in spaceIDFixtures {
            let request = try SendPaymentRequestParser.parse(name)
            #expect(request.source == .name)
            #expect(request.candidateNetworkIDs == [networkID])
        }
    }

    @Test
    func unsupportedOrMalformedRecipientNamesReturnExactErrors() {
        #expect(throws: SendRecipientNameError.ensUsesEthSuffix) {
            try SendPaymentRequestParser.parse("wallet.ens")
        }
        #expect(throws: SendRecipientNameError.unsupportedService) {
            try SendPaymentRequestParser.parse("wallet.example")
        }
        #expect(throws: SendRecipientNameError.invalidName) {
            try SendPaymentRequestParser.parse("wallet..eth")
        }
        #expect(throws: SendRecipientNameError.invalidName) {
            try SendPaymentRequestParser.parse("wallet name.eth")
        }
        #expect(throws: SendRecipientNameError.invalidName) {
            try SendPaymentRequestParser.parse("wallet@")
        }
    }

    @Test
    func spaceIDPaymentIDExposesOnlySupportedResolutionFamilies()
        throws
    {
        let request = try SendPaymentRequestParser.parse(
            "alice@spaceid"
        )
        let candidates = Set(request.candidateNetworkIDs)

        #expect(request.source == .name)
        #expect(candidates.contains("eth"))
        #expect(candidates.contains("polygon"))
        #expect(candidates.contains("bitcoin"))
        #expect(candidates.contains("solana"))
        #expect(candidates.contains("tron"))
        #expect(!candidates.contains("litecoin"))
        #expect(!candidates.contains("doge"))
        #expect(!candidates.contains("bitcoincash"))
    }

    @Test
    func ensNormalizationNamehashAndCallEncodingMatchStandards()
        throws
    {
        let normalized = try ENSUniversalResolverClient.normalizedName(
            "Vitalik.ETH"
        )
        #expect(normalized == "vitalik.eth")
        #expect(
            ENSUniversalResolverClient.namehash(normalized).hexString
                == """
                ee6c4522aab0003e8d14cd40a6af439055fd2577951148c14b6cea\
                9a53475835
                """
        )
        #expect(
            try ENSUniversalResolverClient.dnsEncodedName(
                normalized
            ).hexString
                == "07766974616c696b0365746800"
        )

        let call = try ENSUniversalResolverClient.resolveCallData(
            normalizedName: normalized,
            coinType: 60
        )
        #expect(call.prefix(4).hexString == "9061b923")
        #expect(
            call.dropLast(28).suffix(8).hexString
                == "000000000000003c"
        )
    }

    @Test
    func ensCoinTypesCoverEverySupportedMainnet() {
        for networkID in ENSAddressCodec.supportedNetworkIDs {
            let expected: UInt64
            switch networkID {
            case "eth":
                expected = 60
            case "tron":
                expected = 195
            case "solana":
                expected = 501
            case "bitcoin":
                expected = 0
            case "litecoin":
                expected = 2
            case BitcoinFamilyChain.dogecoin.networkID:
                expected = 3
            case BitcoinFamilyChain.bitcoinCash.networkID:
                expected = 145
            default:
                guard let network = SendAddressValidator.evmNetworks
                    .first(where: { $0.id == networkID })
                else {
                    Issue.record(
                        "A supported ENS network has no coin-type mapping."
                    )
                    continue
                }
                expected = 0x8000_0000 | UInt64(network.chainID)
            }
            #expect(
                ENSAddressCodec.coinType(for: networkID)
                    == expected
            )
        }

        let supported = Set(ENSAddressCodec.supportedNetworkIDs)
        for network in ReceiveNetworkCatalog.all
        where !supported.contains(network.id) {
            #expect(ENSAddressCodec.coinType(for: network.id) == nil)
        }
        #expect(ENSAddressCodec.coinType(for: "unsupported") == nil)
    }

    @Test
    func ensAddressCodecDecodesEverySupportedAddressFamily()
        throws
    {
        #expect(
            try ENSAddressCodec.address(
                from: data(
                    "71c7656ec7ab88b098defb751b7401b5f6d8976f"
                ),
                networkID: "eth"
            ).lowercased() == evmRecipient.lowercased()
        )
        #expect(
            try ENSAddressCodec.address(
                from: data(
                    "0b824c2aa3699485f26c66ff1a12b5a1f75559eb848d79d0a2bee08b463684c7"
                ),
                networkID: "solana"
            ) == solanaRecipient
        )
        #expect(
            try ENSAddressCodec.address(
                from: data(
                    "418840e6c55b9ada326d211d818c34a994aeced808"
                ),
                networkID: "tron"
            ) == "TNPeeaaFB7K9cmo4uQpcU32zGK8G1NYqeL"
        )

        let scriptFixtures: [(String, String, String)] = [
            (
                "76a9147680adec8eabcabac676be9e83854ade0bd22cdb88ac",
                "bitcoin",
                "1BoatSLRHtKNngkdXEeobR76b53LETtpyT"
            ),
            (
                "a91474f209f6ea907e2ea48f74fae05782ae8a66525787",
                "bitcoin",
                "3CMNFxN1oHBc4R1EpboAL5yzHGgE611Xou"
            ),
            (
                "0014751e76e8199196d454941c45d1b3a323f1433bd6",
                "bitcoin",
                "bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4"
            ),
            (
                "512079be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798",
                "bitcoin",
                """
                bc1p0xlxvlhemja6c4dqv22uapctqupfhlxm9h8z3k2e72q4k9h\
                cz7vqzk5jj0
                """
            ),
            (
                "76a914558dbca7118cd5894502767c7b2ffc21a22f54db88ac",
                "litecoin",
                "LT2KVaAy1ppRuxRgrS5RNU3vBsy7RibPeA"
            ),
            (
                "76a91456d9b1d684d5abef32134ebc6883d75d3a53e9be88ac",
                BitcoinFamilyChain.dogecoin.networkID,
                "DD4KSSuBJqcjuTcvUg1CgUKeurPUFeEZkE"
            ),
            (
                "76a91476a04053bda0a88bda5177b86a15c3b29f55987388ac",
                BitcoinFamilyChain.bitcoinCash.networkID,
                """
                bitcoincash:qpm2qsznhks23z7629mms6s4cwef74vcw\
                vy22gdx6a
                """
            )
        ]
        for (script, networkID, expected) in scriptFixtures {
            #expect(
                try ENSAddressCodec.address(
                    from: data(script),
                    networkID: networkID
                ) == expected
            )
        }
    }

    @Test
    func universalResolverResponseDecodingRejectsMalformedData()
        throws
    {
        let record = data(
            "71c7656ec7ab88b098defb751b7401b5f6d8976f"
        )
        let inner = abiWord(32)
            + abiWord(record.count)
            + padded(record)
        let outer = abiWord(64)
            + Data(repeating: 0, count: 32)
            + abiWord(inner.count)
            + padded(inner)

        #expect(
            try ENSUniversalResolverClient.decodeResolvedRecord(
                outer
            ) == record
        )
        #expect(throws: SendRecipientNameError.invalidServiceResponse) {
            try ENSUniversalResolverClient.decodeResolvedRecord(
                Data(repeating: 0, count: 31)
            )
        }
    }

    @Test
    func nameResolutionOccursBeforeFinalReview() throws {
        let request = try SendTextAddressPreparation.request(
            from: "vitalik.eth",
            amount: "0.25"
        )
        let selectedAsset = choice(
            networkID: "eth",
            blockchain: .ethereum,
            decimals: 18,
            balance: "1"
        )
        let route = try SendFlowPlanner.route(
            afterSelecting: selectedAsset,
            for: request
        )

        guard case let .recipient(draft, issue) = route else {
            Issue.record(
                "Names must resolve before reaching final review."
            )
            return
        }
        #expect(draft.recipient == "vitalik.eth")
        #expect(draft.amount == "0.25")
        #expect(issue == nil)

        let solanaRequest = try SendPaymentRequestParser.parse(
            "bonfida.sol"
        )
        let mismatchRoute = try SendFlowPlanner.route(
            afterSelecting: selectedAsset,
            for: solanaRequest
        )
        guard case let .recipient(
            mismatchDraft,
            mismatchFailure
        ) = mismatchRoute else {
            Issue.record(
                "A fixable recipient mismatch must open the editor."
            )
            return
        }
        #expect(
            mismatchFailure?.recipientIssue
                == .name(.networkMismatch)
        )
        #expect(mismatchDraft.recipient == "bonfida.sol")
    }

    @Test
    func pastedPaymentRequestPopulatesOnlyFieldsItContains() throws {
        let asset = choice(
            networkID: "bitcoin",
            blockchain: .bitcoin,
            decimals: 8,
            balance: "2"
        )
        let withAmount = try SendRecipientPastePreparation.fields(
            from:
                "bitcoin:1BoatSLRHtKNngkdXEeobR76b53LETtpyT?amount=0.25",
            selectedAsset: asset
        )
        #expect(withAmount.recipient == "1BoatSLRHtKNngkdXEeobR76b53LETtpyT")
        #expect(withAmount.amount == "0.25")

        let addressOnly = try SendRecipientPastePreparation.fields(
            from: "1BoatSLRHtKNngkdXEeobR76b53LETtpyT",
            selectedAsset: asset
        )
        #expect(addressOnly.recipient == withAmount.recipient)
        #expect(addressOnly.amount == nil)
    }

    @Test
    func pastedRequestMustMatchTheSelectedAssetAndNetwork() {
        let asset = choice(
            networkID: "eth",
            blockchain: .ethereum,
            decimals: 18,
            balance: "2"
        )
        #expect(throws: SendRecipientPasteError.selectedAssetMismatch) {
            try SendRecipientPastePreparation.fields(
                from: "ethereum:\(evmRecipient)@137?value=1e18",
                selectedAsset: asset
            )
        }
    }

    @Test
    func localCurrencyEntryAndMaxResolveToExactAssetAmounts() throws {
        let asset = choice(
            networkID: "eth",
            blockchain: .ethereum,
            decimals: 18,
            balance: "2",
            fiatValue: "5000"
        )
        let currency = WalletCurrencyContext(
            code: "EUR",
            ratePerUSD: Decimal(string: "0.9")!
        )
        #expect(
            try SendAmountEntryConverter.assetAmount(
                from: "2250",
                mode: .localCurrency,
                usesMaximumBalance: false,
                asset: asset,
                currency: currency
            ) == "1"
        )
        #expect(
            try SendAmountEntryConverter.maximumInput(
                mode: .localCurrency,
                asset: asset,
                currency: currency
            ) == "4500"
        )
        #expect(
            try SendAmountEntryConverter.assetAmount(
                from: "4500",
                mode: .localCurrency,
                usesMaximumBalance: true,
                asset: asset,
                currency: currency
            ) == "2"
        )
        #expect(
            SendAmountEntryConverter.pricing(
                asset: choice(
                    networkID: "eth",
                    blockchain: .ethereum,
                    decimals: 18,
                    balance: "2"
                ),
                currency: currency
            ) == nil
        )
    }

    private func choice(
        networkID: String,
        blockchain: WalletBlockchain,
        decimals: Int,
        balance: String,
        fiatValue: String = "0"
    ) -> SendAssetChoice {
        SendAssetChoice(
            id: "\(networkID):native",
            name: networkID,
            symbol: networkID.uppercased(),
            networkID: networkID,
            networkName: networkID,
            blockchain: blockchain,
            contractAddress: nil,
            decimals: decimals,
            logoSource: .nativeCoin(blockchain: blockchain),
            networkLogoSource: .nativeCoin(blockchain: blockchain),
            balance: Decimal(
                string: balance,
                locale: Locale(identifier: "en_US_POSIX")
            ) ?? 0,
            fiatValue: Decimal(
                string: fiatValue,
                locale: Locale(identifier: "en_US_POSIX")
            ) ?? 0
        )
    }

    private func data(_ hexadecimal: String) -> Data {
        let normalized = hexadecimal.components(
            separatedBy: .whitespacesAndNewlines
        ).joined()
        guard normalized.count.isMultiple(of: 2) else {
            Issue.record("A test hexadecimal fixture is invalid.")
            return Data()
        }

        var result = Data()
        result.reserveCapacity(normalized.count / 2)
        var index = normalized.startIndex
        while index < normalized.endIndex {
            let next = normalized.index(index, offsetBy: 2)
            guard let byte = UInt8(normalized[index..<next], radix: 16)
            else {
                Issue.record("A test hexadecimal fixture is invalid.")
                return Data()
            }
            result.append(byte)
            index = next
        }
        return result
    }

    private func abiWord(_ value: Int) -> Data {
        var word = Data(repeating: 0, count: 32)
        var remaining = value
        for offset in 0..<8 {
            word[31 - offset] = UInt8(remaining & 0xff)
            remaining >>= 8
        }
        return word
    }

    private func padded(_ value: Data) -> Data {
        let padding = (32 - value.count % 32) % 32
        return value + Data(repeating: 0, count: padding)
    }
}
