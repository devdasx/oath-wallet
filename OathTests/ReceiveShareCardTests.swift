import CoreImage
import SwiftUI
import Testing
import UIKit
@testable import Aperture

struct ReceiveShareCardTests {
    @Test
    @MainActor
    func receiveAddressUsesLargerDynamicTypeFont() throws {
        let text = ReceiveAddressText.attributedAddress("bc1qexample")
        let font = try #require(text.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
        let expected = UIFontMetrics(forTextStyle: .body).scaledValue(for: 19)
        #expect(abs(font.pointSize - expected) < 0.01)
    }

    @Test
    @MainActor
    func longReceiveAddressesWrapWithoutInsertedHyphens() throws {
        let address =
            "sp1qqgz9da69qjs6yyz9wmkn5d5cvd2uft7ffaw7pp23u"
            + "akdas8je2p9wqcztilcan6vp7rezngs743w8ek7yeh8d7"
            + "tmweazl5udlyhrwem3sq7nekd7"
        let attributed = ReceiveAddressText.attributedAddress(address)
        let paragraphStyle = try #require(
            attributed.attribute(
                .paragraphStyle,
                at: 0,
                effectiveRange: nil
            ) as? NSParagraphStyle
        )

        #expect(attributed.string == address)
        #expect(!attributed.string.contains("-"))
        #expect(paragraphStyle.lineBreakMode == .byCharWrapping)
        #expect(paragraphStyle.hyphenationFactor == 0)
        #expect(!paragraphStyle.usesDefaultHyphenation)
    }

    @Test
    func solanaReceivePathMenuCopyExistsInEveryLanguage() {
        for language in WalletAppLanguage.supportedIdentifiers {
            let bundle = WalletAppLanguage.localizedBundle(for: language)
            let titleKey = "receive.solana.path.title"
            #expect(
                bundle.localizedString(
                    forKey: titleKey,
                    value: nil,
                    table: nil
                ) != titleKey
            )

            for kind in SolanaDerivationKind.allCases {
                #expect(
                    bundle.localizedString(
                        forKey: kind.localizedNameKey,
                        value: nil,
                        table: nil
                    ) != kind.localizedNameKey
                )
            }
        }
    }

    @Test
    @MainActor
    func qrPayloadReplacementAnimationIsExplicitlyOptIn() {
        let standard = ReceiveQRCodeImage(payload: "bitcoin:bc1qexample")
        let changingAddress = ReceiveQRCodeImage(
            payload: "bitcoin:bc1qexample",
            animatesPayloadReplacement: true
        )

        #expect(!standard.animatesPayloadReplacement)
        #expect(changingAddress.animatesPayloadReplacement)
    }

    @Test
    func contentMenuUsesDedicatedShareActionLabels() {
        #expect(
            WalletLocalization.string("receive.action.share")
                == "Share Address"
        )
        #expect(
            WalletLocalization.string(
                "receive.action.share_qr_code"
            ) == "Share QR Code"
        )
    }

    @Test
    @MainActor
    func receivePrimaryLabelLeavesPaddingToNativeButton() {
        let buttonWidth: CGFloat = 180
        let fittingSize = CGSize(width: buttonWidth, height: 200)

        let copyController = UIHostingController(
            rootView: ReceiveAddressActionButtonLabel(
                title: "common.copy"
            )
            .frame(width: buttonWidth)
        )
        let shareController = UIHostingController(
            rootView: ReceiveAddressActionButtonLabel(
                title: "receive.action.share"
            )
            .frame(width: buttonWidth)
        )

        let copySize = copyController.sizeThatFits(in: fittingSize)
        let shareSize = shareController.sizeThatFits(in: fittingSize)

        #expect(copySize.width == shareSize.width)
        #expect(copySize.height == shareSize.height)
        #expect(copySize.height < 44)
    }

    @Test
    func everyApprovedMarketingTaglineIsAvailableExactlyOnce() {
        let taglines = ReceiveShareTagline.allCases

        #expect(taglines.count == 5)
        #expect(Set(taglines.map(\.rawValue)).count == taglines.count)
        #expect(
            taglines.contains(
                .selfCustodyMadeSimple
            )
        )
        #expect(taglines.contains(.yourKeysYourCrypto))
        #expect(taglines.contains(.privateSecureYours))
        #expect(taglines.contains(.receiveSecurely))
        #expect(taglines.contains(.builtForSelfCustody))
    }

    @Test
    func randomSelectionAlwaysReturnsAnApprovedTagline() {
        var generator = PredictableRandomNumberGenerator()

        for _ in 0..<128 {
            let selected = ReceiveShareTagline.random(
                using: &generator
            )
            #expect(ReceiveShareTagline.allCases.contains(selected))
        }
    }

    @Test(arguments: [ColorScheme.light, .dark])
    @MainActor
    func brandedCardRendersAtProductionExportResolution(colorScheme: ColorScheme) async throws {
        let renderedQRCode = await ReceiveQRCodeRenderer.shared.image(
            for: "ethereum:0x0000000000000000000000000000000000000001@1"
        )
        let qrImage = try #require(renderedQRCode)
        let image = try #require(
            ReceiveShareCardRenderer.image(
                context: ReceiveShareContext(
                    address:
                        "0x0000000000000000000000000000000000000001",
                    qrPayload:
                        "ethereum:0x0000000000000000000000000000000000000001@1",
                    assetSymbol: "ETH",
                    assetLogoSource: .nativeCoin(
                        blockchain: .ethereum
                    ),
                    networkName: "Ethereum",
                    networkLogoSource: .nativeCoin(
                        blockchain: .ethereum
                    )
                ),
                qrImage: qrImage,
                tagline: .selfCustodyMadeSimple,
                colorScheme: colorScheme,
                layoutDirection: .leftToRight
            )
        )

        #expect(image.scale == 1)
        #expect(image.size == ReceiveShareCardRenderer.outputSize)
        #expect(image.cgImage?.width == 720)
        #expect(image.cgImage?.height == 960)
        let exported = try #require(image.cgImage)
        let detector = try #require(CIDetector(
            ofType: CIDetectorTypeQRCode,
            context: CIContext(options: [.useSoftwareRenderer: true]),
            options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]
        ))
        let payloads = detector.features(in: CIImage(cgImage: exported))
            .compactMap { ($0 as? CIQRCodeFeature)?.messageString }
        #expect(payloads == ["ethereum:0x0000000000000000000000000000000000000001@1"])
    }
}

struct ReceiveNetworkIdentityTests {
    @Test
    func everySupportedChainResolvesItsCanonicalReceiveNetwork()
        throws
    {
        let expectedNetworks = Self.expectedNetworks
        let supportedBlockchains = Set(
            ReceiveNetworkCatalog.all.map(\.blockchain)
                + BitcoinFamilyChain.allCases.map(\.blockchain)
        )

        #expect(expectedNetworks.count == 25)
        #expect(
            Set(expectedNetworks.map(\.blockchain))
                == supportedBlockchains
        )

        for expected in expectedNetworks {
            let asset = WalletAsset(
                id: "test:\(expected.blockchain.rawValue)",
                name: "Unrelated Token Name",
                symbol: "TEST",
                logoSource: .unavailable,
                network: expected.blockchain,
                balance: .zero,
                fiatValue: .zero
            )
            let presentation = try #require(
                ReceiveNetworkPresentation(asset: asset)
            )

            #expect(presentation.blockchain == expected.blockchain)
            #expect(presentation.nameKey == expected.nameKey)
            #expect(presentation.localizedName == expected.englishName)
            #expect(
                presentation.logoSource
                    == .network(blockchain: expected.blockchain)
            )

            let badge = ReceiveNetworkLabelText.localized(
                networkName: presentation.localizedName,
                blockchain: presentation.blockchain
            )
            #expect(badge.contains(presentation.localizedName))

            let warning = EnglishNumbers.localized(
                "receive.bitcoin_family.warning",
                asset.symbol,
                presentation.localizedName
            )
            #expect(warning.contains(presentation.localizedName))
            #expect(!badge.contains(asset.name))
            #expect(!warning.contains(asset.name))
        }
    }

    @Test
    func tronUSDTUsesTronInsteadOfTheTokenName() throws {
        let asset = WalletAsset(
            id: "tron:test-usdt",
            name: "Tether USD",
            symbol: "USDT",
            logoSource: .unavailable,
            network: .tron,
            balance: .zero,
            fiatValue: .zero
        )
        let presentation = try #require(
            ReceiveNetworkPresentation(asset: asset)
        )

        #expect(presentation.localizedName == "TRON")
        #expect(
            ReceiveNetworkLabelText.localized(
                networkName: presentation.localizedName,
                blockchain: presentation.blockchain
            ) == "On {logo}TRON Network"
        )

        let warning = EnglishNumbers.localized(
            "receive.bitcoin_family.warning",
            asset.symbol,
            presentation.localizedName
        )
        #expect(warning.contains("TRON"))
        #expect(!warning.contains("Tether USD"))
    }

    @Test
    func tokenVariantsKeepTheirOwningNetwork() throws {
        // Catalog contents arrive remotely. Exercise every supported network
        // without relying on another test or a live catalog sync to seed it.
        for owner in ReceiveNetworkCatalog.all {
            let variant = ReceiveTokenVariant(
                networkID: owner.id, contractAddress: "network-label-fixture",
                decimals: 6, networkRank: nil, logoURL: nil
            )
            let network = try #require(variant.network)
            let presentation = try #require(
                ReceiveNetworkPresentation(
                    blockchain: network.blockchain
                )
            )

            #expect(presentation.blockchain == network.blockchain)
            #expect(presentation.nameKey == network.nameKey)

            let badge = ReceiveNetworkLabelText.localized(
                networkName: presentation.localizedName,
                blockchain: presentation.blockchain
            )
            #expect(badge.contains(presentation.localizedName))
        }
    }

    private struct ExpectedNetwork: Sendable {
        let blockchain: WalletBlockchain
        let nameKey: String
        let englishName: String
    }

    private static let expectedNetworks: [ExpectedNetwork] = [
        ExpectedNetwork(
            blockchain: .aptos,
            nameKey: "network.aptos.name",
            englishName: "Aptos"
        ),
        ExpectedNetwork(
            blockchain: .stellar,
            nameKey: "network.stellar.name",
            englishName: "Stellar"
        ),
        ExpectedNetwork(
            blockchain: .ethereum,
            nameKey: "network.ethereum",
            englishName: "Ethereum"
        ),
        ExpectedNetwork(
            blockchain: .tron,
            nameKey: "network.tron.name",
            englishName: "TRON"
        ),
        ExpectedNetwork(
            blockchain: .solana,
            nameKey: "network.solana.name",
            englishName: "Solana"
        ),
        ExpectedNetwork(
            blockchain: .ton,
            nameKey: "network.ton.name",
            englishName: "TON"
        ),
        ExpectedNetwork(
            blockchain: .sui,
            nameKey: "network.sui.name",
            englishName: "Sui Network"
        ),
        ExpectedNetwork(
            blockchain: .near,
            nameKey: "network.near.name",
            englishName: "NEAR Protocol"
        ),
        ExpectedNetwork(
            blockchain: .xrp,
            nameKey: "network.xrp.name",
            englishName: "XRP Ledger"
        ),
        ExpectedNetwork(
            blockchain: .smartchain,
            nameKey: "network.bnb_smart_chain",
            englishName: "BNB Smart Chain"
        ),
        ExpectedNetwork(
            blockchain: .arbitrum,
            nameKey: "network.arbitrum",
            englishName: "Arbitrum"
        ),
        ExpectedNetwork(
            blockchain: .base,
            nameKey: "network.base",
            englishName: "Base"
        ),
        ExpectedNetwork(
            blockchain: .polygon,
            nameKey: "network.polygon",
            englishName: "Polygon"
        ),
        ExpectedNetwork(
            blockchain: .optimism,
            nameKey: "network.optimism",
            englishName: "Optimism"
        ),
        ExpectedNetwork(
            blockchain: .avalanchec,
            nameKey: "network.avalanche",
            englishName: "Avalanche"
        ),
        ExpectedNetwork(
            blockchain: .xdai,
            nameKey: "network.gnosis",
            englishName: "Gnosis"
        ),
        ExpectedNetwork(
            blockchain: .linea,
            nameKey: "network.linea",
            englishName: "Linea"
        ),
        ExpectedNetwork(
            blockchain: .scroll,
            nameKey: "network.scroll",
            englishName: "Scroll"
        ),
        ExpectedNetwork(
            blockchain: .taiko,
            nameKey: "network.taiko",
            englishName: "Taiko"
        ),
        ExpectedNetwork(
            blockchain: .telos,
            nameKey: "network.telos",
            englishName: "Telos"
        ),
        ExpectedNetwork(
            blockchain: .xlayer,
            nameKey: "network.x_layer",
            englishName: "X Layer"
        ),
        ExpectedNetwork(
            blockchain: .bitcoin,
            nameKey: "network.bitcoin.name",
            englishName: "Bitcoin"
        ),
        ExpectedNetwork(
            blockchain: .bitcoincash,
            nameKey: "network.bitcoin_cash.name",
            englishName: "Bitcoin Cash"
        ),
        ExpectedNetwork(
            blockchain: .litecoin,
            nameKey: "network.litecoin.name",
            englishName: "Litecoin"
        ),
        ExpectedNetwork(
            blockchain: .dogecoin,
            nameKey: "network.dogecoin.name",
            englishName: "Dogecoin"
        ),
    ]
}

private struct PredictableRandomNumberGenerator: RandomNumberGenerator {
    private var state: UInt64 = 0x9E3779B97F4A7C15

    mutating func next() -> UInt64 {
        state &*= 2_862_933_555_777_941_757
        state &+= 3_037_000_493
        return state
    }
}
