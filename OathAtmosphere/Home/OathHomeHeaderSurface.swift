import SwiftUI

extension View {
    /// Shared native bar configuration; artwork screens add their edge-aware
    /// appearance separately so plain lists follow the current system theme.
    func oathNativeAppBar(title: String = "", background: Visibility = .automatic, file: StaticString = #fileID, line: UInt = #line) -> some View {
        navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.visible, for: .navigationBar)
            .oathNativeLocalization(navigationBackground: background, navigationMaterial: nil, systemNavigationAppearance: true,
                                    file: file, line: line)
    }

    /// Use on the destination content, never the NavigationStack, so pushed
    /// settings and sheets retain their own native appearance.
    func oathArtworkAppBar(file: StaticString = #fileID, line: UInt = #line) -> some View {
        oathNativeAppBar(file: file, line: line)
            .modifier(OathArtworkNavigationAppearance())
    }
}


/// Keep symbols in custom grouped labels at the same system body/large scale
/// as navigation-bar symbols. Label fonts must not resize individual icons.
struct OathNavigationToolbarSymbol: View {
    let name: String
    init(_ name: String) { self.name = name }
    var body: some View {
        Image(systemName: name)
            .font(.system(.body, design: .default).weight(.semibold))
            .imageScale(.large)
    }
}

/// One native toolbar button: the chevron, divider and asset identity all go back.
struct OathAssetBackButton: View {
    let name: String
    let backLabel: String
    var chain: OathImportChain? = nil
    let action: () -> Void
    @ScaledMetric(relativeTo: .subheadline) private var badgeSize = 18.0

    private var accessibilityText: String {
        [backLabel, name, chain?.name].compactMap { $0 }.joined(separator: ", ")
    }

    var body: some View {
        OathButton(action: action) {
            HStack(spacing: 0) {
                OathNavigationToolbarSymbol("chevron.backward")
                    .frame(width: 44, height: 44)
                Divider().frame(height: 22)
                HStack(spacing: 6) {
                    if let chain {
                        OathNetworkLogo(asset: chain.logoAsset, size: badgeSize)
                            .fixedSize()
                            .accessibilityHidden(true)
                    }
                    Text(name)
                        .oathFont(.subheadline, weight: .semibold)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                    .padding(.horizontal, 10)
                    .frame(maxWidth: 180, minHeight: 44)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .fixedSize(horizontal: true, vertical: false)
            .contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityText)
            .accessibilityIdentifier("asset.back")
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityText)
        .accessibilityIdentifier("asset.back")
    }
}

/// Give the native toolbar a content-sized label with a bounded display name.
/// The saved name and the full accessibility label are never shortened.
struct OathHomeWalletSelector: View {
    let name: String
    let action: () -> Void
    @Environment(\.oathLocalizer) private var strings

    private var displayName: String {
        let limit = 20
        // Count Characters so emoji and combined letters stay intact. The
        // ellipsis is included in the toolbar's display-only character limit.
        guard name.count > limit else { return name }
        return String(name.prefix(limit - 1)) + "…"
    }

    var body: some View {
        OathButton(action: action) {
            HStack(spacing: 6) {
                Text(displayName)
                    .oathFont(.subheadline, weight: .semibold)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "chevron.down")
                    .imageScale(.small)
                    .fixedSize()
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
            .frame(minWidth: 44, maxWidth: 180, minHeight: 44)
            // Toolbar hosting can propose a minimal width to custom groups.
            // Answer with the label's ideal width, capped above for long names
            // and larger text sizes, instead of collapsing the Text to zero.
            .fixedSize(horizontal: true, vertical: false)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(name)
        .accessibilityHint(strings.text(.switchWallet))
        .accessibilityIdentifier("home.walletSwitcher")
    }
}

/// A fixed viewport canvas, masked to the header above the Assets surface.
/// Scroll and refresh never resize the renderer.
struct OathHomeHeaderSurface: View {
    let animates: Bool
    var colorHex: String? = nil

    var body: some View {
        GeometryReader { geometry in
            OathBackground(placement: .walletBackdrop(size: geometry.size),
                           animates: animates, customColor: colorHex.flatMap { UInt32($0, radix: 16) })
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The native list owns the edge transition without scroll-offset thresholds.
struct OathHomeScrollEdgeAppearance: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content.scrollEdgeEffectStyle(.soft, for: .top)
        } else {
            content
        }
    }
}

/// Home, History and asset details share native placement, automatic glass grouping,
/// and semantic foregrounds. Only their actions and leading identity differ.
struct OathArtworkToolbar<Leading: View, Trailing: View>: ToolbarContent {
    @ViewBuilder let leading: () -> Leading
    @ViewBuilder let trailing: () -> Trailing

    var body: some ToolbarContent {
        if #available(iOS 26, *) {
            leadingItem.sharedBackgroundVisibility(.automatic)
            trailingItem.sharedBackgroundVisibility(.automatic)
        } else {
            leadingItem
            trailingItem
        }
    }

    private var leadingItem: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            leading().buttonStyle(.plain).foregroundStyle(.primary)
        }
    }

    private var trailingItem: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            trailing().buttonStyle(.plain).foregroundStyle(.primary)
        }
    }
}

/// Native navigation owns placement, RTL and the safe area.
/// Settings and the wallet selector form one leading control with two actions.
struct OathHomeToolbar: ToolbarContent {
    let walletName: String
    let canSwitchWallet: Bool
    let onSwitchWallet: () -> Void
    let onScan: () -> Void
    let onSettings: () -> Void
    @Environment(\.oathLocalizer) private var strings

    var body: some ToolbarContent {
        OathArtworkToolbar {
            HStack(spacing: 0) {
                OathHomeSettingsToolbarItem(onSettings: onSettings)
                Divider()
                    .frame(height: 22)
                    .accessibilityHidden(true)
                OathHomeWalletSelector(name: walletName, action: onSwitchWallet)
                    .disabled(!canSwitchWallet)
            }
            .fixedSize(horizontal: true, vertical: false)
        } trailing: {
            OathButton(feedback: .scan, action: onScan) {
                OathNavigationToolbarSymbol("viewfinder")
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
            }
            .accessibilityLabel(strings.text(.scan))
            .accessibilityIdentifier("home.scanner")
        }
    }
}

private struct OathHomeSettingsToolbarItem: View {
    let onSettings: () -> Void
    @Environment(\.oathLocalizer) private var strings
    var body: some View {
        OathButton(action: onSettings) {
            OathNavigationToolbarSymbol("slider.horizontal.3")
                .foregroundStyle(.primary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(strings.text(.walletSettings))
        .accessibilityIdentifier("home.settings")
    }
}
