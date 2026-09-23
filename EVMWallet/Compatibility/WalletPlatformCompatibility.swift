import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit

/// Uses Apple's rounded QR artwork without changing support for earlier iOS
/// versions. Rendering and caching belong to ReceiveQRCodeRenderer's actor.
enum WalletPlatformQRCodeGenerator {
    static func roundedImage(message: Data, moduleScale: Int) -> CIImage? {
        if #available(iOS 26.0, *) {
            let filter = CIFilter.roundedQRCodeGenerator()
            filter.message = message
            // Preserve the existing byte capacity and compact M-level symbols.
            // The shared brand overlay owns the center; the generator must not
            // carve out its own larger center tile (Q/H reserve center space).
            filter.correctionLevel = "M"
            filter.scale = Float(moduleScale)
            filter.roundedMarkers = 2
            filter.roundedData = true
            filter.centerSpaceSize = 0
            filter.color0 = .white
            filter.color1 = .black
            return filter.outputImage
        }
        return nil
    }
}

/// UIKit equivalent of the app's SwiftUI glass confirmation control, used in
/// the native keyboard accessory so its bottom gap participates in sizing.
enum WalletNativeKeyboardButtonStyle {
    static func configuration(isConfirmation: Bool = true) -> UIButton.Configuration {
        var configuration: UIButton.Configuration
        if #available(iOS 26.0, *) {
            configuration = isConfirmation ? .prominentGlass() : .glass()
        } else {
            configuration = isConfirmation ? .filled() : .bordered()
        }
        configuration.image = isConfirmation ? UIImage(systemName: "checkmark") : nil
        configuration.title = isConfirmation ? nil : "."
        configuration.preferredSymbolConfigurationForImage = .init(pointSize: 22, weight: .semibold)
        if isConfirmation { configuration.baseBackgroundColor = UIColor(WalletTheme.primaryAction) }
        configuration.baseForegroundColor = UIColor(isConfirmation ? WalletTheme.onAccentLabel : WalletTheme.primaryLabel)
        configuration.cornerStyle = .capsule
        configuration.contentInsets = .zero
        return configuration
    }
}

/// Keeps the app's native iOS 26 confirmation affordance while providing the
/// same checkmark action on earlier supported systems.
struct WalletConfirmationButton: View {
    private let action: () -> Void
    private let accessibilityLabel: LocalizedStringKey

    init(_ accessibilityLabel: LocalizedStringKey = "common.done", action: @escaping () -> Void) {
        self.accessibilityLabel = accessibilityLabel
        self.action = action
    }

    @ViewBuilder
    var body: some View {
        if #available(iOS 26.0, *) {
            Button(role: .confirm, action: UniHaptic.action(.commit, perform: action))
                .accessibilityLabel(Text(accessibilityLabel))
        } else {
            Button(action: UniHaptic.action(.commit, perform: action)) {
                Image(systemName: "checkmark")
            }
            .accessibilityLabel(Text(accessibilityLabel))
        }
    }
}

/// Keeps the native role-based close affordance on iOS 26 while rendering the
/// same localized xmark action on earlier supported systems.
struct WalletCloseButton: View {
    private let action: () -> Void

    init(action: @escaping () -> Void) {
        self.action = action
    }

    @ViewBuilder
    var body: some View {
        if #available(iOS 26.0, *) {
            Button(role: .close, action: action)
        } else {
            Button(action: action) {
                Image(systemName: "xmark")
            }
            .accessibilityLabel(Text("common.close"))
        }
    }
}

/// Preserves the system's container-concentric corners on iOS 26 and uses a
/// continuous rounded rectangle with the same minimum radius on iOS 18–25.
struct WalletConcentricRectangle: Shape {
    let minimumCornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        if #available(iOS 26.0, *) {
            return ConcentricRectangle(
                corners: .concentric(
                    minimum: .fixed(minimumCornerRadius)
                ),
                isUniform: true
            )
            .path(in: rect)
        }

        return RoundedRectangle(
            cornerRadius: minimumCornerRadius,
            style: .continuous
        )
        .path(in: rect)
    }
}

enum WalletToolbarSpacerSizing {
    case fixed
    case flexible
}

/// Uses native toolbar spacing on iOS 26 and a layout-equivalent toolbar item
/// on earlier systems where `ToolbarSpacer` is unavailable.
struct WalletToolbarSpacer: ToolbarContent {
    let sizing: WalletToolbarSpacerSizing
    let placement: ToolbarItemPlacement

    init(
        _ sizing: WalletToolbarSpacerSizing,
        placement: ToolbarItemPlacement
    ) {
        self.sizing = sizing
        self.placement = placement
    }

    @ToolbarContentBuilder
    var body: some ToolbarContent {
        if #available(iOS 26.0, *) {
            switch sizing {
            case .fixed:
                ToolbarSpacer(.fixed, placement: placement)
            case .flexible:
                ToolbarSpacer(.flexible, placement: placement)
            }
        } else {
            ToolbarItem(placement: placement) {
                switch sizing {
                case .fixed:
                    Color.clear
                        .frame(width: 1, height: 1)
                        .accessibilityHidden(true)
                case .flexible:
                    Spacer()
                }
            }
        }
    }
}

struct WalletGlassEffectContainer<Content: View>: View {
    let spacing: CGFloat
    private let content: Content

    init(
        spacing: CGFloat,
        @ViewBuilder content: () -> Content
    ) {
        self.spacing = spacing
        self.content = content()
    }

    @ViewBuilder
    var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) {
                content
            }
        } else {
            content
        }
    }
}

enum WalletAdaptiveGlassButtonStyle {
    case regular
    case accent
}

extension View {
    @ViewBuilder
    func walletPrimaryActionButtonStyle() -> some View {
        if #available(iOS 26.0, *) {
            buttonStyle(.glassProminent)
                .tint(WalletTheme.primaryAction)
        } else {
            buttonStyle(.borderedProminent)
                .tint(WalletTheme.primaryAction)
        }
    }

    @ViewBuilder
    func walletSecondaryActionButtonStyle() -> some View {
        if #available(iOS 26.0, *) {
            buttonStyle(.glass)
        } else {
            buttonStyle(.bordered)
                .tint(WalletTheme.primaryLabel)
        }
    }

    @ViewBuilder
    func walletFlexibleButtonSizing() -> some View {
        if #available(iOS 26.0, *) {
            buttonSizing(.flexible)
        } else {
            self
        }
    }

    @ViewBuilder
    func walletDrawOnTransition(
        options: SymbolEffectOptions = .nonRepeating
    ) -> some View {
        if #available(iOS 26.0, *) {
            transition(
                .symbolEffect(.drawOn.wholeSymbol, options: options)
            )
        } else {
            transition(.opacity)
        }
    }

    @ViewBuilder
    func walletZeroHorizontalListSectionMargins() -> some View {
        if #available(iOS 26.0, *) {
            listSectionMargins(.horizontal, 0)
        } else {
            self
        }
    }

    @ViewBuilder
    func walletSafeAreaBar<Content: View>(
        edge: VerticalEdge,
        spacing: CGFloat? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        if #available(iOS 26.0, *) {
            safeAreaBar(edge: edge, spacing: spacing, content: content)
        } else {
            safeAreaInset(edge: edge, spacing: spacing, content: content)
        }
    }

    @ViewBuilder
    func walletAutomaticSearchToolbarBehavior() -> some View {
        if #available(iOS 26.0, *) {
            searchToolbarBehavior(.automatic)
        } else {
            self
        }
    }

    @ViewBuilder
    func walletRegularGlassEffect<S: Shape>(
        tint: Color? = nil,
        interactive: Bool = false,
        in shape: S
    ) -> some View {
        if #available(iOS 26.0, *) {
            if interactive, let tint {
                glassEffect(
                    .regular.tint(tint).interactive(),
                    in: shape
                )
            } else if interactive {
                glassEffect(.regular.interactive(), in: shape)
            } else if let tint {
                glassEffect(.regular.tint(tint), in: shape)
            } else {
                glassEffect(.regular, in: shape)
            }
        } else {
            background(tint ?? WalletTheme.groupedSurface, in: shape)
        }
    }

    @ViewBuilder
    func walletClearGlassEffect<S: Shape>(
        tint: Color? = nil,
        interactive: Bool = false,
        in shape: S
    ) -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(
                .clear.tint(tint).interactive(interactive),
                in: shape
            )
        } else {
            background(tint ?? WalletTheme.groupedSurface, in: shape)
        }
    }

    @ViewBuilder
    func walletAdaptiveGlassButtonStyle(
        _ style: WalletAdaptiveGlassButtonStyle
    ) -> some View {
        switch style {
        case .accent:
            walletPrimaryActionButtonStyle()
        case .regular:
            if #available(iOS 26.0, *) {
                buttonStyle(.glass(.regular.interactive()))
            } else {
                buttonStyle(.bordered)
            }
        }
    }

    @ViewBuilder
    func walletAdaptiveGlassButtonStyle(tint: Color?) -> some View {
        if #available(iOS 26.0, *) {
            if let tint {
                buttonStyle(
                    .glass(
                        .regular
                            .tint(tint)
                            .interactive()
                    )
                )
            } else {
                buttonStyle(.glass(.regular.interactive()))
            }
        } else if let tint {
            buttonStyle(.borderedProminent)
                .tint(tint)
        } else {
            buttonStyle(.bordered)
        }
    }
}
