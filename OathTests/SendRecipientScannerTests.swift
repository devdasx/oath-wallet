@preconcurrency import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import Testing
import UIKit
import VisionKit
@testable import Aperture

struct NativeQRCodeScannerFailureTests {
    @Test
    func authorizationAndVisionKitFailuresMapPrecisely() {
        #expect(
            NativeQRCodeScannerFailure.authorizationFailure(for: .denied)
                == .cameraPermissionDenied
        )
        #expect(
            NativeQRCodeScannerFailure.authorizationFailure(for: .restricted)
                == .cameraPermissionRestricted
        )
        #expect(
            NativeQRCodeScannerFailure.authorizationFailure(for: .authorized)
                == nil
        )
        #expect(
            NativeQRCodeScannerFailure.visionKitFailure(for: .unsupported)
                == .cameraUnavailable
        )
        #expect(
            NativeQRCodeScannerFailure.visionKitFailure(
                for: .cameraRestricted
            ) == .cameraPermissionRestricted
        )
    }

    @Test
    func failurePresentationKeepsCausesDistinct() {
        let unavailableTitle = "fixture.scanner.unavailable.title"
        let unavailableMessage = "fixture.scanner.unavailable.message"
        let permission = NativeQRCodeScannerFailurePresentation.resolve(
            .cameraPermissionDenied,
            unavailableTitleKey: unavailableTitle,
            unavailableMessageKey: unavailableMessage
        )
        let restricted = NativeQRCodeScannerFailurePresentation.resolve(
            .cameraPermissionRestricted,
            unavailableTitleKey: unavailableTitle,
            unavailableMessageKey: unavailableMessage
        )
        let unavailable = NativeQRCodeScannerFailurePresentation.resolve(
            .cameraUnavailable,
            unavailableTitleKey: unavailableTitle,
            unavailableMessageKey: unavailableMessage
        )
        let configuration = NativeQRCodeScannerFailurePresentation.resolve(
            .configurationFailed,
            unavailableTitleKey: unavailableTitle,
            unavailableMessageKey: unavailableMessage
        )

        #expect(permission.action == .openSettings)
        #expect(restricted.action == nil)
        #expect(unavailable.action == nil)
        #expect(configuration.action == .retry)
        #expect(permission.messageKey != restricted.messageKey)
        #expect(unavailable.titleKey == unavailableTitle)
        #expect(unavailable.messageKey == unavailableMessage)
        #expect(configuration.titleKey != unavailable.titleKey)
        #expect(configuration.messageKey != unavailable.messageKey)
    }

    @Test @MainActor
    func invalidPreviewReportsConfigurationFailure() async {
        let failure = await withCheckedContinuation {
            (continuation:
             CheckedContinuation<NativeQRCodeScannerFailure, Never>) in
            let controller = NativeQRCodeCaptureViewController(
                onPayload: { _ in false },
                onFailure: { failure in
                    continuation.resume(returning: failure)
                },
                previewViewFactory: { UIView() }
            )
            controller.loadViewIfNeeded()
        }

        #expect(failure == .configurationFailed)
    }
}

struct SendRecipientScannerTests {
    private static let evmAddress =
        "0x71C7656EC7ab88b098defB751B7401B5f6d8976F"
    private static let bitcoinAddress =
        "bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4"
    private static let bitcoinCashAddress =
        "qpm2qsznhks23z7629mms6s4cwef74vcwvy22gdx6a"
    private static let litecoinAddress =
        "LT2KVaAy1ppRuxRgrS5RNU3vBsy7RibPeA"
    private static let dogecoinAddress =
        "DD4KSSuBJqcjuTcvUg1CgUKeurPUFeEZkE"
    private static let solanaAddress =
        "mvines9iiHiQTysrwkJjGf2gb9Ex9jXJX8ns3qwf2kN"
    private static let tronAddress =
        "TNPeeaaFB7K9cmo4uQpcU32zGK8G1NYqeL"
    private static let tonAddress =
        "UQBm--PFwDv1yCeS-QTJ-L8oiUpqo9IT1BwgVptlSq3ts4DV"
    private static let suiAddress =
        "0xdfc88cd008c89a4a4a60199b27e503cd5e248b5191be8e953856b43e87ae3393"
    private static let aptosAddress =
        "0xd503b95164384a5ebbccbb5c4bdc8b4a5893d9651e9953abda8e1c22fcc1181d"
    private static let nearAddress = "alice.near"
    private static let xrpAddress =
        "rnBFvgZphmN39GWzUJeUitaP22Fr9be75H"
    private static let stellarAddress =
        "GA5ZSEJYB37JRC5AVCIA5MOP4RHTM335X2KGX3IHOJAPP5RE34K4KZVN"

    @Test
    func representativeMainnetAddressWorksForEverySupportedNetwork()
        throws
    {
        let supported = AssetNetworkSelectorOption.allSupported
        #expect(supported.count == 26)
        #expect(Set(supported.map(\.id)).count == supported.count)

        for network in supported {
            let fixture = Self.address(
                for: network.blockchain
            )
            let recipient = try SendRecipientScanPreparation.recipient(
                from: fixture,
                selectedNetworkID: network.id
            )

            #expect(
                recipient == fixture,
                "Recipient fixture failed for \(network.id)."
            )
            #expect(
                SendAddressValidator.isValid(
                    recipient,
                    for: network.id
                ),
                "Recipient was not valid for \(network.id)."
            )
        }
    }

    @Test
    func paymentURIContributesOnlyItsRecipient() throws {
        let bitcoin = try SendRecipientScanPreparation.recipient(
            from: "bitcoin:\(Self.bitcoinAddress)?amount=0.25&label=Invoice",
            selectedNetworkID: BitcoinFamilyChain.bitcoin.networkID
        )
        let xrp = try SendRecipientScanPreparation.recipient(
            from: "xrp:\(Self.xrpAddress)?amount=10&dt=42",
            selectedNetworkID: XRPConstants.networkID
        )

        #expect(bitcoin == Self.bitcoinAddress)
        #expect(xrp == Self.xrpAddress)
    }

    @Test
    func bareEVMAddressUsesCurrentEVMNetwork() throws {
        for network in AssetNetworkSelectorOption.allSupported
        where network.blockchain.isEVM {
            #expect(
                try SendRecipientScanPreparation.recipient(
                    from: Self.evmAddress,
                    selectedNetworkID: network.id
                ) == Self.evmAddress
            )
        }
    }

    @Test
    func explicitlyPinnedEVMRequestCannotCrossNetworks() throws {
        #expect(
            throws:
                SendRecipientScanError.invalidForSelectedNetwork
        ) {
            try SendRecipientScanPreparation.recipient(
                from: "ethereum:\(Self.evmAddress)@1?value=1",
                selectedNetworkID: "polygon"
            )
        }

        #expect(
            try SendRecipientScanPreparation.recipient(
                from: "ethereum:\(Self.evmAddress)@1?value=1",
                selectedNetworkID: "eth"
            ) == Self.evmAddress
        )
    }

    @Test
    func chainSpecificAddressesCannotCrossNetworks() {
        let mismatches = [
            (Self.bitcoinAddress, BitcoinFamilyChain.litecoin.networkID),
            (Self.litecoinAddress, BitcoinFamilyChain.bitcoin.networkID),
            (Self.tronAddress, SolanaConstants.networkID),
            (Self.solanaAddress, TronConstants.networkID),
            (Self.tonAddress, SuiConstants.networkID),
            (Self.stellarAddress, XRPConstants.networkID)
        ]

        for (payload, selectedNetworkID) in mismatches {
            #expect(
                throws:
                    SendRecipientScanError.invalidForSelectedNetwork
            ) {
                try SendRecipientScanPreparation.recipient(
                    from: payload,
                    selectedNetworkID: selectedNetworkID
                )
            }
        }
    }

    @Test
    func namesAndTestnetAddressesAreNotAcceptedAsScannedAddresses() {
        #expect(
            throws:
                SendRecipientScanError.invalidForSelectedNetwork
        ) {
            try SendRecipientScanPreparation.recipient(
                from: "vitalik.eth",
                selectedNetworkID: "eth"
            )
        }

        #expect(throws: SendPaymentRequestError.invalidMainnetAddress) {
            try SendRecipientScanPreparation.recipient(
                from: "tb1qw508d6qejxtdg4y5r3zarvary0c5xw7kxpjzsx",
                selectedNetworkID: BitcoinFamilyChain.bitcoin.networkID
            )
        }
    }

    @Test
    func renderedQRCodeDecodesAndPassesTheSameNetworkPolicy()
        async throws
    {
        let payload = "litecoin:\(Self.litecoinAddress)?amount=1"
        let pngData = try #require(Self.qrCodePNG(payload: payload))
        let decoded = try #require(
            try await QRCodeImageDecoder.firstPayload(
                in: pngData
            )
        )

        #expect(decoded == payload)
        #expect(
            try SendRecipientScanPreparation.recipient(
                from: decoded,
                selectedNetworkID:
                    BitcoinFamilyChain.litecoin.networkID
            ) == Self.litecoinAddress
        )
    }

    @Test
    func liveScannerUsesVisionKitWhenHardwareSupportsIt() {
        #expect(
            NativeQRCodeScannerBackend.preferred(
                visionKitSupported: true
            ) == .visionKit
        )
        #expect(
            NativeQRCodeScannerBackend.preferred(
                visionKitSupported: false
            ) == .avFoundation
        )
    }

    @Test
    func repeatTransactionBuildsExactDraftAndRoutesInvalidSelfTransfersToRecipient()
        throws
    {
        let supported = AssetNetworkSelectorOption.allSupported
        #expect(supported.count == 26)

        for network in supported {
            let recipient = Self.address(for: network.blockchain)
            let asset = Self.repeatNativeAsset(for: network)
            let transaction = Self.repeatTransaction(
                network: network,
                recipient: recipient,
                inputData: network.id == XRPConstants.networkID
                    ? "42"
                    : network.id == StellarConstants.networkID
                        ? "coffee"
                        : nil
            )
            let plan = try WalletTransactionRepeatPreparation.prepare(
                transaction: transaction,
                walletAssets: [asset],
                capabilities: .fullWallet
            ).get()

            #expect(plan.walletAsset.id == asset.id)
            #expect(plan.draft.asset.id == asset.id)
            #expect(plan.draft.recipient == recipient)
            #expect(plan.draft.usesMaximumBalance == false)
            // These fixtures intentionally repeat to the source address.
            // TRX/XRP must open Recipient; supported self-transfers still review.
            if ["tron", "xrp"].contains(network.id) {
                guard case let .recipient(routedDraft, failure) = plan.initialRoute else {
                    Issue.record("Forbidden repeated self-transfer skipped Recipient")
                    continue
                }
                #expect(routedDraft == plan.draft)
                #expect(failure?.recipientIssue == .selfTransferNotSupported)
            } else {
                #expect(plan.initialRoute == .review(plan.draft))
            }
            let amount = try #require(plan.draft.amount)
            #expect(
                try SendAtomicAmount.fromUserUnits(
                    amount,
                    decimals: plan.draft.asset.decimals
                ) == "100",
                "Repeat lost atomic precision for \(network.id)."
            )
            if network.id == XRPConstants.networkID {
                #expect(plan.draft.request.memo == "42")
            } else if network.id == StellarConstants.networkID {
                #expect(plan.draft.request.memo == "coffee")
            } else {
                #expect(plan.draft.request.memo == nil)
            }
        }
    }

    @Test
    func repeatTransactionUsesExactContractInsteadOfTicker() throws {
        let contract =
            "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48"
        let ethereum = try #require(
            AssetNetworkSelectorOption.allSupported.first {
                $0.id == "eth"
            }
        )
        let ethereumToken = WalletAsset(
            id: AssetIdentityKey.make(
                networkID: ethereum.id,
                contractAddress: contract
            ),
            name: "USD Coin",
            symbol: "USDC",
            logoSource: .catalogToken(
                blockchain: ethereum.blockchain,
                contractAddress: contract,
                logoURL: nil
            ),
            network: ethereum.blockchain,
            balance: 2,
            fiatValue: 2,
            balanceText: "2",
            balanceAtomic: "2000000",
            decimals: 6,
            receiveAddress: Self.evmAddress
        )
        let polygonDecoy = WalletAsset(
            id: AssetIdentityKey.make(
                networkID: "polygon",
                contractAddress: contract
            ),
            name: "USD Coin",
            symbol: "USDC",
            logoSource: .catalogToken(
                blockchain: .polygon,
                contractAddress: contract,
                logoURL: nil
            ),
            network: .polygon,
            balance: 100,
            fiatValue: 100,
            balanceText: "100",
            balanceAtomic: "100000000",
            decimals: 6,
            receiveAddress: Self.evmAddress
        )
        let transaction = Self.repeatTransaction(
            network: ethereum,
            recipient: Self.evmAddress,
            contractAddress: contract,
            tokenDecimals: 6,
            amountText: "-1.234567",
            amountAtomic: nil,
            symbol: "USDC"
        )

        let plan = try WalletTransactionRepeatPreparation.prepare(
            transaction: transaction,
            walletAssets: [polygonDecoy, ethereumToken],
            capabilities: .fullWallet
        ).get()

        #expect(plan.draft.asset.id == ethereumToken.id)
        #expect(plan.draft.amount == "1.234567")
    }

    @Test
    func repeatTransactionRepairsLegacyEVMContractRecipient() throws {
        let contract =
            "0xc2132d05d31c914a87c6611c10748aeb04b58e8f"
        let recipient =
            "0x2132d05d31c914a87c6611c10748aeb04b58e8f0"
        let polygon = try #require(
            AssetNetworkSelectorOption.allSupported.first {
                $0.id == "polygon"
            }
        )
        let token = WalletAsset(
            id: AssetIdentityKey.make(
                networkID: polygon.id,
                contractAddress: contract
            ),
            name: "USDT0",
            symbol: "USDT0",
            logoSource: .catalogToken(
                blockchain: polygon.blockchain,
                contractAddress: contract,
                logoURL: nil
            ),
            network: polygon.blockchain,
            balance: 10,
            fiatValue: 10,
            balanceText: "10",
            balanceAtomic: "10000000",
            decimals: 6,
            receiveAddress: Self.evmAddress
        )
        let encodedRecipient = String(repeating: "0", count: 24)
            + String(recipient.dropFirst(2))
        let transaction = Self.repeatTransaction(
            network: polygon,
            recipient: contract.uppercased(),
            contractAddress: contract,
            tokenDecimals: 6,
            amountText: "-4.99",
            amountAtomic: "4990000",
            symbol: "USDT0",
            inputData: "0xa9059cbb\(encodedRecipient)"
                + String(repeating: "0", count: 63) + "1"
        )

        let plan = try WalletTransactionRepeatPreparation.prepare(
            transaction: transaction,
            walletAssets: [token],
            capabilities: .fullWallet
        ).get()

        #expect(plan.draft.recipient == recipient)

        let undecodable = Self.repeatTransaction(
            network: polygon,
            recipient: contract,
            contractAddress: contract,
            tokenDecimals: 6,
            amountText: "-4.99",
            amountAtomic: "4990000",
            symbol: "USDT0",
            inputData: "0xdeadbeef"
        )
        guard case .failure(.missingTransactionDetails) =
            WalletTransactionRepeatPreparation.prepare(
                transaction: undecodable,
                walletAssets: [token],
                capabilities: .fullWallet
            )
        else {
            Issue.record(
                "Repeat must not send a token to its own contract address."
            )
            return
        }
    }

    @Test
    func repeatTransactionRejectsInsufficientOrNonOutgoingActivity()
        throws
    {
        let dogecoin = try #require(
            AssetNetworkSelectorOption.allSupported.first {
                $0.id == BitcoinFamilyChain.dogecoin.networkID
            }
        )
        let recipient = Self.address(for: dogecoin.blockchain)
        let insufficientAsset = Self.repeatNativeAsset(
            for: dogecoin,
            balanceAtomic: "99"
        )
        let transaction = Self.repeatTransaction(
            network: dogecoin,
            recipient: recipient
        )

        guard case .failure(.insufficientBalance) =
            WalletTransactionRepeatPreparation.prepare(
                transaction: transaction,
                walletAssets: [insufficientAsset],
                capabilities: .fullWallet
            ) else {
            Issue.record("Repeat must reject a balance below the amount.")
            return
        }

        let exactBalanceAsset = Self.repeatNativeAsset(
            for: dogecoin,
            balanceAtomic: "100"
        )
        #expect(
            (try? WalletTransactionRepeatPreparation.prepare(
                transaction: transaction,
                walletAssets: [exactBalanceAsset],
                capabilities: .fullWallet
            ).get()) != nil
        )

        let received = Self.repeatTransaction(
            network: dogecoin,
            recipient: recipient,
            kind: .received(assetSymbol: "DOGE")
        )
        guard case .failure(.notOutgoing) =
            WalletTransactionRepeatPreparation.prepare(
                transaction: received,
                walletAssets: [exactBalanceAsset],
                capabilities: .fullWallet
            ) else {
            Issue.record("Incoming activity must not expose Repeat.")
            return
        }
    }

    @Test
    func insufficientSelfTransferShowsBalanceDialogBeforeRecipientCorrection() throws {
        let network = try #require(AssetNetworkSelectorOption.allSupported.first {
            $0.id == XRPConstants.networkID
        })
        let asset = Self.repeatNativeAsset(for: network, balanceAtomic: "99")
        let transaction = Self.repeatTransaction(
            network: network, recipient: Self.address(for: network.blockchain)
        )
        #expect(throws: WalletTransactionRepeatFailure.insufficientBalance) {
            try WalletTransactionRepeatPreparation.prepare(
                transaction: transaction, walletAssets: [asset], capabilities: .fullWallet
            ).get()
        }
    }

    private static func address(
        for blockchain: WalletBlockchain
    ) -> String {
        switch blockchain {
        case .aptos:
            aptosAddress
        case .stellar:
            stellarAddress
        case .near:
            nearAddress
        case .xrp:
            xrpAddress
        case .sui:
            suiAddress
        case .ton:
            tonAddress
        case .tron:
            tronAddress
        case .solana:
            solanaAddress
        case .bitcoin:
            bitcoinAddress
        case .bitcoincash:
            bitcoinCashAddress
        case .litecoin:
            litecoinAddress
        case .dogecoin:
            dogecoinAddress
        case .ethereum,
             .smartchain,
             .polygon,
             .arbitrum,
             .avalanchec,
             .optimism,
             .base,
             .xdai,
             .scroll,
             .linea,
             .taiko,
             .telos,
             .xlayer,
             .arc:
            evmAddress
        }
    }

    private static func repeatNativeAsset(
        for network: AssetNetworkSelectorOption,
        balanceAtomic: String = "1000"
    ) -> WalletAsset {
        WalletAsset(
            id: AssetIdentityKey.make(
                networkID: network.id,
                contractAddress: nil
            ),
            name: network.localizedName,
            symbol: network.blockchain.rawValue.uppercased(),
            logoSource: .nativeCoin(blockchain: network.blockchain),
            network: network.blockchain,
            balance: 1000,
            fiatValue: 1000,
            balanceText: "1000",
            balanceAtomic: balanceAtomic,
            receiveAddress: address(for: network.blockchain)
        )
    }

    private static func repeatTransaction(
        network: AssetNetworkSelectorOption,
        recipient: String,
        contractAddress: String? = nil,
        tokenDecimals: Int? = nil,
        amountText: String = "-1",
        amountAtomic: String? = "100",
        symbol: String? = nil,
        inputData: String? = nil,
        kind: WalletTransactionKind? = nil
    ) -> WalletTransaction {
        let assetSymbol = symbol
            ?? network.blockchain.rawValue.uppercased()
        let logoSource: AssetLogoSource = contractAddress.map {
            .catalogToken(
                blockchain: network.blockchain,
                contractAddress: $0,
                logoURL: nil
            )
        } ?? .nativeCoin(blockchain: network.blockchain)
        return WalletTransaction(
            id: "repeat:\(network.id):\(contractAddress ?? "native")",
            kind: kind ?? .sent(assetSymbol: assetSymbol),
            detail: recipient,
            time: "",
            assetLogoSource: logoSource,
            assetAmount: -1,
            assetAmountText: amountText,
            assetAmountAtomic: amountAtomic,
            assetSymbol: assetSymbol,
            fiatValue: nil,
            status: .confirmed,
            metadata: WalletTransactionMetadata(
                transactionHash: "abc123",
                blockchainIdentifier: network.id,
                date: nil,
                fromAddress: recipient,
                toAddress: recipient,
                blockNumber: nil,
                blockHash: nil,
                contractAddress: contractAddress,
                tokenName: assetSymbol,
                tokenDecimals: tokenDecimals,
                logIndex: nil,
                networkFee: nil,
                networkFeeFiatValue: nil,
                networkFeeSymbol: nil,
                gasPriceGwei: nil,
                gasLimit: nil,
                gasUsed: nil,
                nonce: nil,
                transactionIndex: nil,
                transactionType: nil,
                inputData: inputData,
                note: nil
            )
        )
    }

    private static func qrCodePNG(payload: String) -> Data? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        filter.correctionLevel = "M"
        guard let outputImage = filter.outputImage else {
            return nil
        }
        let scaledImage = outputImage.transformed(
            by: CGAffineTransform(scaleX: 12, y: 12)
        )
        // Include the QR standard's four-module quiet zone, like the app's
        // share card. An edge-cropped generator image is not a complete QR.
        let bounds = scaledImage.extent.insetBy(dx: -48, dy: -48)
        let paddedImage = scaledImage.composited(over:
            CIImage(color: .white).cropped(to: bounds))
        let context = CIContext(
            options: [.useSoftwareRenderer: true]
        )
        guard let image = context.createCGImage(
            paddedImage,
            from: bounds
        ) else {
            return nil
        }
        return UIImage(cgImage: image).pngData()
    }
}

struct WalletHomePasteTests {
    @Test
    func routesEverySupportedMainnetByAssetCapability() throws {
        for network in AssetNetworkSelectorOption.allSupported {
            let fixture = Self.address(for: network.blockchain)
            let request = try WalletHomePastePreparation
                .request(from: fixture)
                .get()
            #expect(
                request.candidateNetworkIDs.contains(network.id),
                "Home Paste did not classify \(network.id)."
            )

            let preparation = WalletHomePastePreparation.prepare(
                request,
                walletAssets: [Self.nativeAsset(for: network)],
                capabilities: .fullWallet
            )
            guard case let .ready(route) = preparation else {
                Issue.record("Home Paste rejected \(network.id).")
                continue
            }

            if SendFlowPlanner.automaticallySelectedNativeNetworkIDs
                .contains(network.id) {
                guard case let .amount(
                    draft,
                    failure
                ) = route else {
                    Issue.record(
                        "Single-coin \(network.id) did not open amount entry."
                    )
                    continue
                }
                #expect(draft.recipient == request.recipient)
                #expect(failure == nil)
            } else {
                guard case let .assetSelection(plannedRequest) = route else {
                    Issue.record(
                        "Token-capable \(network.id) skipped asset selection."
                    )
                    continue
                }
                #expect(plannedRequest == request)
            }
        }
    }

    @Test
    func rejectsEmptyMalformedAndTestnetPayloads() {
        let invalidPayloads = [
            "",
            "not a supported wallet address",
            "tb1qw508d6qejxtdg4y5r3zarvary0c5xw7kxpjzsx"
        ]

        for payload in invalidPayloads {
            guard case .failure = WalletHomePastePreparation
                .request(from: payload) else {
                Issue.record("Home Paste accepted invalid input.")
                continue
            }
        }
    }

    @Test
    func distinguishesNameServicesFromNEARAccounts() throws {
        let ens = try WalletHomePastePreparation
            .request(from: "vitalik.eth")
            .get()
        #expect(ens.source == .name)
        #expect(ens.candidateNetworkIDs.contains("eth"))

        let solanaName = try WalletHomePastePreparation
            .request(from: "bonfida.sol")
            .get()
        #expect(solanaName.source == .name)
        #expect(solanaName.candidateNetworkIDs == ["solana"])

        let namedNEAR = try WalletHomePastePreparation
            .request(from: "alice.near")
            .get()
        #expect(namedNEAR.source == .bareAddress)
        #expect(namedNEAR.candidateNetworkIDs == ["near"])

        let implicitNEAR = String(repeating: "0", count: 63) + "1"
        let implicitRequest = try WalletHomePastePreparation
            .request(from: implicitNEAR)
            .get()
        #expect(implicitRequest.source == .bareAddress)
        #expect(implicitRequest.candidateNetworkIDs == ["near"])

        guard case .failure = WalletHomePastePreparation
            .request(from: "wallet.example") else {
            Issue.record("Unsupported naming service was accepted as NEAR.")
            return
        }
    }

    @Test
    func tokenSelectionStaysOnTheValidatedNetworkAndFocusesAmount()
        throws
    {
        let network = try #require(
            AssetNetworkSelectorOption.allSupported.first {
                $0.id == "eth"
            }
        )
        let native = Self.nativeAsset(for: network)
        let contract =
            "0xA0b86991c6218b36c1d19d4a2e9eb0ce3606eb48"
        let token = WalletAsset(
            id: AssetIdentityKey.make(
                networkID: network.id,
                contractAddress: contract
            ),
            name: "USD Coin",
            symbol: "USDC",
            logoSource: .token(
                blockchain: .ethereum,
                checksummedContractAddress: contract,
                logoURL: nil,
                origin: .catalog
            ),
            network: .ethereum,
            balance: 10,
            fiatValue: 10,
            decimals: 6
        )
        let request = try WalletHomePastePreparation
            .request(from: Self.address(for: .ethereum))
            .get()
        let choices = SendAssetChoiceCatalog.choices(
            from: [native, token],
            capabilities: .fullWallet,
            for: request
        )

        #expect(choices.count == 2)
        #expect(choices.allSatisfy { $0.networkID == network.id })
        guard case .ready(.assetSelection) =
            WalletHomePastePreparation.prepare(
                request,
                walletAssets: [native, token],
                capabilities: .fullWallet
            ) else {
            Issue.record("Token-capable address skipped asset selection.")
            return
        }
        let tokenChoice = try #require(
            choices.first { !$0.isNative }
        )
        let route = try SendFlowPlanner.route(
            afterSelecting: tokenChoice,
            for: request
        )
        guard case let .amount(draft, failure) = route else {
            Issue.record("Token choice did not open Amount for the validated address.")
            return
        }
        #expect(draft.recipient == request.recipient)
        #expect(failure == nil)

        guard case let .ready(.recipient(
            selectedDraft,
            selectedFailure
        )) = WalletHomePastePreparation.prepare(
            request,
            walletAssets: [native, token],
            capabilities: .fullWallet,
            selectedAsset: tokenChoice
        ) else {
            Issue.record(
                "Asset-detail Paste did not open Recipient for the selected token."
            )
            return
        }
        #expect(selectedDraft.asset.id == tokenChoice.id)
        #expect(selectedDraft.recipient == request.recipient)
        #expect(selectedFailure == nil)
    }

    private static func address(
        for blockchain: WalletBlockchain
    ) -> String {
        switch blockchain {
        case .aptos:
            "0xd503b95164384a5ebbccbb5c4bdc8b4a5893d9651e9953abda8e1c22fcc1181d"
        case .stellar:
            "GA5ZSEJYB37JRC5AVCIA5MOP4RHTM335X2KGX3IHOJAPP5RE34K4KZVN"
        case .near:
            "alice.near"
        case .xrp:
            "rnBFvgZphmN39GWzUJeUitaP22Fr9be75H"
        case .sui:
            "0xdfc88cd008c89a4a4a60199b27e503cd5e248b5191be8e953856b43e87ae3393"
        case .ton:
            "UQBm--PFwDv1yCeS-QTJ-L8oiUpqo9IT1BwgVptlSq3ts4DV"
        case .tron:
            "TNPeeaaFB7K9cmo4uQpcU32zGK8G1NYqeL"
        case .solana:
            "mvines9iiHiQTysrwkJjGf2gb9Ex9jXJX8ns3qwf2kN"
        case .bitcoin:
            "bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4"
        case .bitcoincash:
            "qpm2qsznhks23z7629mms6s4cwef74vcwvy22gdx6a"
        case .litecoin:
            "LT2KVaAy1ppRuxRgrS5RNU3vBsy7RibPeA"
        case .dogecoin:
            "DD4KSSuBJqcjuTcvUg1CgUKeurPUFeEZkE"
        case .ethereum,
             .smartchain,
             .polygon,
             .arbitrum,
             .avalanchec,
             .optimism,
             .base,
             .xdai,
             .scroll,
             .linea,
             .taiko,
             .telos,
             .xlayer,
             .arc:
            "0x71C7656EC7ab88b098defB751B7401B5f6d8976F"
        }
    }

    private static func nativeAsset(
        for network: AssetNetworkSelectorOption
    ) -> WalletAsset {
        WalletAsset(
            id: AssetIdentityKey.make(
                networkID: network.id,
                contractAddress: nil
            ),
            name: network.localizedName,
            symbol: network.blockchain.rawValue.uppercased(),
            logoSource: .nativeCoin(blockchain: network.blockchain),
            network: network.blockchain,
            balance: 1,
            fiatValue: 1
        )
    }
}
