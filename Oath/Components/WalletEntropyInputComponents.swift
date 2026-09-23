import SwiftUI

enum SettingsWalletEntropyDigitGrid {
    nonisolated static var digitCount: Int { 10 }
    nonisolated static var columnCount: Int { 5 }
    nonisolated static var rowCount: Int {
        digitCount / columnCount
    }
}

enum SettingsWalletEntropyDieArtwork {
    static func assetName(for face: Int) -> String? {
        guard (1...6).contains(face) else { return nil }
        return "EntropyDiceFace\(face)"
    }
}

struct SettingsWalletEntropyDieFace: View {
    let face: Int

    var body: some View {
        Group {
            if let imageName = SettingsWalletEntropyDieArtwork.assetName(
                for: face
            ) {
                Image(imageName)
                    .resizable()
                    .renderingMode(.original)
                    .scaledToFit()
            } else {
                Color.clear
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

struct SettingsWalletEntropyPopButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion)
    private var accessibilityReduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(
                accessibilityReduceMotion || !configuration.isPressed
                    ? 1
                    : 0.86
            )
            .animation(
                accessibilityReduceMotion
                    ? nil
                    : .bouncy(duration: 0.25, extraBounce: 0.18),
                value: configuration.isPressed
            )
    }
}

private struct SettingsWalletEntropyLastChoiceBadge: View {
    var body: some View {
        Circle()
            .fill(WalletTheme.accent)
            .frame(width: 14, height: 14)
            .overlay {
                Circle()
                    .stroke(WalletTheme.onAccentLabel, lineWidth: 2)
            }
            .padding(3)
            .accessibilityHidden(true)
    }
}

private struct SettingsWalletEntropyLastChoiceModifier: ViewModifier {
    let entryID: UUID?

    func body(content: Content) -> some View {
        content.overlay(alignment: .topTrailing) {
            if let entryID {
                SettingsWalletEntropyLastChoiceBadge()
                    .id(entryID)
                    .zIndex(1)
            }
        }
    }
}

extension View {
    func walletEntropyLastChoiceBadge(
        entryID: UUID?
    ) -> some View {
        modifier(
            SettingsWalletEntropyLastChoiceModifier(
                entryID: entryID
            )
        )
    }
}

struct SettingsWalletEntropyMethodSelector: View {
    @Binding var selection: SettingsWalletEntropyMethod
    let isDisabled: Bool

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            if Self.usesMenu(for: dynamicTypeSize) {
                accessibilityPicker
            } else {
                segmentedPicker
            }
        }
        .disabled(isDisabled)
        .frame(maxWidth: 560)
        .padding(.horizontal, 16)
    }

    nonisolated static func usesMenu(
        for dynamicTypeSize: DynamicTypeSize
    ) -> Bool {
        dynamicTypeSize.isAccessibilitySize
    }

    private var segmentedPicker: some View {
        methodPicker
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityIdentifier("entropyMethodSelector.segmented")
    }

    private var accessibilityPicker: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("wallet.creation.entropy.method")
                .font(.caption)
                .foregroundStyle(WalletTheme.secondaryLabel)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityHidden(true)

            methodPicker
                .pickerStyle(.menu)
                .labelsHidden()
                .font(.body.weight(.semibold))
                .controlSize(.large)
                .frame(
                    maxWidth: .infinity,
                    minHeight: 44,
                    alignment: .leading
                )
                .contentShape(Rectangle())
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(
                    Text("wallet.creation.entropy.method")
                )
                .accessibilityValue(
                    Text(LocalizedStringKey(titleKey(for: selection)))
                )
                .accessibilityAddTraits(.isButton)
                .accessibilityIdentifier("entropyMethodSelector.menu")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var methodPicker: some View {
        Picker(
            "wallet.creation.entropy.method",
            selection: $selection
        ) {
            ForEach(SettingsWalletEntropyMethod.allCases) { method in
                Text(LocalizedStringKey(titleKey(for: method)))
                    .tag(method)
            }
        }
    }

    private func titleKey(
        for method: SettingsWalletEntropyMethod
    ) -> String {
        switch method {
        case .dice:
            "wallet.creation.entropy.method.dice"
        case .coin:
            "wallet.creation.entropy.method.coin"
        case .digits:
            "wallet.creation.entropy.method.digits"
        }
    }
}

struct SettingsWalletEntropyRecentInputs: View {
    nonisolated static var visibleRowCount: Int { 1 }
    nonisolated static var entriesPerRow: Int { 10 }
    nonisolated static var visibleEntryCapacity: Int {
        visibleRowCount * entriesPerRow
    }

    private static let tileSpacing: CGFloat = 5
    private static let minimumTileSideLength: CGFloat = 18

    let entries: [SettingsWalletEntropyEntry]
    let assessment: SettingsWalletEntropyHealthAssessment

    init(
        entries: [SettingsWalletEntropyEntry],
        assessment: SettingsWalletEntropyHealthAssessment
    ) {
        self.entries = entries
        self.assessment = assessment
    }

    @Environment(\.accessibilityReduceMotion)
    private var accessibilityReduceMotion

    @ScaledMetric(relativeTo: .caption)
    private var preferredTileSideLength: CGFloat = 28
    @State private var didResolveInitialScrollPosition = false

    private var maximumTileSideLength: CGFloat {
        min(max(preferredTileSideLength, 26), 30)
    }

    var body: some View {
        GeometryReader { geometry in
            let containerWidth = max(geometry.size.width, 1)
            let tileSideLength = tileSideLength(
                fitting: containerWidth
            )
            let rows = Array(
                repeating: GridItem(
                    .fixed(tileSideLength),
                    spacing: Self.tileSpacing
                ),
                count: Self.visibleRowCount
            )

            ScrollViewReader { scrollProxy in
                ScrollView(.horizontal) {
                    LazyHGrid(rows: rows, spacing: Self.tileSpacing) {
                        ForEach(entries) { entry in
                            SettingsWalletEntropyRecentInputTile(
                                entry: entry,
                                sideLength: tileSideLength,
                                isFlagged: assessment.flaggedEntryIDs
                                    .contains(entry.id),
                                warningMessageKey: assessment
                                    .warningMessageKey
                            )
                            .id(entry.id)
                        }
                    }
                    .frame(
                        minWidth: containerWidth,
                        alignment: .leading
                    )
                }
                .scrollIndicators(.hidden)
                .task(id: entries.last?.id) {
                    await Task.yield()
                    scrollToNewestEntry(using: scrollProxy)
                }
            }
        }
        .frame(height: maximumTileSideLength)
    }

    nonisolated static func newestEntryID(
        from entries: [SettingsWalletEntropyEntry]
    ) -> UUID? {
        entries.last?.id
    }

    private func tileSideLength(
        fitting containerWidth: CGFloat
    ) -> CGFloat {
        let totalSpacing = CGFloat(Self.entriesPerRow - 1)
            * Self.tileSpacing
        let availableTileWidth = (containerWidth - totalSpacing)
            / CGFloat(Self.entriesPerRow)

        return min(
            maximumTileSideLength,
            max(Self.minimumTileSideLength, availableTileWidth)
        )
    }

    private func scrollToNewestEntry(
        using proxy: ScrollViewProxy
    ) {
        guard let newestEntryID = Self.newestEntryID(
            from: entries
        ) else { return }

        let update = {
            proxy.scrollTo(newestEntryID, anchor: .trailing)
        }

        if didResolveInitialScrollPosition,
           !accessibilityReduceMotion
        {
            withAnimation(.smooth(duration: 0.28)) {
                update()
            }
        } else {
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                update()
            }
        }
        didResolveInitialScrollPosition = true
    }
}

private struct SettingsWalletEntropyRecentInputTile: View {
    let entry: SettingsWalletEntropyEntry
    let sideLength: CGFloat
    let isFlagged: Bool
    let warningMessageKey: String?

    var body: some View {
        accessibleContent
            .frame(width: sideLength, height: sideLength)
            .overlay {
                if isFlagged {
                    RoundedRectangle(
                        cornerRadius: sideLength * 0.24,
                        style: .continuous
                    )
                    .strokeBorder(WalletTheme.danger, lineWidth: 2)
                }
            }
            .accessibilityIdentifier(
                "entropyRecentInput.\(entry.id.uuidString)"
            )
    }

    @ViewBuilder
    private var accessibleContent: some View {
        if isFlagged, let warningMessageKey {
            content
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(accessibilityLabel)
                .accessibilityValue(
                    Text("wallet.creation.entropy.health.section")
                        + Text(verbatim: ": ")
                        + Text(LocalizedStringKey(warningMessageKey))
                )
        } else {
            content
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(accessibilityLabel)
        }
    }

    private var accessibilityLabel: Text {
        switch entry.source {
        case let .dice(face):
            Text(
                verbatim: EnglishNumbers.localized(
                    "wallet.creation.entropy.dice.face",
                    face
                )
            )
        case let .coin(side):
            Text(
                LocalizedStringKey(
                    side == .heads
                        ? "wallet.creation.entropy.coin.heads"
                        : "wallet.creation.entropy.coin.tails"
                )
            )
        case let .digit(digit):
            Text(
                verbatim: EnglishNumbers.localized(
                    "wallet.creation.entropy.digit.accessibility",
                    digit
                )
            )
        }
    }

    @ViewBuilder
    private var content: some View {
        Group {
            switch entry.source {
            case let .dice(face):
                SettingsWalletEntropyDieFace(face: face)

            case let .coin(side):
                SettingsWalletEntropyCoinFace(
                    side: side,
                    diameter: sideLength
                )

            case let .digit(digit):
                Text(verbatim: EnglishNumbers.integer(Int64(digit)))
                    .font(.caption2.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(WalletTheme.onAccentLabel)
                    .frame(
                        width: sideLength,
                        height: sideLength
                    )
                    .background(
                        WalletTheme.accent,
                        in: RoundedRectangle(
                            cornerRadius: sideLength * 0.22,
                            style: .continuous
                        )
                    )
            }
        }
    }
}

struct SettingsWalletEntropyHealthSection<InfoContent: View>: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let assessment: SettingsWalletEntropyHealthAssessment
    @Binding var isShowingInfo: Bool
    @ViewBuilder let infoContent: () -> InfoContent

    var body: some View {
        Section {
            HStack(alignment: .top, spacing: 12) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 10, height: 10)
                    .padding(.top, 6)
                    .accessibilityHidden(true)

                Text(LocalizedStringKey(statusMessageKey))
                    .font(
                        assessment.requiresIntervention
                            ? .body.weight(.semibold)
                            : .body
                    )
                    .foregroundStyle(statusTextColor)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 0)

                if dynamicTypeSize.isAccessibilitySize {
                    informationButton
                        .sheet(isPresented: $isShowingInfo) {
                            infoContent()
                                .walletSheetPresentation(nativeGlass: false)
                                .presentationSizing(.page)
                                .presentationDetents([.large])
                                .presentationDragIndicator(.visible)
                        }
                } else {
                    informationButton
                        .popover(
                            isPresented: $isShowingInfo,
                            attachmentAnchor: .rect(.bounds)
                        ) {
                            infoContent()
                                .walletLocalePresentation()
                                .presentationCompactAdaptation(.popover)
                        }
                }
            }

            if let warningMethodTitleKey {
                LabeledContent(
                    "wallet.creation.entropy.method"
                ) {
                    Text(LocalizedStringKey(warningMethodTitleKey))
                }
            }


        } header: {
            Text("wallet.creation.entropy.health.section")
                .textCase(nil)
        }
    }

    private var informationButton: some View {
        Button(
            "common.learn_more.inline",
            systemImage: "info.circle",
            action: UniHaptic.action(nil, perform: { isShowingInfo = true })
        )
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .foregroundStyle(WalletTheme.accent)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("common.learn_more.inline"))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { UniHaptic.action(nil) { isShowingInfo = true }() }
    }

    private var statusMessageKey: String {
        switch assessment.status {
        case .monitoring, .noWarningSigns:
            "wallet.creation.entropy.health.clear"
        case let .warning(issue):
            issue.messageKey
        }
    }

    private var statusColor: Color {
        switch assessment.status {
        case .monitoring:
            WalletTheme.accent
        case .noWarningSigns:
            WalletTheme.success
        case .warning:
            WalletTheme.danger
        }
    }

    private var warningMethodTitleKey: String? {
        let method: SettingsWalletEntropyMethod
        switch assessment.status {
        case let .warning(.repetition(issueMethod)),
             let .warning(.dominance(issueMethod)),
             let .warning(.predictablePattern(issueMethod)):
            method = issueMethod
        case .monitoring, .noWarningSigns:
            return nil
        }

        switch method {
        case .dice:
            return "wallet.creation.entropy.method.dice"
        case .coin:
            return "wallet.creation.entropy.method.coin"
        case .digits:
            return "wallet.creation.entropy.method.digits"
        }
    }

    private var statusTextColor: Color {
        assessment.requiresIntervention
            ? WalletTheme.danger
            : WalletTheme.primaryLabel
    }
}

struct SettingsWalletEntropyCoinFace: View {
    let side: SettingsWalletEntropyCoinSide
    let diameter: CGFloat

    private var imageName: String {
        side == .heads ? "EntropyCoinHeads" : "EntropyCoinTails"
    }

    var body: some View {
        Image(imageName)
            .resizable()
            .renderingMode(.original)
            .scaledToFit()
            .clipShape(Circle())
            .frame(width: diameter, height: diameter)
            .accessibilityHidden(true)
    }
}

struct SettingsWalletEntropyInputActions: View {
    let isDisabled: Bool
    let onUndo: () -> Void
    let onReset: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: UniHaptic.action(onUndo)) {
                Text("wallet.creation.entropy.undo")
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity)
            }

            Text(verbatim: "|")
                .foregroundStyle(WalletTheme.secondaryLabel)
                .accessibilityHidden(true)

            Button(role: .destructive, action: UniHaptic.action(onReset)) {
                Text("wallet.creation.entropy.reset")
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity)
            }
        }
        .buttonStyle(.borderless)
        .multilineTextAlignment(.center)
        .disabled(isDisabled)
    }
}
