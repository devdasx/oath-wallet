import SwiftUI

enum OnboardingCarouselPage: Int, CaseIterable, Identifiable, Sendable {
    case wallet
    case entropy
    case openSource
    case passphrase

    var id: Int { rawValue }

    var localizedEyebrow: String {
        switch self {
        case .wallet:
            WalletLocalization.string(
                "onboarding.carousel.wallet.eyebrow"
            )
        case .entropy:
            WalletLocalization.string(
                "onboarding.carousel.entropy.eyebrow"
            )
        case .openSource:
            WalletLocalization.string(
                "onboarding.carousel.open_source.eyebrow"
            )
        case .passphrase:
            WalletLocalization.string(
                "onboarding.carousel.passphrase.eyebrow"
            )
        }
    }

    var localizedTitle: String {
        switch self {
        case .wallet:
            WalletLocalization.string(
                "onboarding.carousel.wallet.title"
            )
        case .entropy:
            WalletLocalization.string(
                "onboarding.carousel.entropy.title"
            )
        case .openSource:
            WalletLocalization.string(
                "onboarding.carousel.open_source.title"
            )
        case .passphrase:
            WalletLocalization.string(
                "onboarding.carousel.passphrase.title"
            )
        }
    }

    var localizedMessage: String {
        switch self {
        case .wallet:
            WalletLocalization.string(
                "onboarding.carousel.wallet.message"
            )
        case .entropy:
            WalletLocalization.string(
                "onboarding.carousel.entropy.message"
            )
        case .openSource:
            WalletLocalization.string(
                "onboarding.carousel.open_source.message"
            )
        case .passphrase:
            WalletLocalization.string(
                "onboarding.carousel.passphrase.message"
            )
        }
    }
}

enum OnboardingCarouselSheet: String, Identifiable, Sendable {
    case entropyLearnMore
    case passphraseLearnMore

    var id: String { rawValue }
}

struct OnboardingCarouselView: View {
    let creationErrorMessage: String?
    let onCreateWallet: () -> Void
    let onImportWallet: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var selectedPage = OnboardingCarouselPage.wallet
    @State private var presentedSheet: OnboardingCarouselSheet?

    var body: some View {
        GeometryReader { proxy in
            TabView(selection: $selectedPage) {
                ForEach(OnboardingCarouselPage.allCases) { page in
                    OnboardingCarouselPageView(
                        page: page,
                        availableSize: proxy.size,
                        usesRegularWidth:
                            proxy.size.width >= 720
                            && !dynamicTypeSize.isAccessibilitySize,
                        onShowEntropyLearnMore: {
                            presentedSheet = .entropyLearnMore
                        },
                        onShowPassphraseLearnMore: {
                            presentedSheet = .passphraseLearnMore
                        }
                    )
                    .tag(page)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(
                .page(backgroundDisplayMode: .always)
            )
        }
        .walletSafeAreaBar(edge: .bottom, spacing: 0) {
            actions
        }
        .sheet(item: $presentedSheet) { sheet in
            switch sheet {
            case .entropyLearnMore:
                OnboardingEntropyLearnMoreSheet()
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            case .passphraseLearnMore:
                OnboardingPassphraseLearnMoreSheet()
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
        }
    }

    private var actions: some View {
        VStack(spacing: 12) {
            PrimaryWalletButton(
                title: "onboarding.action.create",
                hapticPolicy: .silent,
                action: onCreateWallet
            )

            SecondaryWalletButton(
                title: "onboarding.action.import",
                hapticPolicy: .silent,
                action: onImportWallet
            )

            if let creationErrorMessage {
                Text(creationErrorMessage)
                    .font(.footnote)
                    .foregroundStyle(WalletTheme.danger)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .walletActionScreenMargins()
        .padding(.top, 12)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity)
    }
}

private struct OnboardingCarouselPageView: View {
    private static let repositoryURL = URL(
        string: "https://github.com/devdasx/oath-wallet"
    )!

    let page: OnboardingCarouselPage
    let availableSize: CGSize
    let usesRegularWidth: Bool
    let onShowEntropyLearnMore: () -> Void
    let onShowPassphraseLearnMore: () -> Void

    var body: some View {
        OnboardingHeightFittedContent {
            Group {
                if usesRegularWidth {
                    regularWidthContent
                } else {
                    compactWidthContent
                }
            }
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.top, topPadding)
        .padding(.bottom, bottomPadding)
    }

    private var compactWidthContent: some View {
        VStack(spacing: contentSpacing) {
            visual
                .frame(maxWidth: 500)

            message(alignment: .center)
                .frame(maxWidth: 620)
        }
    }

    private var regularWidthContent: some View {
        HStack(spacing: min(84, availableSize.width * 0.07)) {
            visual
                .frame(maxWidth: 520)

            message(alignment: .leading)
                .frame(maxWidth: 460, alignment: .leading)
        }
        .frame(maxWidth: 1120)
    }

    private func message(
        alignment: TextAlignment
    ) -> some View {
        VStack(
            alignment: alignment == .leading ? .leading : .center,
            spacing: messageSpacing
        ) {
            Text(verbatim: page.localizedTitle)
                .font(
                    .system(.largeTitle, design: .rounded)
                        .weight(.bold)
                )
                .foregroundStyle(WalletTheme.primaryLabel)
                .multilineTextAlignment(alignment)
                .fixedSize(horizontal: false, vertical: true)

            Text(verbatim: page.localizedMessage)
                .font(.body)
                .foregroundStyle(WalletTheme.secondaryLabel)
                .multilineTextAlignment(alignment)
                .fixedSize(horizontal: false, vertical: true)

            if page == .entropy {
                Button(action: UniHaptic.action(nil, perform: onShowEntropyLearnMore)) {
                    mutedCapsuleLabel(
                        WalletLocalization.string(
                            "onboarding.carousel.entropy.learn_more.action"
                        )
                    )
                }
                .buttonStyle(.plain)
            }

            if page == .passphrase {
                Button(action: UniHaptic.action(nil, perform: onShowPassphraseLearnMore)) {
                    mutedCapsuleLabel(
                        WalletLocalization.string(
                            "onboarding.carousel.passphrase.learn_more.action"
                        )
                    )
                }
                .buttonStyle(.plain)
            }

            if page == .openSource {
                Link(
                    destination: Self.repositoryURL
                ) {
                    mutedCapsuleLabel(
                        WalletLocalization.string(
                            "onboarding.carousel.open_source.action.github"
                        )
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .frame(
            maxWidth: .infinity,
            alignment: alignment == .leading ? .leading : .center
        )
    }

    private func mutedCapsuleLabel(
        _ title: String
    ) -> some View {
        Text(verbatim: title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(WalletTheme.secondaryLabel)
            .padding(.horizontal, 16)
            .frame(minHeight: 44)
            .background(
                WalletTheme.tertiaryFill,
                in: Capsule()
            )
    }

    private var usesCompactHeight: Bool {
        availableSize.height < 560
    }

    private var horizontalPadding: CGFloat {
        if usesRegularWidth {
            return 48
        }
        return availableSize.width < 360 ? 18 : 24
    }

    private var topPadding: CGFloat {
        if usesRegularWidth {
            return usesCompactHeight ? 16 : 28
        }
        return usesCompactHeight ? 8 : 18
    }

    private var bottomPadding: CGFloat {
        usesCompactHeight ? 44 : 54
    }

    private var contentSpacing: CGFloat {
        usesCompactHeight ? 14 : 24
    }

    private var messageSpacing: CGFloat {
        usesCompactHeight ? 10 : 14
    }

    @ViewBuilder
    private var visual: some View {
        switch page {
        case .wallet:
            OnboardingWalletCarouselVisual()
        case .entropy:
            OnboardingEntropyCarouselVisual()
        case .openSource:
            OnboardingOpenSourceCarouselVisual()
        case .passphrase:
            OnboardingPassphraseCarouselVisual()
        }
    }
}

private struct OnboardingHeightFittedContent<Content: View>: View {
    @State private var measuredContentHeight: CGFloat = 0

    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        GeometryReader { proxy in
            let scale = fittedScale(
                contentHeight: measuredContentHeight,
                availableHeight: proxy.size.height
            )

            content
                .frame(width: proxy.size.width)
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { geometry in
                    geometry.size.height
                } action: { height in
                    guard height.isFinite,
                          abs(height - measuredContentHeight) > 0.5 else {
                        return
                    }
                    measuredContentHeight = height
                }
                .scaleEffect(scale, anchor: .center)
                .frame(
                    width: proxy.size.width,
                    height: proxy.size.height,
                    alignment: .center
                )
        }
    }

    private func fittedScale(
        contentHeight: CGFloat,
        availableHeight: CGFloat
    ) -> CGFloat {
        guard contentHeight.isFinite,
              availableHeight.isFinite,
              contentHeight > 0,
              availableHeight > 0 else {
            return 1
        }
        return min(availableHeight / contentHeight, 1)
    }
}

private struct OnboardingWalletCarouselVisual: View {
    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 12) {
                OnboardingBrandMark(size: 42)

                VStack(alignment: .leading, spacing: 2) {
                    Text("wallet.home.wallet.name.default")
                        .font(.headline)
                    Text("onboarding.carousel.wallet.visual.networks")
                        .font(.caption)
                        .foregroundStyle(WalletTheme.secondaryLabel)
                }

                Spacer(minLength: 8)

                OnboardingNetworkLogoStack()
            }

            VStack(spacing: 2) {
                Text("wallet.home.balance.label")
                    .font(.caption)
                    .foregroundStyle(WalletTheme.secondaryLabel)

                Text(
                    verbatim: EnglishNumbers.currency(
                        Decimal(12_480.32),
                        currencyCode: "USD"
                    )
                )
                .font(.system(.title, design: .rounded).weight(.bold))
                .monospacedDigit()
            }
            .frame(maxWidth: .infinity)

            HStack(spacing: 8) {
                OnboardingWalletActionLabel(
                    key: "wallet.home.action.send"
                )
                OnboardingWalletActionLabel(
                    key: "wallet.home.action.receive"
                )
                OnboardingWalletActionLabel(
                    key: "wallet.home.action.scan"
                )
            }

            VStack(spacing: 0) {
                OnboardingWalletAssetSample(
                    imageName: "NetworkLogoEthereum",
                    nameKey: "wallet.asset.ethereum.name",
                    symbol: "ETH",
                    amount: Decimal(2.41)
                )

                Divider()
                    .padding(.leading, 50)

                OnboardingWalletAssetSample(
                    imageName: "NetworkLogoBitcoin",
                    nameKey: "network.bitcoin.name",
                    symbol: "BTC",
                    amount: Decimal(string: "0.084") ?? 0
                )
            }
            .padding(.horizontal, 14)
            .background(
                WalletTheme.groupedSurface,
                in: RoundedRectangle(
                    cornerRadius: 20,
                    style: .continuous
                )
            )
        }
        .padding(18)
        .walletRegularGlassEffect(
            in: RoundedRectangle(cornerRadius: 32, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 32, style: .continuous)
                .stroke(
                    WalletTheme.separator.opacity(0.22),
                    lineWidth: 0.5
                )
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            Text("onboarding.carousel.wallet.visual.accessibility")
        )
    }
}

private struct OnboardingNetworkLogoStack: View {
    private let imageNames = [
        "NetworkLogoEthereum",
        "NetworkLogoBitcoin",
        "NetworkLogoSolana"
    ]

    var body: some View {
        HStack(spacing: -8) {
            ForEach(imageNames, id: \.self) { imageName in
                Image(imageName)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 30, height: 30)
                    .clipShape(Circle())
                    .overlay {
                        Circle()
                            .stroke(WalletTheme.background, lineWidth: 2)
                    }
            }
        }
        .accessibilityHidden(true)
    }
}

private struct OnboardingWalletActionLabel: View {
    let key: LocalizedStringKey

    var body: some View {
        Text(key)
            .font(.caption.weight(.semibold))
            .foregroundStyle(WalletTheme.primaryLabel)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(WalletTheme.tertiaryFill, in: Capsule())
    }
}

private struct OnboardingWalletAssetSample: View {
    let imageName: String
    let nameKey: LocalizedStringKey
    let symbol: String
    let amount: Decimal

    var body: some View {
        HStack(spacing: 12) {
            Image(imageName)
                .resizable()
                .scaledToFit()
                .frame(width: 36, height: 36)
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 1) {
                Text(nameKey)
                    .font(.subheadline.weight(.medium))
                Text(verbatim: symbol)
                    .font(.caption)
                    .foregroundStyle(WalletTheme.secondaryLabel)
            }

            Spacer(minLength: 8)

            Text(
                verbatim: EnglishNumbers.decimal(
                    amount,
                    minimumFractionDigits: 0,
                    maximumFractionDigits: 3
                ) + " " + symbol
            )
            .font(.subheadline.weight(.medium))
            .monospacedDigit()
        }
        .padding(.vertical, 10)
    }
}

private struct OnboardingEntropyCarouselVisual: View {
    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 10) {
                OnboardingEntropyMethodVisual(
                    titleKey: "wallet.creation.entropy.method.dice"
                ) {
                    SettingsWalletEntropyDieFace(face: 5)
                        .frame(width: 58, height: 58)
                }

                OnboardingEntropyMethodVisual(
                    titleKey: "wallet.creation.entropy.method.coin"
                ) {
                    SettingsWalletEntropyCoinFace(
                        side: .heads,
                        diameter: 58
                    )
                }

                OnboardingEntropyMethodVisual(
                    titleKey: "wallet.creation.entropy.method.digits"
                ) {
                    Text(verbatim: EnglishNumbers.integer(739))
                        .font(
                            .system(.title3, design: .monospaced)
                                .bold()
                        )
                        .frame(width: 66, height: 58)
                        .background(
                            WalletTheme.groupedSurface,
                            in: RoundedRectangle(
                                cornerRadius: 16,
                                style: .continuous
                            )
                        )
                        .overlay {
                            RoundedRectangle(
                                cornerRadius: 16,
                                style: .continuous
                            )
                            .stroke(
                                WalletTheme.separator.opacity(0.55),
                                lineWidth: 0.7
                            )
                        }
                }
            }

            Image(systemName: "arrow.down")
                .font(.headline)
                .foregroundStyle(WalletTheme.accent)
                .accessibilityHidden(true)

            HStack(spacing: 12) {
                Image(systemName: "key.horizontal")
                    .font(.title2)
                    .foregroundStyle(WalletTheme.accent)

                VStack(alignment: .leading, spacing: 2) {
                    Text("onboarding.carousel.entropy.visual.output")
                        .font(.headline)
                    Text("onboarding.carousel.entropy.visual.local")
                        .font(.caption)
                        .foregroundStyle(WalletTheme.secondaryLabel)
                }

                Spacer(minLength: 8)

                Image(systemName: "checkmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(WalletTheme.success)
            }
            .padding(16)
            .background(
                WalletTheme.groupedSurface,
                in: RoundedRectangle(
                    cornerRadius: 22,
                    style: .continuous
                )
            )
        }
        .padding(18)
        .walletRegularGlassEffect(
            in: RoundedRectangle(cornerRadius: 32, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 32, style: .continuous)
                .stroke(
                    WalletTheme.separator.opacity(0.22),
                    lineWidth: 0.5
                )
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            Text("onboarding.carousel.entropy.visual.accessibility")
        )
    }
}

private struct OnboardingEntropyMethodVisual<Content: View>: View {
    let titleKey: LocalizedStringKey
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 8) {
            content()

            Text(titleKey)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .padding(.horizontal, 6)
    }
}

private struct OnboardingPassphraseCarouselVisual: View {
    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 10) {
                OnboardingPassphraseInputVisual(
                    symbol: "text.book.closed",
                    title: WalletLocalization.string(
                        "onboarding.carousel.passphrase.visual.phrase"
                    )
                )

                Image(systemName: "plus")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(WalletTheme.secondaryLabel)
                    .accessibilityHidden(true)

                OnboardingPassphraseInputVisual(
                    symbol: "key.horizontal",
                    title: WalletLocalization.string(
                        "onboarding.carousel.passphrase.visual.passphrase"
                    )
                )
            }

            Image(systemName: "arrow.down")
                .font(.headline)
                .foregroundStyle(WalletTheme.accent)
                .accessibilityHidden(true)

            HStack(spacing: 12) {
                Image(systemName: "lock.shield")
                    .font(.title2)
                    .foregroundStyle(WalletTheme.accent)

                VStack(alignment: .leading, spacing: 2) {
                    Text(
                        verbatim: WalletLocalization.string(
                            "onboarding.carousel.passphrase.visual.output"
                        )
                    )
                        .font(.headline)
                    Text(
                        verbatim: WalletLocalization.string(
                            "onboarding.carousel.passphrase.visual.requirement"
                        )
                    )
                        .font(.caption)
                        .foregroundStyle(WalletTheme.secondaryLabel)
                }

                Spacer(minLength: 8)

                Image(systemName: "checkmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(WalletTheme.success)
            }
            .padding(16)
            .background(
                WalletTheme.groupedSurface,
                in: RoundedRectangle(
                    cornerRadius: 22,
                    style: .continuous
                )
            )
        }
        .padding(18)
        .walletRegularGlassEffect(
            in: RoundedRectangle(cornerRadius: 32, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 32, style: .continuous)
                .stroke(WalletTheme.separator.opacity(0.22), lineWidth: 0.5)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            Text(
                verbatim: WalletLocalization.string(
                    "onboarding.carousel.passphrase.visual.accessibility"
                )
            )
        )
    }
}

private struct OnboardingPassphraseInputVisual: View {
    let symbol: String
    let title: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(WalletTheme.accent)
                .frame(width: 58, height: 58)
                .background(
                    WalletTheme.groupedSurface,
                    in: RoundedRectangle(
                        cornerRadius: 16,
                        style: .continuous
                    )
                )
                .overlay {
                    RoundedRectangle(
                        cornerRadius: 16,
                        style: .continuous
                    )
                    .stroke(
                        WalletTheme.separator.opacity(0.55),
                        lineWidth: 0.7
                    )
                }

            Text(verbatim: title)
                .font(.caption.weight(.semibold))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.72)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .padding(.horizontal, 4)
    }
}

private struct OnboardingOpenSourceCarouselVisual: View {
    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .font(.title2)
                    .foregroundStyle(WalletTheme.accent)

                Text("onboarding.carousel.open_source.visual.repository")
                    .font(.headline)

                Spacer(minLength: 4)
            }
            .padding(14)
            .background(
                WalletTheme.groupedSurface,
                in: RoundedRectangle(
                    cornerRadius: 20,
                    style: .continuous
                )
            )

            HStack(spacing: 7) {
                OnboardingBuildVerificationNode(
                    symbol: "curlybraces",
                    titleKey:
                        "onboarding.carousel.open_source.visual.source"
                )

                OnboardingBuildVerificationConnector()

                OnboardingBuildVerificationNode(
                    symbol: "hammer",
                    titleKey:
                        "onboarding.carousel.open_source.visual.rebuild"
                )

                OnboardingBuildVerificationConnector()

                OnboardingBuildVerificationNode(
                    symbol: "checkmark.seal",
                    titleKey:
                        "onboarding.carousel.open_source.visual.compare"
                )
            }
        }
        .padding(18)
        .walletRegularGlassEffect(
            in: RoundedRectangle(cornerRadius: 32, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 32, style: .continuous)
                .stroke(WalletTheme.separator.opacity(0.22), lineWidth: 0.5)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            Text("onboarding.carousel.open_source.visual.accessibility")
        )
    }
}

private struct OnboardingBuildVerificationNode: View {
    let symbol: String
    let titleKey: LocalizedStringKey

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(WalletTheme.accent)
                .frame(width: 42, height: 42)
                .background(WalletTheme.tertiaryFill, in: Circle())

            Text(titleKey)
                .font(.caption2.weight(.semibold))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.72)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct OnboardingBuildVerificationConnector: View {
    var body: some View {
        Image(systemName: "chevron.forward")
            .font(.caption.weight(.semibold))
            .foregroundStyle(WalletTheme.secondaryLabel)
            .accessibilityHidden(true)
    }
}
