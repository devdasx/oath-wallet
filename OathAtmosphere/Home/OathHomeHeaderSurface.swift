import SwiftUI

/// Give the native toolbar a content-sized label with a bounded display name.
/// The saved name and the full accessibility label are never shortened.
struct OathHomeWalletSelector: View {
    let name: String
    let effects: OathHomeScrollEffects
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
        .modifier(OathHomeToolbarForeground(effects: effects))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(name)
        .accessibilityHint(strings.text(.switchWallet))
        .accessibilityIdentifier("home.walletSwitcher")
    }
}

/// A fixed viewport canvas. The opaque scrolling body reveals its lower edge;
/// neither scroll geometry nor refresh inset animations resize this renderer.
struct OathHomeHeaderSurface: View {
    let effects: OathHomeScrollEffects
    let animates: Bool
    var colorHex: String? = nil

    var body: some View {
        GeometryReader { geometry in
            OathBackground(placement: .walletBackdrop(size: geometry.size),
                           animates: animates, customColor: colorHex.flatMap { UInt32($0, radix: 16) })
            .modifier(OathHomePullBlur(effects: effects))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The renderer stays fixed; only its native blur filter follows downward
/// overscroll. UIKit's own bounce/refresh return drives this back to zero.
private struct OathHomePullBlur: ViewModifier {
    let effects: OathHomeScrollEffects
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        content.blur(radius: reduceTransparency ? 0 : 24 * effects.pullProgress, opaque: true)
    }
}

/// Native navigation owns placement, RTL, the safe area and the shared glass.
/// Settings and the wallet selector form one leading control with two actions.
struct OathHomeToolbar: ToolbarContent {
    let effects: OathHomeScrollEffects
    let walletName: String
    let walletColorHex: String?
    let canSwitchWallet: Bool
    let onSwitchWallet: () -> Void
    let onScan: () -> Void
    let onSettings: () -> Void
    let onWalletSettings: () -> Void
    @Environment(\.oathLocalizer) private var strings

    var body: some ToolbarContent {
        if #available(iOS 26, *) {
            walletControls.sharedBackgroundVisibility(.visible)
            scannerItem.sharedBackgroundVisibility(.visible)
        } else {
            walletControls
            scannerItem
        }
    }

    private var walletControls: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            HStack(spacing: 0) {
                OathHomeSettingsToolbarItem(effects: effects, walletColorHex: walletColorHex,
                    onSettings: onSettings, onWalletSettings: onWalletSettings)
                // A native Divider inside a horizontal group is a vertical
                // hairline, without creating another toolbar background.
                Divider()
                    .frame(height: 22)
                    .accessibilityHidden(true)
                OathHomeWalletSelector(name: walletName, effects: effects, action: onSwitchWallet)
                    .disabled(!canSwitchWallet)
            }
            .fixedSize(horizontal: true, vertical: false)
            .modifier(OathHomeLegacyToolbarBackground(shape: Capsule()))
        }
    }

    private var scannerItem: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            // Match every other scanner entry: the native bar chooses the
            // symbol's font, scale and control size for the current OS/traits.
            OathButton(strings.text(.scan), systemImage: "viewfinder", feedback: .scan, action: onScan)
            .labelStyle(.iconOnly)
            .modifier(OathHomeLegacyToolbarBackground(shape: Circle()))
            .modifier(OathHomeToolbarForeground(effects: effects))
            .accessibilityLabel(strings.text(.scan))
            .accessibilityIdentifier("home.scanner")
        }
    }

}

/// Isolate per-frame contrast changes from Home's asset filtering, database
/// snapshot, and the navigation bar's item identity/layout.
private struct OathHomeToolbarForeground: ViewModifier {
    let effects: OathHomeScrollEffects
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let color = Color(white: colorScheme == .dark ? 1 : 1 - effects.toolbarForegroundProgress)
        content.foregroundStyle(color).tint(color)
    }
}

private struct OathHomeSettingsToolbarItem: View {
    let effects: OathHomeScrollEffects
    let walletColorHex: String?
    let onSettings: () -> Void
    let onWalletSettings: () -> Void
    @Environment(\.oathLocalizer) private var strings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let showsWallet = effects.showsWalletSettings
        let replacement: AnyTransition = reduceMotion ? .opacity : AnyTransition(.blurReplace)
        let animation: Animation = reduceMotion ? .easeOut(duration: 0.12) : .smooth(duration: 0.28)
        // Keep a single native toolbar button. Only its symbol transitions,
        // while the action and accessibility label follow the current state.
        return OathButton(action: showsWallet ? onWalletSettings : onSettings) {
            ZStack {
                if showsWallet {
                    OathWalletSymbol(colorHex: walletColorHex)
                        .transition(replacement)
                } else {
                    Image(systemName: "slider.horizontal.3")
                        .modifier(OathHomeToolbarForeground(effects: effects))
                        .transition(replacement)
                }
            }
            // This group needs its own hit region, but its symbols retain the
            // toolbar's inherited metrics instead of resizing to that region.
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(strings.text(showsWallet ? .walletDetails : .walletSettings))
        .accessibilityIdentifier(showsWallet ? "home.walletSettings" : "home.settings")
        .animation(animation, value: showsWallet)
    }
}

/// Older systems do not provide a glass toolbar background. Keep the same
/// grouping there without drawing another layer over iOS 26's native glass.
private struct OathHomeLegacyToolbarBackground<S: Shape>: ViewModifier {
    let shape: S

    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content
        } else {
            content.background(.ultraThinMaterial, in: shape)
        }
    }
}
