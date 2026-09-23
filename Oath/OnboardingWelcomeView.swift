import SwiftUI
import UIKit

/// The pages of the first-run tour, in order. Each pairs a headline with the
/// feature it introduces. Most reuse copy the rest of onboarding already ships,
/// so every locale carries them.
enum OnboardingWelcomePage: Int, CaseIterable, Identifiable, Sendable {
    case networks
    case entropy
    case activity
    case security
    case openSource

    var id: Int { rawValue }

    var titleKey: String {
        switch self {
        case .networks: "onboarding.title.networks_aperture"
        case .entropy: "onboarding.welcome.entropy.title"
        case .activity: "onboarding.title.onchain_control"
        case .security: "onboarding.welcome.security.title"
        case .openSource: "onboarding.carousel.open_source.title"
        }
    }

    var subtitleKey: String {
        switch self {
        case .networks: "onboarding.subtitle.networks_aperture"
        case .entropy: "onboarding.carousel.entropy.message"
        case .activity: "onboarding.subtitle.onchain_control"
        case .security: "onboarding.welcome.security.subtitle"
        case .openSource: "onboarding.carousel.open_source.message"
        }
    }

    /// Tints the illustration's centrepiece. Kept to the cool end of the
    /// settings palette so the tour reads as one object, not five posters.
    var accent: Color {
        switch self {
        case .entropy, .activity, .openSource: WalletTheme.settingsIconBlue
        case .networks: WalletTheme.settingsIconIndigo
        case .security: WalletTheme.settingsIconGreen
        }
    }
}

/// The first-run welcome: a native paged tour of what the wallet does, with the
/// two ways in always within reach beneath it.
@MainActor
struct OnboardingWelcomeView: View {
    let creationErrorMessage: String?
    let onCreateWallet: () -> Void
    let onImportWallet: () -> Void

    @State private var selectedPage = OnboardingWelcomePage.networks
    @State private var isShowingLanguagePicker = false

    var body: some View {
        // Every page change ticks, whether swiped or tapped in the indicator.
        let selection = $selectedPage.hapticSelection()
        GeometryReader { proxy in
            TabView(selection: selection) {
                ForEach(OnboardingWelcomePage.allCases) { page in
                    OnboardingWelcomePageView(
                        page: page,
                        isActive: selectedPage == page,
                        availableSize: proxy.size
                    )
                    .tag(page)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
        }
        .background(WalletTheme.background.ignoresSafeArea())
        .walletSafeAreaBar(edge: .bottom, spacing: 0) {
            VStack(spacing: 18) {
                OnboardingWelcomePageIndicator(selection: selection)
                actions
            }
            .walletActionScreenMargins()
            .padding(.top, 8)
            .padding(.bottom, 12)
        }
        // The system bar carries only the language switch; the emblem is the brand.
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                languageButton
            }
        }
        .sheet(isPresented: $isShowingLanguagePicker) {
            languagePicker
        }
    }

    private var languageButton: some View {
        Button(action: UniHaptic.action(.selection) {
            isShowingLanguagePicker = true
        }) {
            Label("settings.language.title", systemImage: "globe")
        }
        .accessibilityValue(Text(verbatim: WalletAppLanguage.nativeName(
            for: WalletAppLanguage.selectedIdentifier
        )))
        .accessibilityIdentifier("onboardingChooseLanguage")
    }

    private var languagePicker: some View {
        NavigationStack {
            AppLanguageSettingsView()
                .toolbar(.visible, for: .navigationBar)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("common.done", action: UniHaptic.action {
                            isShowingLanguagePicker = false
                        })
                    }
                }
        }
        .walletSheetPresentation(nativeGlass: false)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private var actions: some View {
        VStack(spacing: 12) {
            PrimaryWalletButton(
                title: "onboarding.action.create",
                hapticPolicy: .silent,
                action: onCreateWallet
            )
            .accessibilityIdentifier("onboardingCreateWallet")

            SecondaryWalletButton(
                title: "onboarding.action.import",
                hapticPolicy: .silent,
                action: onImportWallet
            )
            .accessibilityIdentifier("onboardingImportWallet")

            if let creationErrorMessage {
                Text(verbatim: creationErrorMessage)
                    .font(.footnote)
                    .foregroundStyle(WalletTheme.secondaryLabel)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity)
            }
        }
        .walletActionUsesContainerMargins()
    }
}

// MARK: - Paging

/// The current page stretches into a pill; the rest stay as dots. Tapping one
/// jumps to it. VoiceOver navigates through the pager itself, so this stays
/// out of the accessibility tree.
private struct OnboardingWelcomePageIndicator: View {
    @Binding var selection: OnboardingWelcomePage
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 6) {
            ForEach(OnboardingWelcomePage.allCases) { page in
                let isCurrent = page == selection
                Button(action: UniHaptic.action(nil) {
                    selection = page
                }) {
                    Capsule()
                        .fill(WalletTheme.primaryLabel.opacity(isCurrent ? 0.9 : 0.16))
                        .frame(width: isCurrent ? 22 : 7, height: 7)
                        .padding(.vertical, 8)
                        .padding(.horizontal, 2)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.35), value: selection)
        .accessibilityHidden(true)
    }
}

// MARK: - Page

private struct OnboardingWelcomePageView: View {
    let page: OnboardingWelcomePage
    let isActive: Bool
    let availableSize: CGSize

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .largeTitle) private var headlineSize: CGFloat = 42
    @ScaledMetric(relativeTo: .body) private var bodySize: CGFloat = 17
    @State private var hasAppeared = false

    var body: some View {
        let textWidth = max(1, min(availableSize.width - 48, 440))
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                ScrollView {
                    VStack(spacing: 28) {
                        stage(size: min(availableSize.width - 48, 240))
                        copy(width: textWidth, compact: false)
                    }
                    .padding(.vertical, 20)
                    .frame(maxWidth: .infinity)
                }
                .scrollBounceBehavior(.basedOnSize)
            } else if availableSize.width > 680 && availableSize.height < 480 {
                HStack(spacing: 32) {
                    stage(size: min(availableSize.height * 0.8, 300))
                        .frame(maxWidth: .infinity)
                    copy(width: (min(availableSize.width - 48, 840) - 32) / 2, compact: true)
                        .frame(maxWidth: .infinity)
                }
                .frame(maxWidth: 840)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let compact = availableSize.height < 520
                // A fixed stage keeps the headline on the same baseline across pages.
                let stageSize = min(
                    availableSize.width - 48,
                    340,
                    max(160, availableSize.height * (compact ? 0.44 : 0.52))
                )
                VStack(spacing: compact ? 16 : 28) {
                    stage(size: stageSize)
                        .frame(height: stageSize)
                    copy(width: textWidth, compact: compact)
                }
                .padding(.top, compact ? 4 : 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .padding(.horizontal, 24)
        .onAppear { hasAppeared = true }
    }

    private func stage(size: CGFloat) -> some View {
        Group {
            switch page {
            case .networks:
                OnboardingWelcomeNetworksVisual(size: size, isActive: isActive)
            case .entropy:
                OnboardingWelcomeEntropyVisual(size: size, isActive: isActive)
            case .activity:
                OnboardingWelcomeActivityVisual(size: size)
            case .security:
                OnboardingWelcomeSecurityVisual(size: size, isActive: isActive, accent: page.accent)
            case .openSource:
                OnboardingWelcomeOpenSourceVisual(size: size, isActive: isActive, accent: page.accent)
            }
        }
        .frame(width: size, height: size)
        .scaleEffect(hasAppeared ? 1 : 0.92)
        .opacity(hasAppeared ? 1 : 0)
        .animation(reduceMotion ? nil : .smooth(duration: 0.6), value: hasAppeared)
        .accessibilityHidden(true)
    }

    private func copy(width: CGFloat, compact: Bool) -> some View {
        VStack(spacing: compact ? 12 : 16) {
            Text(verbatim: title)
                .font(.system(
                    size: fittedTitleSize(width: width, compact: compact),
                    weight: .bold, design: .rounded
                ))
                .tracking(dynamicTypeSize.isAccessibilitySize ? 0 : -0.8)
                .foregroundStyle(WalletTheme.primaryLabel)
                .multilineTextAlignment(.center)
                .lineSpacing(locale.language.languageCode?.identifier == "my" ? 10 : 2)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 3)
                .minimumScaleFactor(0.72)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("onboardingWelcomeTitle")

            Text(verbatim: subtitle)
                .font(.system(size: bodySize * (compact ? 0.9 : 1)))
                .foregroundStyle(WalletTheme.secondaryLabel)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 380)
                .accessibilityIdentifier("onboardingWelcomeSubtitle")
        }
        .frame(maxWidth: .infinity)
    }

    private var localizedBundle: Bundle {
        let language = Bundle.preferredLocalizations(
            from: WalletAppLanguage.supportedIdentifiers,
            forPreferences: [locale.identifier]
        ).first ?? WalletAppLanguage.defaultIdentifier
        return WalletAppLanguage.localizedBundle(for: language)
    }

    /// Headlines are two lines. Copy authored as one sentence pair breaks at its
    /// first full stop so each line stays whole instead of wrapping mid-sentence.
    private var title: String {
        let raw = localizedBundle.localizedString(forKey: page.titleKey, value: nil, table: nil)
        guard !raw.contains("\n") else { return raw }
        let terminators: Set<Character> = [".", "!", "?", "。", "！", "？", "।", "۔"]
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard let breakIndex = trimmed.indices.first(where: { index in
            terminators.contains(trimmed[index])
                && trimmed[trimmed.index(after: index)...].contains(where: { !$0.isWhitespace })
        }) else { return raw }
        let head = trimmed[...breakIndex]
        let tail = trimmed[trimmed.index(after: breakIndex)...].trimmingCharacters(in: .whitespaces)
        return String(head) + "\n" + tail
    }

    private var subtitle: String {
        localizedBundle.localizedString(forKey: page.subtitleKey, value: nil, table: nil)
    }

    private func fittedTitleSize(width: CGFloat, compact: Bool) -> CGFloat {
        let preferred = headlineSize * (compact ? 0.78 : 1)
        guard !dynamicTypeSize.isAccessibilitySize else { return preferred }
        let lines = title.components(separatedBy: .newlines)
        guard lines.count > 1 else { return preferred }
        func fits(_ size: CGFloat) -> Bool {
            let systemFont = UIFont.systemFont(ofSize: size, weight: .bold)
            let font = UIFont(
                descriptor: systemFont.fontDescriptor.withDesign(.rounded) ?? systemFont.fontDescriptor,
                size: size
            )
            return lines.allSatisfy {
                ($0 as NSString).size(withAttributes: [.font: font]).width <= max(1, width - 2)
            }
        }
        guard !fits(preferred) else { return preferred }
        var lower = min(20, preferred)
        var upper = preferred
        while upper - lower > 0.25 {
            let candidate = (lower + upper) / 2
            if fits(candidate) { lower = candidate } else { upper = candidate }
        }
        return lower
    }
}

// MARK: - Illustrations

/// The networks the wallet speaks, orbiting the emblem. Two rings turn against
/// each other; every logo counter-rotates so it stays upright.
private struct OnboardingWelcomeNetworksVisual: View {
    let size: CGFloat
    let isActive: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let innerRing = [
        "NetworkLogoBitcoin", "NetworkLogoEthereum", "NetworkLogoSolana",
        "NetworkLogoTON", "NetworkLogoTron", "NetworkLogoXRP"
    ]
    private static let outerRing = [
        "NetworkLogoBase", "NetworkLogoArbitrum", "NetworkLogoPolygon",
        "NetworkLogoBNBSmartChain", "NetworkLogoAvalanche", "NetworkLogoSui",
        "NetworkLogoNEAR", "NetworkLogoStellar", "NetworkLogoOptimism", "NetworkLogoAptos"
    ]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion || !isActive)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            ZStack {
                ring(
                    radius: size * 0.45, logos: Self.outerRing, logoSize: size * 0.105,
                    rotation: -time * 360 / 110, opacity: 0.92
                )
                ring(
                    radius: size * 0.28, logos: Self.innerRing, logoSize: size * 0.14,
                    rotation: time * 360 / 70, opacity: 1
                )
                OnboardingOathArtwork(size: size * 0.32)
            }
            .frame(width: size, height: size)
        }
        // A physical arrangement, independent of reading direction.
        .environment(\.layoutDirection, .leftToRight)
    }

    private func ring(
        radius: CGFloat, logos: [String], logoSize: CGFloat,
        rotation: Double, opacity: Double
    ) -> some View {
        ZStack {
            Circle()
                .stroke(WalletTheme.separator.opacity(0.5), lineWidth: 1)
                .frame(width: radius * 2, height: radius * 2)
            ForEach(Array(logos.enumerated()), id: \.offset) { index, name in
                let angle = Angle.degrees(rotation + Double(index) / Double(logos.count) * 360 - 90)
                OfficialNetworkLogoView(assetName: name, size: logoSize)
                    .padding(logoSize * 0.09)
                    .background(Circle().fill(WalletTheme.background))
                    .shadow(color: .black.opacity(0.12), radius: logoSize * 0.18, y: logoSize * 0.08)
                    .offset(x: cos(angle.radians) * radius, y: sin(angle.radians) * radius)
            }
        }
        .opacity(opacity)
    }
}

/// Physical randomness becoming keys. A die, a coin and a digit feed a ribbon
/// of bits that settles into a recovery phrase; the die tumbles, the coin turns
/// and the digit keeps rolling while the page is showing.
private struct OnboardingWelcomeEntropyVisual: View {
    let size: CGFloat
    let isActive: Bool
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // A fixed pattern, so the ribbon reads as bits rather than as flicker.
    private static let bits = Array("1011001011100101001101110100101100011010")
    private static let digits = [7, 3, 0, 9, 4, 1, 8, 5, 2, 6]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion || !isActive)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            VStack(spacing: size * 0.04) {
                HStack(alignment: .center, spacing: size * 0.07) {
                    die(side: size * 0.23, tilt: sin(time * 0.9) * 9)
                    coin(diameter: size * 0.2, angle: reduceMotion ? 0 : coinAngle(at: time))
                    digitTile(side: size * 0.2, index: Int(time / 0.9) % Self.digits.count)
                }
                .padding(.bottom, size * 0.02)

                Image(systemName: "arrow.down")
                    .font(.system(size: size * 0.05, weight: .bold))
                    .foregroundStyle(WalletTheme.tertiaryLabel)

                bitRibbon(width: size * 0.86, height: size * 0.11, time: time)

                Image(systemName: "arrow.down")
                    .font(.system(size: size * 0.05, weight: .bold))
                    .foregroundStyle(WalletTheme.tertiaryLabel)

                HStack(spacing: 6) {
                    Image(systemName: "key.fill")
                        .font(.system(size: size * 0.036, weight: .bold))
                    Text("onboarding.entropy.learn_more.visual.phrase")
                        .font(.system(size: size * 0.036, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .foregroundStyle(WalletTheme.primaryLabel)
                .padding(.vertical, size * 0.028)
                .padding(.horizontal, size * 0.05)
                .background { surface(Capsule()) }
                .overlay { Capsule().strokeBorder(WalletTheme.separator.opacity(0.35), lineWidth: 0.5) }
            }
            .frame(width: size, height: size)
        }
        // A physical arrangement, independent of reading direction.
        .environment(\.layoutDirection, .leftToRight)
    }

    // MARK: Inputs

    private func die(side: CGFloat, tilt: Double) -> some View {
        let pips: [CGPoint] = [
            CGPoint(x: 0.27, y: 0.27), CGPoint(x: 0.73, y: 0.27), CGPoint(x: 0.5, y: 0.5),
            CGPoint(x: 0.27, y: 0.73), CGPoint(x: 0.73, y: 0.73)
        ]
        return ZStack {
            RoundedRectangle(cornerRadius: side * 0.22, style: .continuous)
                .fill(LinearGradient(
                    colors: [.white, Color(white: 0.9)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ))
                .overlay {
                    RoundedRectangle(cornerRadius: side * 0.22, style: .continuous)
                        .strokeBorder(Color.black.opacity(0.12), lineWidth: 0.5)
                }
            ForEach(Array(pips.enumerated()), id: \.offset) { _, pip in
                Circle()
                    .fill(Color(white: 0.12))
                    .frame(width: side * 0.15, height: side * 0.15)
                    .position(x: pip.x * side, y: pip.y * side)
            }
        }
        .frame(width: side, height: side)
        .rotation3DEffect(.degrees(tilt), axis: (x: 0.4, y: 1, z: 0), perspective: 0.6)
        .rotationEffect(.degrees(-8))
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.5 : 0.16), radius: side * 0.2, y: side * 0.1)
    }

    /// A coin flips, then rests: one half-turn every few seconds, so it is
    /// face-up for most of the time and any single frame still reads as a coin.
    private func coinAngle(at time: Double) -> Double {
        let period = 4.0
        let flipDuration = 0.6
        let phase = time.truncatingRemainder(dividingBy: period)
        let completedFlips = (time / period).rounded(.down)
        let progress = min(1, phase / flipDuration)
        let eased = 0.5 - cos(progress * .pi) / 2
        return (completedFlips + eased) * 180
    }

    private func coin(diameter: CGFloat, angle: Double) -> some View {
        ZStack {
            Circle()
                .fill(LinearGradient(
                    colors: [Color(white: 0.98), Color(white: 0.76)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ))
            Circle()
                .strokeBorder(Color(white: 0.55).opacity(0.55), lineWidth: diameter * 0.035)
                .padding(diameter * 0.07)
            // Struck on both faces, so the coin never rests as a blank disc.
            HeroBrandMark(size: diameter * 0.46, color: Color(white: 0.22))
        }
        .frame(width: diameter, height: diameter)
        .rotation3DEffect(.degrees(angle), axis: (x: 0, y: 1, z: 0), perspective: 0.5)
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.5 : 0.16), radius: diameter * 0.18, y: diameter * 0.1)
    }

    private func digitTile(side: CGFloat, index: Int) -> some View {
        let digit = String(Self.digits[index])
        return Text(verbatim: digit)
            .font(.system(size: side * 0.5, weight: .bold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(WalletTheme.primaryLabel)
            .contentTransition(.numericText())
            .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: digit)
            .frame(width: side, height: side)
            .background { surface(RoundedRectangle(cornerRadius: side * 0.26, style: .continuous)) }
            .overlay {
                RoundedRectangle(cornerRadius: side * 0.26, style: .continuous)
                    .strokeBorder(WalletTheme.separator.opacity(0.35), lineWidth: 0.5)
            }
    }

    // MARK: Output

    private func bitRibbon(width: CGFloat, height: CGFloat, time: Double) -> some View {
        let count = Self.bits.count
        let cell = height * 0.6
        let cycle = cell * CGFloat(count)
        let shift = CGFloat((time * 24).truncatingRemainder(dividingBy: Double(cycle)))
        return HStack(spacing: 0) {
            ForEach(0..<(count * 2), id: \.self) { index in
                Text(verbatim: String(Self.bits[index % count]))
                    .font(.system(size: height * 0.42, weight: .semibold, design: .monospaced))
                    .foregroundStyle(WalletTheme.secondaryLabel)
                    .frame(width: cell)
            }
        }
        .offset(x: -shift)
        .frame(width: width, height: height, alignment: .leading)
        .clipShape(Capsule())
        .mask {
            LinearGradient(stops: [
                .init(color: .clear, location: 0), .init(color: .black, location: 0.1),
                .init(color: .black, location: 0.9), .init(color: .clear, location: 1)
            ], startPoint: .leading, endPoint: .trailing)
        }
        .background { surface(Capsule()) }
        .overlay { Capsule().strokeBorder(WalletTheme.separator.opacity(0.35), lineWidth: 0.5) }
    }

    private func surface<S: Shape>(_ shape: S) -> some View {
        shape
            .fill(colorScheme == .dark ? WalletTheme.secondarySurface : WalletTheme.background)
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.45 : 0.1), radius: size * 0.035, y: size * 0.018)
    }
}

/// A wallet as it actually looks: balance, the two actions, and settled activity.
private struct OnboardingWelcomeActivityVisual: View {
    let size: CGFloat
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isActivityRevealed = false

    private let networkLogos = ["NetworkLogoEthereum", "NetworkLogoBitcoin", "NetworkLogoSolana"]

    var body: some View {
        let cardWidth = min(size, 330)
        let scale = cardWidth / 330
        VStack(alignment: .leading, spacing: 14 * scale) {
            HStack(spacing: 10 * scale) {
                OnboardingBrandMark(size: 36 * scale)
                VStack(alignment: .leading, spacing: 1) {
                    Text("wallet.home.wallet.name.default")
                        .font(.system(size: 15 * scale, weight: .semibold))
                        .foregroundStyle(WalletTheme.primaryLabel)
                    Text("wallet.home.balance.label")
                        .font(.system(size: 12 * scale))
                        .foregroundStyle(WalletTheme.secondaryLabel)
                }
                Spacer(minLength: 8)
                logoStack(logoSize: 24 * scale)
            }

            Text(verbatim: EnglishNumbers.currency(Decimal(12_480.32), currencyCode: "USD"))
                .font(.system(size: 34 * scale, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(WalletTheme.primaryLabel)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            HStack(spacing: 8 * scale) {
                actionPill(key: "wallet.home.action.send", symbol: "arrow.up", prominent: true, scale: scale)
                actionPill(key: "wallet.home.action.receive", symbol: "arrow.down", prominent: false, scale: scale)
            }

            VStack(spacing: 0) {
                activityRow(
                    logo: "NetworkLogoEthereum", directionKey: "wallet.transaction.details.direction.sent",
                    symbol: "ETH", amount: Decimal(string: "0.5") ?? 0, isIncoming: false, scale: scale
                )
                Divider().padding(.leading, 46 * scale)
                activityRow(
                    logo: "NetworkLogoBitcoin", directionKey: "wallet.transaction.details.direction.received",
                    symbol: "BTC", amount: Decimal(string: "0.084") ?? 0, isIncoming: true, scale: scale
                )
            }
            .padding(.horizontal, 12 * scale)
            .background(
                WalletTheme.tertiaryFill,
                in: RoundedRectangle(cornerRadius: 18 * scale, style: .continuous)
            )
            .opacity(isActivityRevealed ? 1 : 0)
            .offset(y: isActivityRevealed ? 0 : 10)
        }
        .padding(18 * scale)
        .frame(width: cardWidth)
        .background {
            RoundedRectangle(cornerRadius: 30 * scale, style: .continuous)
                .fill(colorScheme == .dark ? WalletTheme.secondarySurface : WalletTheme.background)
                .shadow(color: .black.opacity(colorScheme == .dark ? 0.5 : 0.12), radius: 28, y: 14)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 30 * scale, style: .continuous)
                .strokeBorder(WalletTheme.separator.opacity(0.35), lineWidth: 0.5)
        }
        .onAppear {
            withAnimation(reduceMotion ? nil : .smooth(duration: 0.55).delay(0.3)) {
                isActivityRevealed = true
            }
        }
    }

    private func logoStack(logoSize: CGFloat) -> some View {
        HStack(spacing: -logoSize * 0.3) {
            ForEach(Array(networkLogos.enumerated()), id: \.offset) { _, name in
                OfficialNetworkLogoView(assetName: name, size: logoSize)
                    .padding(2)
                    .background(Circle().fill(colorScheme == .dark ? WalletTheme.secondarySurface : WalletTheme.background))
            }
        }
    }

    private func actionPill(key: LocalizedStringKey, symbol: String, prominent: Bool, scale: CGFloat) -> some View {
        HStack(spacing: 6 * scale) {
            Image(systemName: symbol)
                .font(.system(size: 12 * scale, weight: .bold))
            Text(key)
                .font(.system(size: 14 * scale, weight: .semibold))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10 * scale)
        .background(prominent ? WalletTheme.primaryAction : WalletTheme.tertiaryFill, in: Capsule())
        .foregroundStyle(prominent ? WalletTheme.onAccentLabel : WalletTheme.primaryLabel)
    }

    private func activityRow(
        logo: String, directionKey: LocalizedStringKey, symbol: String,
        amount: Decimal, isIncoming: Bool, scale: CGFloat
    ) -> some View {
        let formatted = EnglishNumbers.decimal(amount, minimumFractionDigits: 0, maximumFractionDigits: 3)
        return HStack(spacing: 12 * scale) {
            OfficialNetworkLogoView(assetName: logo, size: 34 * scale)
            VStack(alignment: .leading, spacing: 2) {
                Text(directionKey)
                    .font(.system(size: 15 * scale, weight: .medium))
                    .foregroundStyle(WalletTheme.primaryLabel)
                HStack(spacing: 3) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 10 * scale, weight: .bold))
                    Text("wallet.activity.status.confirmed")
                        .font(.system(size: 12 * scale))
                }
                .foregroundStyle(WalletTheme.success)
            }
            Spacer(minLength: 8)
            Text(verbatim: (isIncoming ? "+" : "−") + formatted + " " + symbol)
                .font(.system(size: 15 * scale, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(isIncoming ? WalletTheme.gain : WalletTheme.primaryLabel)
        }
        .padding(.vertical, 10 * scale)
    }
}

/// The lock at the centre, and the four things that make it yours floating
/// around it: Face ID, the recovery phrase, iCloud, and the privacy shield.
private struct OnboardingWelcomeSecurityVisual: View {
    let size: CGFloat
    let isActive: Bool
    let accent: Color
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion || !isActive)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            ZStack {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: size * 0.42, weight: .medium))
                    .foregroundStyle(LinearGradient(
                        colors: [accent, accent.opacity(0.72)],
                        startPoint: .top, endPoint: .bottom
                    ))
                    .shadow(color: accent.opacity(0.35), radius: size * 0.08, y: size * 0.03)

                tile("faceid", x: -0.33, y: -0.27, phase: 0.0, time: time)
                tile("key.fill", x: 0.35, y: -0.21, phase: 1.4, time: time)
                tile("icloud.fill", x: -0.35, y: 0.25, phase: 2.6, time: time)
                tile("eye.slash.fill", x: 0.33, y: 0.30, phase: 3.9, time: time)
            }
            .frame(width: size, height: size)
        }
        .environment(\.layoutDirection, .leftToRight)
    }

    private func tile(_ symbol: String, x: CGFloat, y: CGFloat, phase: Double, time: Double) -> some View {
        let drift = sin(time * 0.8 + phase) * size * 0.014
        let side = size * 0.19
        return Image(systemName: symbol)
            .font(.system(size: size * 0.085, weight: .semibold))
            .foregroundStyle(WalletTheme.primaryLabel)
            .frame(width: side, height: side)
            .background {
                RoundedRectangle(cornerRadius: side * 0.3, style: .continuous)
                    .fill(colorScheme == .dark ? WalletTheme.secondarySurface : WalletTheme.background)
                    .shadow(color: .black.opacity(colorScheme == .dark ? 0.45 : 0.12), radius: side * 0.25, y: side * 0.12)
            }
            .overlay {
                RoundedRectangle(cornerRadius: side * 0.3, style: .continuous)
                    .strokeBorder(WalletTheme.separator.opacity(0.35), lineWidth: 0.5)
            }
            .offset(x: x * size, y: y * size + drift)
    }
}

/// A release that can be checked: the published fingerprint, the seal, and the
/// verdict a reproducible build gives.
private struct OnboardingWelcomeOpenSourceVisual: View {
    let size: CGFloat
    let isActive: Bool
    let accent: Color
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // A stand-in for a release digest; the real one lives on the published build.
    private let sampleFingerprint = "4c1e 9f0a  b7d2 8e63  a72b 5d19"

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion || !isActive)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            ZStack {
                VStack(spacing: size * 0.045) {
                    chip {
                        Text(verbatim: sampleFingerprint)
                            .font(.system(size: size * 0.034, weight: .medium, design: .monospaced))
                            .foregroundStyle(WalletTheme.secondaryLabel)
                    }

                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: size * 0.33, weight: .medium))
                        .foregroundStyle(LinearGradient(
                            colors: [accent, accent.opacity(0.72)],
                            startPoint: .top, endPoint: .bottom
                        ))
                        .shadow(color: accent.opacity(0.35), radius: size * 0.08, y: size * 0.03)

                    chip {
                        HStack(spacing: 5) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: size * 0.036, weight: .bold))
                            Text("onboarding.carousel.open_source.visual.match")
                                .font(.system(size: size * 0.034, weight: .bold))
                                .tracking(0.4)
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                        }
                        .foregroundStyle(WalletTheme.success)
                    }
                }

                tile("chevron.left.forwardslash.chevron.right", x: -0.37, y: -0.04, phase: 0.6, time: time)
                tile("hammer.fill", x: 0.37, y: 0.02, phase: 2.3, time: time)
            }
            .frame(width: size, height: size)
            .clipped()
        }
        .environment(\.layoutDirection, .leftToRight)
    }

    private func chip<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(.vertical, size * 0.028)
            .padding(.horizontal, size * 0.05)
            .background {
                Capsule()
                    .fill(colorScheme == .dark ? WalletTheme.secondarySurface : WalletTheme.background)
                    .shadow(color: .black.opacity(colorScheme == .dark ? 0.45 : 0.10), radius: size * 0.04, y: size * 0.02)
            }
            .overlay {
                Capsule().strokeBorder(WalletTheme.separator.opacity(0.35), lineWidth: 0.5)
            }
    }

    private func tile(_ symbol: String, x: CGFloat, y: CGFloat, phase: Double, time: Double) -> some View {
        let drift = sin(time * 0.8 + phase) * size * 0.014
        let side = size * 0.17
        return Image(systemName: symbol)
            .font(.system(size: size * 0.07, weight: .semibold))
            .foregroundStyle(WalletTheme.primaryLabel)
            .frame(width: side, height: side)
            .background {
                RoundedRectangle(cornerRadius: side * 0.3, style: .continuous)
                    .fill(colorScheme == .dark ? WalletTheme.secondarySurface : WalletTheme.background)
                    .shadow(color: .black.opacity(colorScheme == .dark ? 0.45 : 0.12), radius: side * 0.25, y: side * 0.12)
            }
            .overlay {
                RoundedRectangle(cornerRadius: side * 0.3, style: .continuous)
                    .strokeBorder(WalletTheme.separator.opacity(0.35), lineWidth: 0.5)
            }
            .offset(x: x * size, y: y * size + drift)
    }
}

#Preview {
    OnboardingWelcomeView(creationErrorMessage: nil, onCreateWallet: {}, onImportWallet: {})
}
