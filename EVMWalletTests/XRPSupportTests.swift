import Foundation
import GRDB
import Testing
import WalletCore
@testable import Aperture

@Suite(.serialized)
struct XRPSupportTests {
    private static let mnemonic =
        "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
    private static let rippleUSDCurrencyCode =
        "524C555344000000000000000000000000000000"
    private static let rippleUSDIssuer =
        "rMxCKbEDwqr76QuheSUMdEGf4B9xJ8m5De"
    private static let rippleUSDIdentity =
        "RLUSD:\(rippleUSDIssuer)"
    private static let rippleUSDLogoURL =
        "oath-asset://catalog/stablecoin-rlusd.png"

    @Test
    func amountAddressAndDestinationTagRulesAreLossless() throws {
        #expect(try XRPAmount.userUnitsFromDrops("25094973665") == "25094.973665")
        #expect(try XRPAmount.userUnitsFromDrops("1") == "0.000001")
        #expect(try XRPAmount.canonicalIssuedPayment("12.5000") == "12.5")
        #expect(
            try XRPAmount.canonicalIssuedPayment("1234567890123456")
                == "1234567890123456"
        )
        #expect(throws: XRPProviderError.self) {
            try XRPAmount.canonicalIssuedPayment("12345678901234567")
        }
        #expect(XRPDestinationTag.acceptsEditableInput("4294967295"))
        #expect(!XRPDestinationTag.acceptsEditableInput("42949672950"))
        #expect(!XRPDestinationTag.acceptsEditableInput("١"))
        #expect(try XRPDestinationTag.parsed(" 42 ") == 42)
        #expect(try XRPDestinationTag.parsed(" ") == nil)
        #expect(throws: SendPaymentRequestError.invalidReference) {
            try XRPDestinationTag.parsed("4294967296")
        }
        #expect(
            XRPAmount.decodedCurrency(
                "5553440000000000000000000000000000000000"
            ) == "USD"
        )
        #expect(
            XRPAddress.signingDestination(
                classicAddress: "rnBFvgZphmN39GWzUJeUitaP22Fr9be75H",
                destinationTag: 0
            ) == "X76UnYEMbQfEs3mUqgtjp4zFy9exgTsM93nriVZAPufrpE3"
        )
    }

    @Test
    func mainnetXAddressesResolveToClassicAddressAndOneTag() throws {
        let classic = "rnBFvgZphmN39GWzUJeUitaP22Fr9be75H"
        let tagged =
            "X76UnYEMbQfEs3mUqgtjp4zFy9exgThRj7XVZ6UxsdrBptF"
        let taggedZero =
            "X76UnYEMbQfEs3mUqgtjp4zFy9exgTsM93nriVZAPufrpE3"
        let noTag =
            "X76UnYEMbQfEs3mUqgtjp4zFy9exgSxWAqcQwu9z2r5d7Tm"
        let malformedNoTag =
            "X76UnYEMbQfEs3mUqgtjp4zFy9exgSybYUh1taorDmyP7YL"

        #expect(
            XRPAddress.resolvedDestination(
                address: tagged,
                explicitTag: nil
            ) == .init(classicAddress: classic, destinationTag: 12_345)
        )
        #expect(
            XRPAddress.resolvedDestination(
                address: tagged,
                explicitTag: 12_345
            ) == .init(classicAddress: classic, destinationTag: 12_345)
        )
        #expect(
            XRPAddress.resolvedDestination(
                address: taggedZero,
                explicitTag: nil
            ) == .init(classicAddress: classic, destinationTag: 0)
        )
        #expect(
            XRPAddress.resolvedDestination(
                address: noTag,
                explicitTag: nil
            ) == .init(classicAddress: classic, destinationTag: nil)
        )
        #expect(
            XRPAddress.resolvedDestination(
                address: classic,
                explicitTag: 42
            ) == .init(classicAddress: classic, destinationTag: 42)
        )

        #expect(
            XRPAddress.resolvedDestination(
                address: tagged,
                explicitTag: 9
            ) == nil
        )
        #expect(
            XRPAddress.resolvedDestination(
                address: noTag,
                explicitTag: 0
            ) == nil
        )
        #expect(
            XRPAddress.resolvedDestination(
                address: malformedNoTag,
                explicitTag: nil
            ) == nil
        )
        #expect(XRPAddress.validatedClassic(tagged) == nil)
        #expect(XRPAddress.validatedClassic(classic) == classic)
    }

    @Test
    func rippleUSDUsesTheOfficialCurrencyAndIssuerIdentity() throws {
        Self.installRemoteRippleUSDCatalog()
        let metadata = try #require(
            XRPTokenCatalog.metadata(
                currency: Self.rippleUSDCurrencyCode,
                issuer: Self.rippleUSDIssuer
            )
        )

        #expect(metadata.name == "Ripple USD")
        #expect(metadata.symbol == "RLUSD")
        #expect(metadata.isVerified)
        #expect(metadata.identity == Self.rippleUSDIdentity)
        #expect(
            AssetIdentityKey.make(
                networkID: XRPConstants.networkID,
                contractAddress: metadata.identity
            ) == "xrp:\(Self.rippleUSDIdentity)"
        )
        let selection = try #require(
            ReceiveAssetCatalog.selection(
                assetIdentity: "xrp:\(Self.rippleUSDIdentity)"
            )
        )
        #expect(
            selection.variant.logoSource.remoteLogoURL?.absoluteString
                == Self.rippleUSDLogoURL
        )
    }

    @Test
    func rippleUSDBrandingCannotBeClaimedByAnotherIssuer() {
        Self.installRemoteRippleUSDCatalog()
        let alternateIdentity =
            "RLUSD:rHb9CJAWyB4rj91VRWn96DkukG4bwdtyTh"
        #expect(
            XRPTokenCatalog.metadata(
                currency: "RLUSD",
                issuer: "rHb9CJAWyB4rj91VRWn96DkukG4bwdtyTh"
            ) == nil
        )
        #expect(
            ReceiveAssetCatalog.selection(
                assetIdentity: "xrp:\(alternateIdentity)"
            ) == nil
        )
    }

    @Test
    func receiveCatalogPlacesRippleUSDAfterNativeXRP() throws {
        Self.installRemoteRippleUSDCatalog()
        let assets = ReceiveAssetCatalog.tokens(
            for: XRPConstants.networkID
        )
        let native = try #require(assets.first)
        let rlusd = try #require(
            assets.first(where: { $0.symbol == "RLUSD" })
        )

        #expect(native.symbol == "XRP")
        #expect(rlusd.name == "Ripple USD")
        #expect(rlusd.variants.count == 1)
        #expect(
            rlusd.variants[0].contractAddress
                == Self.rippleUSDIdentity
        )
    }

    private static func installRemoteRippleUSDCatalog() {
        let native = ReceiveToken.nativeAsset(
            for: ReceiveNetworkCatalog.catalogNetwork(
                for: XRPConstants.networkID
            )!
        )
        let rippleUSD = ReceiveToken(
            id: "xrp:\(rippleUSDIdentity)",
            name: "Ripple USD",
            symbol: "RLUSD",
            rank: 30_001,
            isStablecoin: true,
            variants: [
                ReceiveTokenVariant(
                    networkID: XRPConstants.networkID,
                    contractAddress: rippleUSDIdentity,
                    decimals: 15,
                    networkRank: 1,
                    logoURL: rippleUSDLogoURL,
                    marketDataID: "ripple-usd"
                )
            ]
        )
        ReceiveAssetCatalogRuntime.install([native, rippleUSD], revision: 1)
    }

    @Test
    func walletCoreDerivesCanonicalClassicXRPAccount() throws {
        let wallet = try #require(
            BIP39Mnemonic.hdWallet(mnemonic: Self.mnemonic)
        )
        let key = try #require(
            wallet.getKey(
                coin: .xrp,
                derivationPath: XRPConstants.derivationPath
            )
        )
        let address = CoinType.xrp.deriveAddress(privateKey: key)

        #expect(XRPAddress.validated(address) == address)
        #expect(CoinType.xrp.validate(address: address))
        #expect(XRPAddress.validated("rInvalid") == nil)
        #expect(XRPConstants.derivationPath == "m/44'/144'/0'/0/0")
    }

    @Test
    func receiveRoutingNeverFallsBackToAnEVMAddress() throws {
        let addresses = try Self.makeAddresses()
        let network = try #require(
            ReceiveNetworkCatalog.network(for: .xrp)
        )
        let evmAddress = "0x1111111111111111111111111111111111111111"

        #expect(
            ReceiveAddressResolver.requiresIndependentAddress(for: .xrp)
        )
        #expect(
            !ReceiveAddressResolver.requiresIndependentAddress(
                for: .ethereum
            )
        )
        #expect(
            ReceiveAddressResolver.validatedIndependentAddress(
                addresses.sender,
                for: .xrp
            ) == addresses.sender
        )
        #expect(
            ReceiveAddressResolver.validatedIndependentAddress(
                evmAddress,
                for: .xrp
            ) == nil
        )
        #expect(
            ReceiveAddressResolver.paymentPayload(
                address: addresses.sender,
                network: network,
                contractAddress: nil
            ) == addresses.sender
        )
    }

    @Test
    func issuedXRPAssetsUseTheirStoredClassicReceiveAddress() throws {
        let addresses = try Self.makeAddresses()
        let asset = WalletAsset(
            id: "xrp:USD:\(addresses.issuer)",
            name: "USD",
            symbol: "USD",
            logoSource: .unavailable,
            network: .xrp,
            balance: 12.5,
            fiatValue: 12.5,
            receiveAddress: addresses.sender
        )

        let preparation = ReceiveAssetSelectionPreparation.make(
            walletAssets: [asset],
            transactions: [],
            capabilities: .fullWallet
        )

        #expect(preparation.baseDirectWalletAssets == [asset])
    }

    @Test
    func paymentURIParsesAmountAndOptionalNumericMemo() throws {
        let addresses = try Self.makeAddresses()
        let request = try SendPaymentRequestParser.parse(
            "xrp:\(addresses.recipient)?amount=1.25&dt=987654"
        )

        #expect(request.source == .xrpURI)
        #expect(request.recipient == addresses.recipient)
        #expect(request.candidateNetworkIDs == [XRPConstants.networkID])
        #expect(request.requestedNetworkID == XRPConstants.networkID)
        #expect(request.requestedAsset == .native)
        #expect(request.requestedAmount == .userUnits("1.25"))
        #expect(request.memo == "987654")
        #expect(
            SendAddressValidator.isValid(
                addresses.recipient,
                for: XRPConstants.networkID
            )
        )
    }

    @Test
    func paymentURIRejectsDuplicateOrInvalidDestinationTags() throws {
        let address = try Self.makeAddresses().recipient
        #expect(throws: SendPaymentRequestError.duplicateParameter) {
            try SendPaymentRequestParser.parse(
                "xrp:\(address)?dt=1&destination_tag=2"
            )
        }
        #expect(throws: SendPaymentRequestError.invalidReference) {
            try SendPaymentRequestParser.parse(
                "xrp:\(address)?dt=4294967296"
            )
        }
    }

    @Test
    func providerLoadsNativeTrustLineAndPaymentHistory() async throws {
        let addresses = try Self.makeAddresses()
        let fixture = XRPProviderFixture(
            mode: .snapshot,
            sender: addresses.sender,
            recipient: addresses.recipient,
            issuer: addresses.issuer
        )
        let client = try Self.makeClient(fixture: fixture)
        let probe = XRPBalanceSnapshotProbe()
        let snapshot = try await client.loadSnapshot(
            material: XRPAccountMaterial(
                address: addresses.sender,
                publicKey: "fixture",
                derivationPath: XRPConstants.derivationPath
            )
        ) { partial in
            await probe.record(partial)
        }

        #expect(await probe.recordCount == 2)
        #expect(await probe.historyCount == 0)
        #expect(await probe.firstBalanceCount == 1)
        #expect(await probe.latestBalanceCount == 2)
        #expect(!(await probe.firstBalancesAreAuthoritative))
        #expect(await probe.latestBalancesAreAuthoritative)
        #expect(snapshot.balancesAreAuthoritative)
        #expect(snapshot.historyIsAuthoritative)
        #expect(snapshot.providerFailureCodes.isEmpty)
        #expect(snapshot.balances.count == 2)
        #expect(snapshot.balances[0].amountText == "50")
        #expect(snapshot.balances[0].atomicAmount == "50000000")
        let token = try #require(snapshot.balances.first { !$0.isNative })
        #expect(token.metadata?.currency == "USD")
        #expect(token.metadata?.issuer == addresses.issuer)
        #expect(token.amountText == "12.5")
        #expect(snapshot.history.count == 2)
        #expect(snapshot.history[0].signedAmountText == "-1")
        #expect(snapshot.history[0].destinationTag == 42)
        #expect(snapshot.history[1].metadata?.currency == "USD")
        #expect(snapshot.history[1].signedAmountText == "2.5")
        #expect(snapshot.historyLedgerWatermark == 100)
        let methods = await fixture.recordedMethods()
        #expect(Set(methods) == ["account_info", "account_lines", "account_tx"])
    }

    @Test
    func incrementalHistoryUsesNextValidatedLedger() async throws {
        let addresses = try Self.makeAddresses()
        let fixture = XRPProviderFixture(
            mode: .snapshot,
            sender: addresses.sender,
            recipient: addresses.recipient,
            issuer: addresses.issuer
        )
        let client = try Self.makeClient(fixture: fixture)

        _ = try await client.loadSnapshot(
            material: XRPAccountMaterial(
                address: addresses.sender,
                publicKey: "fixture",
                derivationPath: XRPConstants.derivationPath
            ),
            historyLedgerMinimum: 98
        )

        #expect(await fixture.accountTransactionLedgerMinimum() == 98)
    }

    @Test
    func unfundedProviderAccountProducesAuthoritativeNativeZero()
        async throws
    {
        let addresses = try Self.makeAddresses()
        let fixture = XRPProviderFixture(
            mode: .empty,
            sender: addresses.sender,
            recipient: addresses.recipient,
            issuer: addresses.issuer
        )
        let client = try Self.makeClient(fixture: fixture)
        let snapshot = try await client.loadSnapshot(
            material: XRPAccountMaterial(
                address: addresses.sender,
                publicKey: "fixture",
                derivationPath: XRPConstants.derivationPath
            )
        )

        #expect(snapshot.balancesAreAuthoritative)
        #expect(snapshot.historyIsAuthoritative)
        #expect(snapshot.balances.count == 1)
        #expect(snapshot.balances[0].amountText == "0")
        #expect(snapshot.balances[0].atomicAmount == "0")
        #expect(snapshot.history.isEmpty)
    }

    @Test
    func transportUsesXRPLParameterArrayAndPreservesRPCFailure()
        async throws
    {
        let executor = XRPTransportProbe()
        let transport = try XRPJSONRPCTransport(
            endpoint: try #require(URL(string: "https://example.test/xrp"))
        ) { request in
            try await executor.response(for: request)
        }
        do {
            _ = try await transport.request(
                method: "account_info",
                parameters: ["account": .string("fixture")]
            )
            Issue.record("Expected fixture RPC failure.")
        } catch let error as XRPProviderError {
            guard case let .rpc(code, message) = error else {
                Issue.record("Unexpected transport error: \(error)")
                return
            }
            #expect(code == -32_600)
            #expect(message == "fixture rejected")
        }
        #expect(await executor.method == "account_info")
        #expect(await executor.parameterCount == 1)
        #expect(await executor.firstAccount == "fixture")
    }

    @Test
    func snapshotPersistenceStoresBalancesTokensHistoryAndTag()
        async throws
    {
        let addresses = try Self.makeAddresses()
        let database = try WalletDatabase.temporary()
        let walletID = "xrp-persistence-wallet"
        let accountID = "\(walletID):xrp:0"
        let now = Date().timeIntervalSince1970
        try await database.pool.write { connection in
            try DBWalletRecord(
                id: walletID,
                profileID: WalletDatabase.defaultProfileID,
                name: "XRP Persistence Wallet",
                kind: DatabaseWalletKind.created.rawValue,
                secretKeyReference: nil,
                isSelected: false,
                sortOrder: 0,
                createdAt: now,
                updatedAt: now,
                lastOpenedAt: nil,
                archivedAt: nil
            ).insert(connection)
            try DBWalletAccountRecord(
                id: accountID,
                walletID: walletID,
                networkID: XRPConstants.networkID,
                address: addresses.sender,
                normalizedAddress: addresses.sender,
                label: XRPConstants.accountLabel,
                derivationPath: XRPConstants.derivationPath,
                accountIndex: 0,
                publicKey: "fixture",
                isWatchOnly: false,
                isEnabled: true,
                createdAt: now,
                updatedAt: now,
                lastSyncedAt: nil
            ).insert(connection)
        }
        let token = XRPTokenMetadata(
            currency: "USD",
            issuer: addresses.issuer,
            name: "USD",
            symbol: "USD",
            decimals: 15,
            isVerified: false,
            rank: 10_000
        )
        try await database.saveXRPSnapshot(
            XRPWalletSnapshot(
                material: XRPAccountMaterial(
                    address: addresses.sender,
                    publicKey: "fixture",
                    derivationPath: XRPConstants.derivationPath
                ),
                balances: [
                    XRPAssetBalance(
                        metadata: nil,
                        amountText: "50",
                        atomicAmount: "50000000"
                    ),
                    XRPAssetBalance(
                        metadata: token,
                        amountText: "12.5",
                        atomicAmount: nil
                    )
                ],
                history: [
                    XRPHistoryItem(
                        id: "A1",
                        transactionHash: "A1",
                        timestamp: now,
                        failed: false,
                        sender: addresses.sender,
                        recipient: addresses.recipient,
                        destinationTag: 42,
                        metadata: nil,
                        signedAmountText: "-1",
                        networkFeeDrops: "10",
                        ledgerIndex: 100,
                        sequence: 7
                    )
                ],
                balancesAreAuthoritative: true,
                historyIsAuthoritative: true,
                providerFailureCodes: [],
                historyLedgerWatermark: 100
            ),
            walletID: walletID
        )

        let stored = try await database.pool.read { connection in
            (
                native: try DBAccountAssetRecord.fetchOne(
                    connection,
                    key: [
                        "accountID": accountID,
                        "assetID": XRPConstants.nativeAssetID
                    ]
                ),
                token: try DBAccountAssetRecord.fetchOne(
                    connection,
                    key: ["accountID": accountID, "assetID": token.assetID]
                ),
                transaction: try DBTransactionRecord
                    .filter(Column("accountID") == accountID)
                    .fetchOne(connection)
            )
        }
        #expect(stored.native?.balance == "50")
        #expect(stored.native?.balanceAtomic == "50000000")
        #expect(stored.token?.balance == "12.5")
        #expect(stored.transaction?.assetAmount == "-1")
        #expect(stored.transaction?.networkFee == "0.00001")
        #expect(stored.transaction?.inputData == "42")
        #expect(stored.transaction?.methodName == "DestinationTag")
    }

    @Test
    func nativeSendSignsSubmitsAndCarriesOptionalDestinationTag()
        async throws
    {
        let context = try Self.makeSigningContext()
        let fixture = XRPProviderFixture(
            mode: .send,
            sender: context.sender,
            recipient: context.recipient,
            issuer: context.issuer
        )
        let client = try Self.makeClient(fixture: fixture)
        let service = SendXRPTransactionService(
            api: client,
            quoteLoader: { _ in Self.feeQuote() }
        )
        let receipt = try await service.submit(
            draft: Self.nativeDraft(
                sender: context.sender,
                recipient: context.recipient,
                memo: "42"
            ),
            material: context.material
        )

        #expect(receipt.networkID == XRPConstants.networkID)
        #expect(receipt.fromAddress == context.sender)
        #expect(receipt.toAddress == context.recipient)
        #expect(receipt.amount == "1")
        #expect(receipt.amountAtomic == "1000000")
        #expect(receipt.networkFeeAtomic == "10")
        #expect(receipt.networkFee == "0.00001")
        #expect(receipt.transactionHash.count == 64)
        #expect(await fixture.submitBlobLength() > 0)
    }

    @Test
    func issuedTokenSendRequiresAndUsesRecipientTrustLine()
        async throws
    {
        let context = try Self.makeSigningContext()
        let fixture = XRPProviderFixture(
            mode: .send,
            sender: context.sender,
            recipient: context.recipient,
            issuer: context.issuer
        )
        let client = try Self.makeClient(fixture: fixture)
        let service = SendXRPTransactionService(
            api: client,
            quoteLoader: { _ in Self.feeQuote() }
        )
        let receipt = try await service.submit(
            draft: Self.tokenDraft(
                sender: context.sender,
                recipient: context.recipient,
                issuer: context.issuer
            ),
            material: context.material
        )

        #expect(receipt.assetID == "xrp:USD:\(context.issuer)")
        #expect(receipt.assetSymbol == "USD")
        #expect(receipt.amount == "2.5")
        #expect(receipt.amountAtomic == "2.5")
        #expect(await fixture.submitBlobLength() > 0)
    }

    private static func makeClient(
        fixture: XRPProviderFixture
    ) throws -> XRPAPIClient {
        XRPAPIClient(
            transport: try XRPJSONRPCTransport(
                endpoint: try #require(
                    URL(string: "https://example.test/xrp")
                )
            ) { request in
                try await fixture.response(for: request)
            }
        )
    }

    private static func makeAddresses() throws -> (
        sender: String,
        recipient: String,
        issuer: String
    ) {
        let wallet = try #require(
            BIP39Mnemonic.hdWallet(mnemonic: Self.mnemonic)
        )
        func address(_ index: Int) throws -> String {
            let key = try #require(
                wallet.getKey(
                    coin: .xrp,
                    derivationPath: "m/44'/144'/\(index)'/0/0"
                )
            )
            return CoinType.xrp.deriveAddress(privateKey: key)
        }
        return (try address(0), try address(1), try address(2))
    }

    private static func makeSigningContext() throws -> (
        sender: String,
        recipient: String,
        issuer: String,
        material: SendResolvedSigningMaterial
    ) {
        let wallet = try #require(
            BIP39Mnemonic.hdWallet(mnemonic: Self.mnemonic)
        )
        let key = try #require(
            wallet.getKey(
                coin: .xrp,
                derivationPath: XRPConstants.derivationPath
            )
        )
        let addresses = try makeAddresses()
        let account = DBWalletAccountRecord(
            id: "wallet:xrp:0",
            walletID: "wallet",
            networkID: XRPConstants.networkID,
            address: addresses.sender,
            normalizedAddress: addresses.sender,
            label: XRPConstants.accountLabel,
            derivationPath: XRPConstants.derivationPath,
            accountIndex: 0,
            publicKey: key.getPublicKeySecp256k1(compressed: true).description,
            isWatchOnly: false,
            isEnabled: true,
            createdAt: 0,
            updatedAt: 0,
            lastSyncedAt: nil
        )
        return (
            addresses.sender,
            addresses.recipient,
            addresses.issuer,
            SendResolvedSigningMaterial(
                walletID: "wallet",
                account: account,
                privateKey: key.data
            )
        )
    }

    private static func nativeDraft(
        sender: String,
        recipient: String,
        memo: String?
    ) -> SendDraft {
        let request = SendPaymentRequest.manualEntry(
            networkID: XRPConstants.networkID
        ).replacingMemo(memo)
        return SendDraft(
            request: request,
            asset: SendAssetChoice(
                id: XRPConstants.nativeAssetID,
                name: "XRP",
                symbol: XRPConstants.nativeSymbol,
                networkID: XRPConstants.networkID,
                networkName: "XRP",
                blockchain: .xrp,
                contractAddress: nil,
                decimals: XRPConstants.decimals,
                logoSource: .nativeCoin(blockchain: .xrp),
                networkLogoSource: .network(blockchain: .xrp),
                balance: 50,
                fiatValue: 0,
                balanceAtomic: "50000000",
                sourceAddress: sender
            ),
            recipient: recipient,
            amount: "1",
            note: nil
        )
    }

    private static func tokenDraft(
        sender: String,
        recipient: String,
        issuer: String
    ) -> SendDraft {
        SendDraft(
            request: .manualEntry(networkID: XRPConstants.networkID),
            asset: SendAssetChoice(
                id: "xrp:USD:\(issuer)",
                name: "USD",
                symbol: "USD",
                networkID: XRPConstants.networkID,
                networkName: "XRP",
                blockchain: .xrp,
                contractAddress: "USD:\(issuer)",
                decimals: 15,
                logoSource: .unavailable,
                networkLogoSource: .network(blockchain: .xrp),
                balance: 12.5,
                fiatValue: 0,
                sourceAddress: sender
            ),
            recipient: recipient,
            amount: "2.5",
            note: nil
        )
    }

    private static func feeQuote() -> SendNetworkFeeQuote {
        SendNetworkFeeQuote(
            networkID: XRPConstants.networkID,
            provider: "fixture",
            fetchedAt: Date(),
            expiresAt: Date().addingTimeInterval(60),
            tiers: [
                SendNetworkFeeTier(
                    preset: .fastest,
                    model: .xrpProtocol,
                    primaryValue: "10",
                    secondaryValue: nil
                )
            ]
        )
    }
}
