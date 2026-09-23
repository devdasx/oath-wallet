import SwiftUI

struct SmartScannerReviewRow: Identifiable, Hashable {
    enum ValueStyle: Hashable {
        case standard
        case monospaced
        case secret
        case warning
    }

    let id: String
    let titleKey: String
    let value: String
    let valueStyle: ValueStyle
    let progressFraction: Double?

    init(
        id: String,
        titleKey: String,
        value: String,
        valueStyle: ValueStyle = .standard,
        progressFraction: Double? = nil
    ) {
        self.id = id
        self.titleKey = titleKey
        self.value = value
        self.valueStyle = valueStyle
        self.progressFraction = progressFraction
    }
}

struct SmartScannerReviewPresentation: Hashable {
    enum Kind: Hashable {
        case payment
        case address
        case recoveryPhrase
        case privateKey
        case deviceTransfer
        case tokenContract

        var systemImage: String {
            switch self {
            case .payment:
                "arrow.up.right.circle"
            case .address:
                "wallet.pass"
            case .recoveryPhrase:
                "doc.text"
            case .privateKey:
                "key.horizontal"
            case .deviceTransfer:
                "iphone.and.arrow.forward"
            case .tokenContract:
                "shippingbox"
            }
        }
    }

    let kind: Kind
    let heroLogoSource: AssetLogoSource?
    let titleKey: String
    let detailKey: String
    let rows: [SmartScannerReviewRow]
    let warningKey: String?
    let primaryActionKey: String
    let isPrimaryActionDisabled: Bool

    init(
        kind: Kind,
        heroLogoSource: AssetLogoSource? = nil,
        titleKey: String,
        detailKey: String,
        rows: [SmartScannerReviewRow],
        warningKey: String?,
        primaryActionKey: String,
        isPrimaryActionDisabled: Bool = false
    ) {
        self.kind = kind
        self.heroLogoSource = heroLogoSource
        self.titleKey = titleKey
        self.detailKey = detailKey
        self.rows = rows
        self.warningKey = warningKey
        self.primaryActionKey = primaryActionKey
        self.isPrimaryActionDisabled = isPrimaryActionDisabled
    }
}

struct SmartScannerReviewPanel: View {
    let presentation: SmartScannerReviewPresentation
    let onConfirm: () -> Void
    let onCancel: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        List {
            Group {
                Section {
                    VStack(spacing: 12) {
                        reviewHero

                        Text(LocalizedStringKey(presentation.titleKey))
                            .font(WalletTypography.title(.title2))
                            .multilineTextAlignment(.center)
                            .accessibilityAddTraits(.isHeader)

                        Text(LocalizedStringKey(presentation.detailKey))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                }

                Section {
                    ForEach(presentation.rows) { row in
                        reviewRow(row)
                    }
                } header: {
                    Text("smart_scanner.review.details.section")
                }

                if let warningKey = presentation.warningKey {
                    Section {
                        Text(LocalizedStringKey(warningKey))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } header: {
                        Text("smart_scanner.review.warning.section")
                    }
                }
            }
            .walletListRowSurface()
        }
        .walletListAppearance()
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(WalletTheme.groupedBackground)
        .walletSafeAreaBar(edge: .bottom, spacing: 0) {
            actionBar
        }
    }

    @ViewBuilder
    private var reviewHero: some View {
        if let logoSource = presentation.heroLogoSource {
            AssetLogoView(
                source: logoSource,
                size: 64,
                animatesChanges: false
            )
            .accessibilityHidden(true)
        } else {
            Image(systemName: presentation.kind.systemImage)
                .font(
                    .system(
                        size: 32,
                        weight: WalletSFSymbol.weight
                    )
                )
                .foregroundStyle(WalletTheme.accent)
                .frame(width: 64, height: 64)
                .background(
                    WalletTheme.accent.opacity(0.12),
                    in: Circle()
                )
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private func reviewRow(
        _ row: SmartScannerReviewRow
    ) -> some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(LocalizedStringKey(row.titleKey))
                    .font(.caption)
                    .foregroundStyle(WalletTheme.primaryLabel)

                switch row.valueStyle {
                case .standard:
                    Text(verbatim: row.value)
                        .font(.body)
                        .foregroundStyle(WalletTheme.secondaryLabel)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                case .monospaced:
                    WalletExactText(row.value, monospaced: true)
                        .fixedSize(horizontal: false, vertical: true)
                case .secret:
                    WalletExactText(row.value, monospaced: true)
                        .fixedSize(horizontal: false, vertical: true)
                        .walletSensitiveValue()
                case .warning:
                    Text(verbatim: row.value)
                        .font(.body)
                        .foregroundStyle(WalletTheme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let progressFraction = row.progressFraction {
                Gauge(
                    value: min(max(progressFraction, 0), 1),
                    in: 0 ... 1
                ) {
                    Text(LocalizedStringKey(row.titleKey))
                }
                .gaugeStyle(.accessoryCircularCapacity)
                .tint(
                    progressFraction > 0
                        ? WalletTheme.accent
                        : WalletTheme.danger
                )
                .labelsHidden()
                .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var actionBar: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(spacing: 10) {
                    primaryButton
                    cancelButton
                }
            } else {
                HStack(spacing: 12) {
                    cancelButton
                    primaryButton
                }
            }
        }
        .walletActionScreenMargins()
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private var primaryButton: some View {
        PrimaryWalletButton(
            title: LocalizedStringKey(
                presentation.primaryActionKey
            ),
            action: onConfirm
        )
        .disabled(presentation.isPrimaryActionDisabled)
    }

    private var cancelButton: some View {
        SecondaryWalletButton(
            title: "common.cancel",
            hapticPolicy: .silent,
            action: onCancel
        )
    }
}
