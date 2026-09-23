import SwiftUI
import UIKit

struct ReceiveShareContext: Equatable, Sendable {
    let address: String
    let qrPayload: String
    let assetSymbol: String
    let assetLogoSource: AssetLogoSource
    let networkName: String
    let networkLogoSource: AssetLogoSource
}

enum ReceiveShareTagline: String, CaseIterable, Sendable {
    case selfCustodyMadeSimple =
        "receive.share.tagline.self_custody_made_simple"
    case yourKeysYourCrypto =
        "receive.share.tagline.your_keys_your_crypto"
    case privateSecureYours =
        "receive.share.tagline.private_secure_yours"
    case receiveSecurely =
        "receive.share.tagline.receive_securely"
    case builtForSelfCustody =
        "receive.share.tagline.built_for_self_custody"

    var localizedText: String {
        WalletLocalization.string(rawValue)
    }

    static func random() -> ReceiveShareTagline {
        var generator = SystemRandomNumberGenerator()
        return random(using: &generator)
    }

    static func random<Generator: RandomNumberGenerator>(
        using generator: inout Generator
    ) -> ReceiveShareTagline {
        allCases.randomElement(using: &generator)
            ?? .selfCustodyMadeSimple
    }
}

@MainActor
enum ReceiveShareCardRenderer {
    static let outputSize = CGSize(width: 720, height: 960)
    fileprivate static let designSize = CGSize(
        width: 1_200,
        height: 1_600
    )
    private static let outputScale =
        outputSize.width / designSize.width

    static func image(
        context: ReceiveShareContext,
        qrImage: CGImage,
        tagline: ReceiveShareTagline,
        colorScheme: ColorScheme,
        layoutDirection: LayoutDirection
    ) -> UIImage? {
        let card = ZStack(alignment: .topLeading) {
            ReceiveShareCard(
                context: context,
                qrImage: qrImage,
                tagline: tagline
            )
            .environment(\.colorScheme, colorScheme)
            .environment(\.layoutDirection, layoutDirection)
            .scaleEffect(outputScale, anchor: .topLeading)
        }
        .frame(
            width: outputSize.width,
            height: outputSize.height,
            alignment: .topLeading
        )
        .clipped()

        let renderer = ImageRenderer(content: card)
        renderer.proposedSize = ProposedViewSize(
            width: outputSize.width,
            height: outputSize.height
        )
        renderer.scale = 1
        renderer.isOpaque = true
        return renderer.uiImage
    }
}

private struct ReceiveShareCard: View {
    let context: ReceiveShareContext
    @Environment(\.colorScheme) private var colorScheme
    let qrImage: CGImage
    let tagline: ReceiveShareTagline

    var body: some View {
        ZStack {
            WalletTheme.groupedBackground

            RoundedRectangle(cornerRadius: 72, style: .continuous)
                .fill(WalletTheme.secondarySurface)
                .overlay {
                    RoundedRectangle(
                        cornerRadius: 72,
                        style: .continuous
                    )
                    .stroke(WalletTheme.separator, lineWidth: 2)
                }
                .padding(54)

            VStack(spacing: 0) {
                brandHeader

                receiveTitle
                    .padding(.top, 48)

                ReceiveNetworkLabel(
                    networkName: context.networkName,
                    logoSource: context.networkLogoSource,
                    logoSize: 38,
                    spacing: 10,
                    animatesLogoChanges: false
                )
                .font(.system(size: 32, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.top, 12)

                qrCode
                    .padding(.top, 42)

                brandMessage
                    .padding(.top, 34)

                addressPanel
                    .padding(.top, 34)
            }
            .padding(.horizontal, 112)
            .padding(.vertical, 96)
        }
        .frame(
            width: ReceiveShareCardRenderer.designSize.width,
            height: ReceiveShareCardRenderer.designSize.height
        )
    }

    private var brandHeader: some View {
        HStack(spacing: 22) {
            HeroBrandMark(size: 62)

            Text(verbatim: WalletLocalization.string("brand.name"))
                .font(.system(size: 42, weight: .bold))
                .foregroundStyle(.primary)

            Spacer(minLength: 32)
        }
    }

    private var receiveTitle: some View {
        HStack(spacing: 14) {
            Text(
                verbatim: WalletLocalization.string(
                    "receive.title"
                )
            )

            AssetLogoView(
                source: context.assetLogoSource,
                size: 54,
                animatesChanges: false
            )
            .accessibilityHidden(true)

            Text(verbatim: context.assetSymbol)
        }
        .font(.system(size: 70, weight: .bold))
        .foregroundStyle(.primary)
        .lineLimit(1)
        .minimumScaleFactor(0.68)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            EnglishNumbers.localized(
                "receive.details.navigation.title",
                context.assetSymbol
            )
        )
    }

    private var qrCode: some View {
        Image(
            decorative: ReceiveQRCodeAppearance.image(qrImage, colorScheme: colorScheme),
            scale: 1,
            orientation: .up
        )
        .resizable()
        .interpolation(qrImage.shouldInterpolate ? .high : .none)
        .scaledToFit()
        .padding(46)
        .frame(width: 680, height: 680)
        .background(
            WalletTheme.qrCodeSurface,
            in: RoundedRectangle(
                cornerRadius: 54,
                style: .continuous
            )
        )
        .overlay {
            RoundedRectangle(cornerRadius: 54, style: .continuous)
                .stroke(Color.black.opacity(0.08), lineWidth: 2)
        }
    }

    private var brandMessage: some View {
        VStack(spacing: 18) {
            HeroBrandMark(size: 72)

            Text(verbatim: tagline.localizedText)
                .font(.system(size: 38, weight: .semibold))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.72)
                .frame(maxWidth: 820)
        }
    }

    private var addressPanel: some View {
        VStack(spacing: 12) {
            Text(
                verbatim: WalletLocalization.string(
                    "receive.details.address.section"
                )
            )
            .font(.system(size: 24, weight: .semibold))
            .foregroundStyle(.secondary)

            ReceiveShareAddressText(
                address: context.address,
                width: ReceiveShareCardRenderer.designSize.width - 2 * (112 + 38)
            )
        }
        .padding(.horizontal, 38)
        .padding(.vertical, 28)
        .frame(maxWidth: .infinity)
        .background(
            WalletTheme.mutedSecondaryFill,
            in: RoundedRectangle(cornerRadius: 34, style: .continuous)
        )
    }
}
