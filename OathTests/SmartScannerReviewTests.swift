import Foundation
import GRDB
import Testing
import WalletCore
@testable import Aperture

struct SmartScannerReviewTests {
    @Test
    func completePaymentReviewShowsResolvedDetailsAndAction()
        throws
    {
        let request = try SendPaymentRequestParser.parse(
            """
            bitcoin:1BoatSLRHtKNngkdXEeobR76b53LETtpyT\
            ?amount=0.25&label=Invoice
            """
        )
        let choice = SendAssetChoice(
            id: "bitcoin:native",
            name: "Bitcoin",
            symbol: "BTC",
            networkID: "bitcoin",
            networkName: "Bitcoin",
            blockchain: .bitcoin,
            contractAddress: nil,
            decimals: 8,
            logoSource: .nativeCoin(blockchain: .bitcoin),
            networkLogoSource: .nativeCoin(blockchain: .bitcoin),
            balance: 1,
            fiatValue: 0
        )
        let route = try SendFlowPlanner.initialRoute(
            for: request,
            choices: [choice]
        )
        let presentation = SendScannerReview(
            request: request,
            route: route
        ).presentation

        #expect(presentation.kind == .payment)
        #expect(
            presentation.primaryActionKey
                == "send.scan.review.action.review_send"
        )
        #expect(presentation.heroLogoSource == choice.logoSource)
        #expect(
            presentation.rows.contains {
                $0.id == "amount" && $0.value == "0.25 BTC"
            }
        )
        #expect(
            presentation.rows.contains {
                $0.id == "recipient"
                    && $0.value
                        == "1BoatSLRHtKNngkdXEeobR76b53LETtpyT"
                    && $0.valueStyle == .standard
            }
        )
    }

    @Test
    func bareAddressesAutoSelectEverySingleNativeAssetNetwork()
        throws
    {
        let fixtures: [(
            address: String,
            networkID: String,
            name: String,
            symbol: String,
            blockchain: WalletBlockchain
        )] = [
            (
                "bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4",
                "bitcoin",
                "Bitcoin",
                "BTC",
                .bitcoin
            ),
            (
                "qpm2qsznhks23z7629mms6s4cwef74vcwvy22gdx6a",
                "bitcoin_cash",
                "Bitcoin Cash",
                "BCH",
                .bitcoincash
            ),
            (
                "LT2KVaAy1ppRuxRgrS5RNU3vBsy7RibPeA",
                "litecoin",
                "Litecoin",
                "LTC",
                .litecoin
            ),
            (
                "DD4KSSuBJqcjuTcvUg1CgUKeurPUFeEZkE",
                "dogecoin",
                "Dogecoin",
                "DOGE",
                .dogecoin
            ),
        ]
        #expect(
            SendFlowPlanner.automaticallySelectedNativeNetworkIDs
                == Set(fixtures.map(\.networkID))
        )

        for fixture in fixtures {
            let request = try SendPaymentRequestParser.parse(
                fixture.address
            )
            #expect(request.candidateNetworkIDs == [fixture.networkID])
            #expect(request.requestedAsset == .unspecified)

            let choice = SendAssetChoice(
                id: "\(fixture.networkID):native",
                name: fixture.name,
                symbol: fixture.symbol,
                networkID: fixture.networkID,
                networkName: fixture.name,
                blockchain: fixture.blockchain,
                contractAddress: nil,
                decimals: 8,
                logoSource: .nativeCoin(
                    blockchain: fixture.blockchain
                ),
                networkLogoSource: .nativeCoin(
                    blockchain: fixture.blockchain
                ),
                balance: 1,
                fiatValue: 0
            )
            let route = try SendFlowPlanner.initialRoute(
                for: request,
                choices: [choice]
            )
            guard case let .amount(
                draft,
                failure
            ) = route else {
                Issue.record(
                    "A single native asset address requested asset selection."
                )
                continue
            }
            #expect(draft.asset.id == choice.id)
            #expect(draft.recipient == fixture.address)
            #expect(failure == nil)
            #expect(
                SendScannerReview(
                    request: request,
                    route: route
                ).presentation.primaryActionKey
                    == "send.scan.review.action.enter_amount"
            )
        }
    }

    @Test
    func nearFallbackDoesNotCompeteWithChecksummedChainAddresses()
        throws
    {
        let bitcoin = try SendPaymentRequestParser.parse(
            "bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4"
        )
        let near = try SendPaymentRequestParser.parse("alice.near")

        #expect(bitcoin.candidateNetworkIDs == ["bitcoin"])
        #expect(!bitcoin.candidateNetworkIDs.contains(NEARConstants.networkID))
        #expect(near.candidateNetworkIDs == [NEARConstants.networkID])
    }

    @Test
    func implicitNEARAddressDoesNotCollideWithAptosOrSui() throws {
        let implicit =
            "5510e2b44cae6eb807e3e0e45d579dda058c274abcba15e5cb84636f5d1ee412"
        let request = try SendPaymentRequestParser.parse(implicit)

        #expect(request.candidateNetworkIDs == [NEARConstants.networkID])
        #expect(request.recipient == implicit)
        #expect(request.requestedAsset == .unspecified)
    }

    @Test
    func receiveQRCodesPinMoveAndNEARNetworksAndAssets() throws {
        let fixtures: [(
            networkID: String,
            address: String,
            nativePayload: String,
            token: String,
            decimals: Int
        )] = [
            (
                AptosConstants.networkID,
                "0xd503b95164384a5ebbccbb5c4bdc8b4a5893d9651e9953abda8e1c22fcc1181d",
                "aptos:0xd503b95164384a5ebbccbb5c4bdc8b4a5893d9651e9953abda8e1c22fcc1181d",
                "0xabc::managed_coin::USDC",
                AptosConstants.decimals
            ),
            (
                SuiConstants.networkID,
                "0xdfc88cd008c89a4a4a60199b27e503cd5e248b5191be8e953856b43e87ae3393",
                "sui:0xdfc88cd008c89a4a4a60199b27e503cd5e248b5191be8e953856b43e87ae3393",
                "0x2::example_coin::EXAMPLE",
                SuiConstants.decimals
            ),
            (
                NEARConstants.networkID,
                "5510e2b44cae6eb807e3e0e45d579dda058c274abcba15e5cb84636f5d1ee412",
                "near:5510e2b44cae6eb807e3e0e45d579dda058c274abcba15e5cb84636f5d1ee412",
                "usdt.tether-token.near",
                NEARConstants.decimals
            )
        ]

        for fixture in fixtures {
            let network = try #require(
                ReceiveNetworkCatalog.network(for: fixture.networkID)
            )
            let nativePayload = ReceiveAddressResolver.paymentPayload(
                address: fixture.address,
                network: network,
                contractAddress: nil
            )
            #expect(nativePayload == fixture.nativePayload)

            let nativeRequest = try SendPaymentRequestParser.parse(
                nativePayload
            )
            #expect(nativeRequest.candidateNetworkIDs == [fixture.networkID])
            #expect(nativeRequest.requestedNetworkID == fixture.networkID)
            #expect(nativeRequest.requestedAsset == .native)
            let route = try SendFlowPlanner.initialRoute(
                for: nativeRequest,
                choices: [
                    SendAssetChoice(
                        id: "\(fixture.networkID):native",
                        name: network.localizedName,
                        symbol: network.symbol,
                        networkID: network.id,
                        networkName: network.localizedName,
                        blockchain: network.blockchain,
                        contractAddress: nil,
                        decimals: fixture.decimals,
                        logoSource: network.logoSource,
                        networkLogoSource: network.logoSource,
                        balance: 1,
                        fiatValue: 0
                    )
                ]
            )
            guard case .amount = route else {
                Issue.record(
                    "A chain-pinned native Receive QR opened asset selection."
                )
                continue
            }

            let tokenPayload = ReceiveAddressResolver.paymentPayload(
                address: fixture.address,
                network: network,
                contractAddress: fixture.token
            )
            let tokenRequest = try SendPaymentRequestParser.parse(tokenPayload)
            #expect(tokenRequest.candidateNetworkIDs == [fixture.networkID])
            #expect(tokenRequest.requestedNetworkID == fixture.networkID)
            #expect(tokenRequest.requestedAsset == .contract(fixture.token))
        }
    }

    @Test
    func bareMoveAddressRemainsAmbiguousWithoutAChainScheme() throws {
        let address =
            "0xd503b95164384a5ebbccbb5c4bdc8b4a5893d9651e9953abda8e1c22fcc1181d"
        let request = try SendPaymentRequestParser.parse(address)

        #expect(
            Set(request.candidateNetworkIDs)
                == [AptosConstants.networkID, SuiConstants.networkID]
        )
        #expect(request.requestedNetworkID == nil)
        #expect(request.requestedAsset == .unspecified)
    }

    @Test
    func malformedSelfDescribingAddressIsNeverRelabeledAsNEAR() {
        let invalidBitcoin =
            "bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kg3g4ty"
        let bitcoinTestnet =
            "tb1qw508d6qejxtdg4y5r3zarvary0c5xw7kxpjzsx"

        #expect(
            SendAddressValidator.candidateNetworkIDs(
                for: invalidBitcoin
            ).isEmpty
        )
        #expect(
            SendAddressValidator.candidateNetworkIDs(
                for: bitcoinTestnet
            ).isEmpty
        )
        #expect(throws: SendPaymentRequestError.invalidMainnetAddress) {
            try SendPaymentRequestParser.parse(invalidBitcoin)
        }
        #expect(throws: SendPaymentRequestError.invalidMainnetAddress) {
            try SendPaymentRequestParser.parse(bitcoinTestnet)
        }
    }

    @Test
    func recoveryPhraseReviewShowsValidatedSecretBeforeImport()
        throws
    {
        let phrase =
            """
            abandon abandon abandon abandon abandon abandon abandon \
            abandon abandon abandon abandon about
            """
        let review = try ImportCredentialScanReview.parse(
            phrase,
            mode: .recoveryPhrase
        )

        #expect(review.wordCount == 12)
        #expect(review.presentation.kind == .recoveryPhrase)
        #expect(
            review.presentation.primaryActionKey
                == "import.scanner.review.action.use_recovery_phrase"
        )
        #expect(
            review.presentation.rows.contains {
                $0.id == "recovery_phrase"
                    && $0.valueStyle == .secret
                    && $0.value == phrase
            }
        )
    }

    @Test
    func overBalancePaymentReviewShowsExactBlockingIssue()
        throws
    {
        let request = try SendPaymentRequestParser.parse(
            """
            bitcoin:1BoatSLRHtKNngkdXEeobR76b53LETtpyT\
            ?amount=2
            """
        )
        let choice = SendAssetChoice(
            id: "bitcoin:native",
            name: "Bitcoin",
            symbol: "BTC",
            networkID: "bitcoin",
            networkName: "Bitcoin",
            blockchain: .bitcoin,
            contractAddress: nil,
            decimals: 8,
            logoSource: .nativeCoin(blockchain: .bitcoin),
            networkLogoSource: .nativeCoin(blockchain: .bitcoin),
            balance: 1,
            fiatValue: 0
        )
        let route = try SendFlowPlanner.initialRoute(
            for: request,
            choices: [choice]
        )
        let presentation = SendScannerReview(
            request: request,
            route: route
        ).presentation

        #expect(
            presentation.rows.contains {
                $0.id == "attention"
                    && $0.valueStyle == .warning
                    && $0.value
                        == SendAmountValidationIssue
                            .exceedsBalance.localizedMessage
            }
        )
        #expect(
            presentation.primaryActionKey
                == "send.scan.review.action.enter_amount"
        )
    }

    @Test
    func bscUSDCOverBalanceScanRoutesToAmountCorrection()
        throws
    {
        let recipient =
            "0x71C7656EC7ab88b098defB751B7401B5f6d8976F"
        let contract =
            "0x8ac76a51cc950d9822d68b83fe1ad97b32cd580d"
        let request = try SendPaymentRequestParser.parse(
            """
            ethereum:\(contract)@56/transfer\
            ?address=\(recipient)&uint256=1250000000000000000
            """
        )
        let choice = SendAssetChoice(
            id: "bsc:\(contract)",
            name: "USD Coin",
            symbol: "USDC",
            networkID: "bsc",
            networkName: "BNB Smart Chain",
            blockchain: .smartchain,
            contractAddress: contract,
            decimals: 18,
            logoSource: .unavailable,
            networkLogoSource: .nativeCoin(
                blockchain: .smartchain
            ),
            balance: 0,
            fiatValue: 0
        )
        let route = try SendFlowPlanner.initialRoute(
            for: request,
            choices: [choice]
        )
        guard case let .amount(
            draft,
            failure
        ) = route else {
            Issue.record(
                "An unaffordable scan must open Amount."
            )
            return
        }

        #expect(draft.recipient == recipient)
        #expect(draft.amount == "1.25")
        #expect(failure?.recipientIssue == nil)
        #expect(failure?.amountIssue == .exceedsBalance)
        #expect(
            SendScannerReview(
                request: request,
                route: route
            ).presentation.primaryActionKey
                == "send.scan.review.action.enter_amount"
        )
    }

    @Test
    func sendScannerRejectsCredentialsUnlessTheyAreCanonicalNEARAddresses()
        throws
    {
        let phrase =
            """
            abandon abandon abandon abandon abandon abandon abandon \
            abandon abandon abandon abandon about
            """
        let rawKey = String(repeating: "0", count: 63) + "1"
        let privateKeyData = Data(
            repeating: 0,
            count: 31
        ) + Data([1])
        let bitcoinWIF = Self.wif(
            privateKey: privateKeyData,
            prefix: 0x80
        )
        let litecoinWIF = Self.wif(
            privateKey: privateKeyData,
            prefix: 0xb0
        )
        let dogecoinWIF = Self.wif(
            privateKey: privateKeyData,
            prefix: 0x9e
        )
        let wifFixtures: [
            (network: PrivateKeyImportNetwork, value: String)
        ] = [
            (.bitcoin, bitcoinWIF),
            (.bitcoinCash, bitcoinWIF),
            (.litecoin, litecoinWIF),
            (.dogecoin, dogecoinWIF)
        ]

        do {
            try ScannerPayloadPolicy.sendRequest(from: phrase)
            Issue.record("Recovery phrase was accepted as a payment request.")
        } catch {
            #expect(
                error is SendPaymentRequestError
                    || error is SendRecipientNameError
            )
        }
        for network in [
            PrivateKeyImportNetwork.evm,
            .tron,
            .solana
        ] {
            #expect(
                PrivateKeyImportService.isValid(
                    rawKey,
                    network: network
                )
            )
        }
        let nearRequest = try ScannerPayloadPolicy.sendRequest(
            from: rawKey
        )
        #expect(
            nearRequest.candidateNetworkIDs
                == [NEARConstants.networkID]
        )

        for fixture in wifFixtures {
            #expect(
                PrivateKeyImportService.isValid(
                    fixture.value,
                    network: fixture.network
                )
            )
            #expect(throws: SendPaymentRequestError.self) {
                try ScannerPayloadPolicy.sendRequest(
                    from: fixture.value
                )
            }
        }
    }

    @Test
    func credentialScannerContextAcceptsOnlyItsSelectedMode()
        throws
    {
        let phrase =
            """
            abandon abandon abandon abandon abandon abandon abandon \
            abandon abandon abandon abandon about
            """
        let key = String(repeating: "0", count: 63) + "1"
        let payment =
            """
            bitcoin:1BoatSLRHtKNngkdXEeobR76b53LETtpyT\
            ?amount=0.25
            """

        let recovery = try ScannerPayloadPolicy.importCredential(
            from: phrase,
            mode: .recoveryPhrase
        )
        #expect(recovery.mode == .recoveryPhrase)

        let privateKey = try ScannerPayloadPolicy.importCredential(
            from: key,
            mode: .privateKey(.evm)
        )
        #expect(
            privateKey.mode == .privateKey(.evm)
        )

        #expect(
            throws:
                ImportCredentialScanError.invalidRecoveryPhrase
        ) {
            try ScannerPayloadPolicy.importCredential(
                from: payment,
                mode: .recoveryPhrase
            )
        }
        #expect(
            throws:
                ImportCredentialScanError.invalidPrivateKey
        ) {
            try ScannerPayloadPolicy.importCredential(
                from: payment,
                mode: .privateKey(.evm)
            )
        }
    }

    @Test
    func tokenContractScannerRequiresAnExactAddress() {
        let contract =
            "0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174"
        let payment =
            """
            ethereum:\(contract)@137/transfer\
            ?address=0x71C7656EC7ab88b098defB751B7401B5f6d8976F\
            &uint256=1250000
            """

        #expect(
            ScannerPayloadPolicy.tokenContractAddress(
                from: "  \(contract)  "
            ) == contract.lowercased()
        )
        #expect(
            ScannerPayloadPolicy.tokenContractAddress(
                from: "contract: \(contract)"
            ) == nil
        )
        #expect(
            ScannerPayloadPolicy.tokenContractAddress(
                from: payment
            ) == nil
        )
    }

    @Test
    func deviceTransferScannerContextRejectsPaymentPayloads()
        throws
    {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let source = try DeviceMigrationCryptography
            .makeSourceHandshake(now: now)
        let invitation = try ScannerPayloadPolicy
            .deviceMigrationInvitation(
                from: source.invitation.qrPayload,
                now: now
            )

        #expect(invitation == source.invitation)
        #expect(throws: DeviceMigrationError.invalidInvitation) {
            try ScannerPayloadPolicy.deviceMigrationInvitation(
                from: "1BoatSLRHtKNngkdXEeobR76b53LETtpyT",
                now: now
            )
        }
        #expect(throws: SendPaymentRequestError.self) {
            try ScannerPayloadPolicy.sendRequest(
                from: source.invitation.qrPayload
            )
        }
    }

    @Test
    func unknownAddressCannotCreateAWatchOnlyWallet()
        async throws
    {
        let database = try WalletDatabase.temporary()

        try await database.pool.write { db in
            #expect(
                throws:
                    WalletSnapshotPersistenceError
                        .selectedWalletUnavailable
            ) {
                try WalletDatabase.registeredWalletAndAccounts(
                    address:
                        "0x71C7656EC7ab88b098defB751B7401B5f6d8976F",
                    normalizedAddress:
                        "0x71c7656ec7ab88b098defb751b7401b5f6d8976f",
                    database: db
                )
            }
            let walletCount = try DBWalletRecord.fetchCount(db)
            let accountCount = try DBWalletAccountRecord.fetchCount(db)
            #expect(walletCount == 0)
            #expect(accountCount == 0)
        }
    }

    private static func wif(
        privateKey: Data,
        prefix: UInt8
    ) -> String {
        var payload = Data([prefix])
        payload.append(privateKey)
        payload.append(0x01)
        return Base58.encode(data: payload)
    }
}

struct SelectedAssetSendRoutingTests {
    @Test
    func selectedAssetScannerBypassesSelectorsForEverySupportedMainnet()
        throws
    {
        for option in AssetNetworkSelectorOption.allSupported {
            let choice = try selectedNativeChoice(for: option)
            let request = try SendPaymentRequestParser.parse(
                scannedAddress(for: option.blockchain)
            )

            #expect(
                request.candidateNetworkIDs.contains(option.id),
                "The fixture must validate for \(option.id)."
            )
            let preparation = SendFlowPreparation.prepare(
                request,
                walletAssets: [],
                capabilities: .fullWallet,
                selectedAsset: choice
            )
            guard case let .ready(route) = preparation,
                  case let .recipient(draft, failure) = route else {
                Issue.record(
                    "Selected \(option.id) QR requested another selector."
                )
                continue
            }

            #expect(draft.asset.id == choice.id)
            #expect(draft.asset.networkID == option.id)
            #expect(draft.recipient == request.recipient)
            #expect(failure?.recipientIssue == nil)
        }
    }

    @Test
    func selectedAssetScannerKeepsPaymentAmountInRecipientDetails()
        throws
    {
        let option = try #require(
            AssetNetworkSelectorOption.allSupported.first {
                $0.id == BitcoinFamilyChain.bitcoinCash.networkID
            }
        )
        let choice = try selectedNativeChoice(for: option)
        let request = try SendPaymentRequestParser.parse(
            "bitcoincash:qpm2qsznhks23z7629mms6s4cwef74vcwvy22gdx6a?amount=0.01"
        )

        let preparation = SendFlowPreparation.prepare(
            request,
            walletAssets: [],
            capabilities: .fullWallet,
            selectedAsset: choice
        )
        guard case let .ready(route) = preparation,
              case let .recipient(draft, failure) = route else {
            Issue.record(
                "A selected BCH payment QR must open Recipient Details."
            )
            return
        }

        #expect(draft.asset.id == choice.id)
        #expect(draft.amount == "0.01")
        #expect(failure == nil)
    }

    @Test
    func selectedTokenScannerKeepsExactContractForBareAddress()
        throws
    {
        let contract =
            "0x6B175474E89094C44Da98b954EedeAC495271d0F"
        let selectedAsset = tokenAsset(
            identity: AssetIdentityKey.make(
                networkID: "eth",
                contractAddress: contract
            ),
            contract: contract,
            balance: 2,
            fiatValue: 2
        )
        let choice = try #require(
            SendAssetChoiceCatalog.choice(
                for: selectedAsset,
                refreshedFrom: [selectedAsset],
                capabilities: .fullWallet
            )
        )
        let request = try SendPaymentRequestParser.parse(
            "0x71C7656EC7ab88b098defB751B7401B5f6d8976F"
        )

        let preparation = SendFlowPreparation.prepare(
            request,
            walletAssets: [],
            capabilities: .fullWallet,
            selectedAsset: choice
        )
        guard case let .ready(route) = preparation,
              case let .recipient(draft, failure) = route else {
            Issue.record(
                "A selected token QR must not reopen asset selection."
            )
            return
        }

        #expect(draft.asset.id == choice.id)
        #expect(draft.asset.contractAddress == contract)
        #expect(failure == nil)
    }

    @Test
    func selectedAssetScannerRejectsAnExplicitForeignNetwork() throws {
        let ethereum = try #require(
            AssetNetworkSelectorOption.allSupported.first {
                $0.id == "eth"
            }
        )
        let choice = try selectedNativeChoice(for: ethereum)
        let request = try SendPaymentRequestParser.parse(
            "ethereum:0x71C7656EC7ab88b098defB751B7401B5f6d8976F@137"
        )

        guard case let .failed(message) = SendFlowPreparation.prepare(
            request,
            walletAssets: [],
            capabilities: .fullWallet,
            selectedAsset: choice
        ) else {
            Issue.record("A Polygon QR must not be sent as Ethereum.")
            return
        }
        #expect(
            message
                == SendRecipientPasteError
                    .selectedAssetMismatch.localizedMessage
        )
    }

    @Test
    func selectedNativeAssetOpensRecipientEntryForEverySupportedNetwork()
        throws
    {
        for option in AssetNetworkSelectorOption.allSupported {
            let identity = AssetIdentityKey.make(
                networkID: option.id,
                contractAddress: nil
            )
            let selectedAsset = WalletAsset(
                id: identity,
                name: option.localizedName,
                symbol: option.blockchain.rawValue.uppercased(),
                logoSource: .nativeCoin(
                    blockchain: option.blockchain
                ),
                network: option.blockchain,
                balance: 1,
                fiatValue: 1
            )
            let choice = try #require(
                SendAssetChoiceCatalog.choice(
                    for: selectedAsset,
                    refreshedFrom: [selectedAsset],
                    capabilities: .fullWallet
                )
            )

            #expect(choice.id == identity)
            #expect(choice.networkID == option.id)
            assertRecipientEntry(
                SendFlowPlanner.manualEntryRoute(for: choice),
                expectedAssetID: identity,
                expectedNetworkID: option.id
            )
        }
    }

    @Test
    func selectedTokenKeepsItsExactNetworkContractAndFreshBalance()
        throws
    {
        let contract =
            "0x6B175474E89094C44Da98b954EedeAC495271d0F"
        let identity = AssetIdentityKey.make(
            networkID: "eth",
            contractAddress: contract
        )
        let selectedAsset = tokenAsset(
            identity: "ETH:\(contract)",
            contract: contract,
            balance: 1,
            fiatValue: 1
        )
        let refreshedAsset = tokenAsset(
            identity: identity,
            contract: contract,
            balance: 200,
            fiatValue: 200
        )
        let choice = try #require(
            SendAssetChoiceCatalog.choice(
                for: selectedAsset,
                refreshedFrom: [refreshedAsset],
                capabilities: .fullWallet
            )
        )

        #expect(choice.id == identity)
        #expect(choice.networkID == "eth")
        #expect(
            AssetIdentityKey.make(
                networkID: choice.networkID,
                contractAddress: choice.contractAddress
            ) == identity
        )
        #expect(choice.balance == 200)
        #expect(choice.fiatValue == 200)
        assertRecipientEntry(
            SendFlowPlanner.manualEntryRoute(for: choice),
            expectedAssetID: identity,
            expectedNetworkID: "eth"
        )
    }

    private func assertRecipientEntry(
        _ route: SendFlowRoute,
        expectedAssetID: String,
        expectedNetworkID: String
    ) {
        guard case let .recipient(draft, failure) = route else {
            Issue.record(
                "Selected-asset Send must open Recipient Details directly."
            )
            return
        }

        #expect(failure == nil)
        #expect(draft.asset.id == expectedAssetID)
        #expect(draft.asset.networkID == expectedNetworkID)
        #expect(draft.recipient.isEmpty)
        #expect(draft.amount == nil)
    }

    private func selectedNativeChoice(
        for option: AssetNetworkSelectorOption
    ) throws -> SendAssetChoice {
        let asset = WalletAsset(
            id: AssetIdentityKey.make(
                networkID: option.id,
                contractAddress: nil
            ),
            name: option.localizedName,
            symbol: option.blockchain.rawValue.uppercased(),
            logoSource: .nativeCoin(blockchain: option.blockchain),
            network: option.blockchain,
            balance: 10,
            fiatValue: 10
        )
        return try #require(
            SendAssetChoiceCatalog.choice(
                for: asset,
                refreshedFrom: [asset],
                capabilities: .fullWallet
            )
        )
    }

    private func scannedAddress(
        for blockchain: WalletBlockchain
    ) -> String {
        switch blockchain {
        case .bitcoin:
            "1BoatSLRHtKNngkdXEeobR76b53LETtpyT"
        case .bitcoincash:
            "qpm2qsznhks23z7629mms6s4cwef74vcwvy22gdx6a"
        case .litecoin:
            "LT2KVaAy1ppRuxRgrS5RNU3vBsy7RibPeA"
        case .dogecoin:
            "DD4KSSuBJqcjuTcvUg1CgUKeurPUFeEZkE"
        case .tron:
            "TNPeeaaFB7K9cmo4uQpcU32zGK8G1NYqeL"
        case .solana:
            "mvines9iiHiQTysrwkJjGf2gb9Ex9jXJX8ns3qwf2kN"
        case .ton:
            "UQBm--PFwDv1yCeS-QTJ-L8oiUpqo9IT1BwgVptlSq3ts4DV"
        case .sui:
            "0xdfc88cd008c89a4a4a60199b27e503cd5e248b5191be8e953856b43e87ae3393"
        case .aptos:
            "0xd503b95164384a5ebbccbb5c4bdc8b4a5893d9651e9953abda8e1c22fcc1181d"
        case .near:
            "5510e2b44cae6eb807e3e0e45d579dda058c274abcba15e5cb84636f5d1ee412"
        case .xrp:
            "rnBFvgZphmN39GWzUJeUitaP22Fr9be75H"
        case .stellar:
            "GA5ZSEJYB37JRC5AVCIA5MOP4RHTM335X2KGX3IHOJAPP5RE34K4KZVN"
        case .ethereum, .smartchain, .polygon, .arbitrum,
             .avalanchec, .optimism, .base, .xdai, .scroll, .linea,
             .taiko, .telos, .xlayer, .arc:
            "0x71C7656EC7ab88b098defB751B7401B5f6d8976F"
        }
    }

    private func tokenAsset(
        identity: String,
        contract: String,
        balance: Decimal,
        fiatValue: Decimal
    ) -> WalletAsset {
        WalletAsset(
            id: identity,
            name: "Dai Stablecoin",
            symbol: "DAI",
            logoSource: .catalogToken(
                blockchain: .ethereum,
                contractAddress: contract,
                logoURL: nil
            ),
            network: .ethereum,
            balance: balance,
            fiatValue: fiatValue,
            decimals: 18
        )
    }
}
