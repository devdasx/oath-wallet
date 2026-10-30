import SwiftUI
import OathTokenImages

private struct OathDestructiveRowKey: EnvironmentKey {
    static let defaultValue = false
}

private extension EnvironmentValues {
    var oathDestructiveRow: Bool {
        get { self[OathDestructiveRowKey.self] }
        set { self[OathDestructiveRowKey.self] = newValue }
    }
}

/// Shared Settings primitives: open rows, quiet icon tiles and section rules.
/// Leading/trailing layout is semantic so the same views work in every locale.
struct OathSettingsIcon: View {
    let symbol: String
    var color: Color = Color(uiColor: .label)
    @ScaledMetric(relativeTo: .body) private var size = 38.0

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.54, weight: .regular))
            .foregroundStyle(color)
            .frame(width: size, height: size)
            .background(Color(uiColor: OathSurfaceColors.field), in: .rect(cornerRadius: size * 0.28))
            .accessibilityHidden(true)
    }
}

struct OathSettingsRow: View {
    enum Accessory { case disclosure, selection(Bool), none }

    let title: String
    var icon: String? = nil
    var value: String? = nil
    var truncatesTitle = false
    var isSelected = false
    var accessory: Accessory = .disclosure
    var subtitle: String? = nil
    var subtitleLineLimit: Int? = 2
    var identifierBadge: String? = nil
    var networkLogo: String? = nil
    var tokenLogo: String? = nil
    var tokenSymbol: String? = nil
    var tokenIdentity: TokenArtworkIdentity? = nil
    var isWorking = false
    var imageAsset: String? = nil
    var walletIcon: OathWalletListIcon? = nil
    var color: Color = Color(uiColor: .label)
    var titleWeight: Font.Weight = .regular
    @ScaledMetric(relativeTo: .body) private var iconSize = 38.0
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.oathDestructiveRow) private var destructiveRow

    private var actionColor: Color { destructiveRow ? .red : color }

    var body: some View {
        OathListRow {
            if let walletIcon {
                walletIcon
            }
            else if let imageAsset {
                Image(imageAsset).resizable().scaledToFit().frame(width: iconSize, height: iconSize)
                    .clipShape(.rect(cornerRadius: iconSize * 0.23)).accessibilityHidden(true)
            }
            else if let tokenSymbol { OathTokenLogo(source: tokenLogo, symbol: tokenSymbol, size: iconSize, identity: tokenIdentity) }
            else if let networkLogo { OathNetworkLogo(asset: networkLogo, size: iconSize) }
            else if let icon { OathSettingsIcon(symbol: icon, color: actionColor) }
        } content: {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 5) {
                    titleLabel
                    valueLabel
                }
                Spacer(minLength: 8)
            } else {
                titleLabel.layoutPriority(1)
                Spacer(minLength: 12)
                valueLabel
            }
        } accessory: {
            if isWorking {
                ProgressView()
            } else {
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(OathOnboardingColors.blue)
                        .accessibilityHidden(true)
                }
                switch accessory {
                case .disclosure:
                    Image(systemName: "chevron.forward")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color(uiColor: .secondaryLabel))
                        .accessibilityHidden(true)
                case .selection(let selected):
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(OathOnboardingColors.blue)
                        .opacity(selected ? 1 : 0)
                        .accessibilityHidden(true)
                case .none:
                    EmptyView()
                }
            }
        }
    }

    private var titleLabel: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .oathFont(.body, weight: titleWeight)
                .foregroundStyle(actionColor)
                .lineLimit(truncatesTitle ? 1 : nil)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: !truncatesTitle)
            if let identifierBadge {
                Text(verbatim: identifierBadge)
                    .oathFont(.caption, weight: .medium)
                    .foregroundStyle(Color(uiColor: .secondaryLabel))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Color(uiColor: OathSurfaceColors.field), in: .rect(cornerRadius: 6))
                    .environment(\.layoutDirection, .leftToRight)
            }
            if let subtitle {
                Text(subtitle).oathFont(.subheadline).foregroundStyle(Color(uiColor: .secondaryLabel))
                    .lineLimit(subtitleLineLimit).truncationMode(.tail)
            }
        }
    }

    @ViewBuilder private var valueLabel: some View {
        if let value {
            Text(value)
                .oathFont(.body)
                .foregroundStyle(Color(uiColor: .secondaryLabel))
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }
}

/// One layout contract for settings, wallet actions and asset/network rows.
/// Specialized values (such as attributed balances) keep their own content.
struct OathListRow<Leading: View, Content: View, Accessory: View>: View {
    @ViewBuilder let leading: () -> Leading
    @ViewBuilder let content: () -> Content
    @ViewBuilder let accessory: () -> Accessory

    var body: some View {
        HStack(spacing: 16) {
            leading()
            content()
            accessory()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 17)
        .frame(minHeight: 74)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

enum OathWalletCreationOptions {
    // TODO: Restore the creation entry points when requested; see TODO.md.
    // Existing multisig wallets and their operations remain available.
    static let showsMultisig = false
}

struct OathWalletActions: View {
    let identifier: String
    var isCreating = false
    let onCreate: () -> Void
    let onCreateMultisig: () -> Void
    let onImport: () -> Void
    let onImportPrivateKey: () -> Void
    let onRestore: () -> Void
    @Environment(\.oathLocalizer) private var strings

    var body: some View {
        VStack(spacing: 0) {
            action(.createWallet, icon: "plus.circle", suffix: "create", working: isCreating, onCreate)
            if OathWalletCreationOptions.showsMultisig {
                action(.createMultisignatureWallet, icon: "signature", suffix: "createMultisig", onCreateMultisig)
            }
            action(.importWallet, icon: "square.and.arrow.down", suffix: "import", onImport)
            action(.importPrivateKey, icon: "key.horizontal", suffix: "importPrivateKey", onImportPrivateKey)
            action(.restoreICloud, icon: "icloud", suffix: "restore", onRestore)
        }
    }

    private func action(_ title: OathStringKey, icon: String, suffix: String, working: Bool = false,
                        _ action: @escaping () -> Void) -> some View {
        OathButton(action: action) {
            OathSettingsRow(title: strings.text(title), icon: icon, isWorking: working)
        }
        .buttonStyle(OathSettingsRowButtonStyle())
        .accessibilityIdentifier(identifier + "." + suffix)
    }
}

/// Shared section divider for every Settings flow: two physical display pixels.
struct OathSettingsSectionRule: View {
    var body: some View {
        OathHairline()
            .padding(.vertical, 12)
    }
}

/// An explicit section boundary for plain Lists. Keep it outside movable
/// ForEach content and suppress List's insets and editing controls. Its List
/// sets defaultMinListRowHeight to zero; content rows own their minimum height.
struct OathSettingsListSectionRule: View {
    var body: some View {
        OathSettingsSectionRule()
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .deleteDisabled(true)
            .moveDisabled(true)
    }
}

/// Explanatory copy below a Settings row, shared with iCloud backup's status.
struct OathSettingsFooter<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12, content: content)
            .oathFont(.footnote)
            .foregroundStyle(Color(uiColor: .secondaryLabel))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
    }
}

struct OathSettingsIntroduction: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            OathSettingsIcon(symbol: icon)
            Text(text)
                .oathFont(.subheadline)
                .foregroundStyle(Color(uiColor: .secondaryLabel))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Native button press feedback without decorating every row as a card.
struct OathSettingsRowButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    @ViewBuilder func makeBody(configuration: Configuration) -> some View {
        if configuration.role == .destructive {
            row(configuration)
                .environment(\.oathDestructiveRow, true)
                .foregroundStyle(.red)
                .tint(.red)
        } else {
            row(configuration)
        }
    }

    private func row(_ configuration: Configuration) -> some View {
        configuration.label
            .background(Color(uiColor: OathSurfaceColors.field).opacity(configuration.isPressed ? 0.65 : 0))
            .opacity(isEnabled ? 1 : 0.45)
    }
}

extension View {
    func oathSettingsField() -> some View {
        oathInputRow().oathInputBackground()
    }
}
