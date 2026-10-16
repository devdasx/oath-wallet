import SwiftUI

enum OathActionAppearance { case primary, secondary, text }

/// Neutral dismissal, independent of the presenting screen's accent color.
/// The native toolbar owns the glass treatment and the hit target.
struct OathCloseButton: View {
    @Environment(\.oathLocalizer) private var strings
    let action: @MainActor () -> Void

    var body: some View {
        OathButton(feedback: .dismiss, action: action) {
            Label(strings.text(.close), systemImage: "xmark")
        }
        .labelStyle(.iconOnly)
        .oathNeutralControl()
        .accessibilityLabel(strings.text(.close))
    }
}

/// Let the system supply the confirmation symbol, prominence and hit target.
/// Keep the localized action name for VoiceOver even when only the icon is visible.
struct OathDoneButton: View {
    @Environment(\.oathLocalizer) private var strings
    var label: OathStringKey = .done
    let action: @MainActor () -> Void

    var body: some View {
        Group {
            if #available(iOS 26.0, *) {
                OathButton(role: .confirm, action: action)
            } else {
                OathButton(action: action) {
                    Label(strings.text(label), systemImage: "checkmark")
                }
            }
        }
        .labelStyle(.iconOnly)
        .oathConfirmationControl()
        .accessibilityLabel(strings.text(label))
    }
}

/// Native welcome-screen metrics: extra-large capsule, shared typography and
/// system content insets. Do not add vertical padding or a fixed label height.
struct OathActionButton: View {
    let title: String
    var icon: String? = nil
    var appearance: OathActionAppearance = .primary
    var role: ButtonRole? = nil
    var accent: Color? = nil
    var foreground: Color? = nil
    var isWorking = false
    var isInteractionBlocked = false
    let action: () -> Void
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        OathButton(role: role, feedback: nil) {
            guard scenePhase == .active, !isInteractionBlocked else { return }
            OathHaptics.shared.perform(role == .destructive ? .warning : .tap, action: action)
        } label: {
            OathActionLabel(title: title, icon: icon, isWorking: isWorking,
                            progressColor: foreground ?? (appearance == .primary ? .white : .primary))
        }
        .oathActionStyle(appearance, accent: accent, foreground: foreground)
        .oathInteractionBlocked(isInteractionBlocked)
    }
}

/// Face ID can report success while its dismissal still keeps the scene
/// inactive. Suspend input without changing the native control's enabled color.
/// Validation, missing data and committed work still use ordinary .disabled.
private struct OathInteractionBlock: ViewModifier {
    let blocked: Bool
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        let allowsInteraction = !blocked && scenePhase == .active
        content
            .allowsHitTesting(allowsInteraction)
            .accessibilityRespondsToUserInteraction(allowsInteraction)
    }
}

/// Shared text, icon and progress content without extra per-screen padding.
struct OathActionLabel: View {
    let title: String
    var icon: String? = nil
    var isWorking = false
    var progressColor: Color = .white

    var body: some View {
        HStack(spacing: OathActionMetrics.labelSpacing) {
            if isWorking { ProgressView().controlSize(.small).tint(progressColor) }
            else if let icon { Image(systemName: icon).accessibilityHidden(true) }
            Text(title)
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity)
    }
}

private struct OathActionStyle: ViewModifier {
    let appearance: OathActionAppearance
    let accent: Color?
    let foreground: Color?

    func body(content: Content) -> some View {
        nativeButton(content)
            .controlSize(.extraLarge)
            .buttonBorderShape(.capsule)
            .oathFont(.body, weight: .semibold)
    }

    @ViewBuilder private func nativeButton(_ content: Content) -> some View {
        switch appearance {
        case .primary:
            if #available(iOS 26, *) {
                content.buttonStyle(.glassProminent).buttonSizing(.flexible)
                    .tint(accent ?? OathOnboardingColors.blue)
                    .foregroundStyle(foreground ?? .white)
            } else {
                content.buttonStyle(.borderedProminent)
                    .tint(accent ?? OathOnboardingColors.blue)
                    .foregroundStyle(foreground ?? .white)
            }
        case .secondary:
            if #available(iOS 26, *) {
                // The default glass button uses the frosted regular material,
                // which washes out the animated wallet colors. Secondary
                // actions share one untinted native clear-glass surface.
                content.buttonStyle(.glass(.clear)).buttonSizing(.flexible)
                    .foregroundStyle(foreground ?? .primary)
            } else {
                content.buttonStyle(.bordered).tint(accent ?? .primary)
                    .foregroundStyle(foreground ?? .primary)
            }
        case .text:
            // Preserve the welcome screen's quiet More Options treatment while
            // retaining native control insets and the same extra-large height.
            content.buttonStyle(.bordered).tint(.clear)
                .foregroundStyle(foreground ?? .secondary)
        }
    }
}

extension View {
    /// For transient authentication/input suspension, not form validation.
    /// Raw Button/Toggle actions must also guard against queued activation.
    func oathInteractionBlocked(_ blocked: Bool = false) -> some View {
        modifier(OathInteractionBlock(blocked: blocked))
    }

    /// Confirmations stay blue even in sheets with neutral navigation controls.
    func oathConfirmationControl() -> some View {
        tint(OathOnboardingColors.blue)
    }

    /// Explicit label color avoids inheriting a wallet or navigation-link tint.
    /// Use only for neutral controls; confirmation buttons own their blue tint.
    func oathNeutralControl() -> some View {
        foregroundStyle(Color(uiColor: .label))
            .tint(Color(uiColor: .label))
    }

    func oathActionStyle(_ appearance: OathActionAppearance = .primary,
                         accent: Color? = nil, foreground: Color? = nil) -> some View {
        modifier(OathActionStyle(appearance: appearance, accent: accent, foreground: foreground))
    }

    /// existingInset accounts for a form's padding instead of adding it twice.
    func oathActionArea(existingInset: CGFloat = 0) -> some View {
        OathActionAreaLayout(existingInset: existingInset) { self }
    }

    /// Fixed screen actions belong to the system's bottom safe-area bar, so
    /// scrolling content receives the native edge treatment behind the controls.
    /// Keep form/inline actions in oathActionArea instead.
    func oathBottomActions<Actions: View>(isPresented: Bool = true,
                                          maximumWidth: CGFloat = OathActionMetrics.maximumWidth,
                                          @ViewBuilder content: () -> Actions) -> some View {
        modifier(OathBottomActions(isPresented: isPresented, maximumWidth: maximumWidth, actions: content()))
    }
}

private struct OathBottomActions<Actions: View>: ViewModifier {
    let isPresented: Bool
    let maximumWidth: CGFloat
    let actions: Actions

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .safeAreaBar(edge: .bottom) { bar }
                .scrollEdgeEffectStyle(.soft, for: .bottom)
        } else {
            content.safeAreaInset(edge: .bottom) {
                bar.background(.bar)
            }
        }
    }

    @ViewBuilder private var bar: some View {
        // Apply system padding only to a real bar. Empty states and working
        // screens must not reserve an invisible footer's height.
        if isPresented {
            actions
                .frame(maxWidth: maximumWidth)
                .padding()
                .frame(maxWidth: .infinity)
        }
    }
}

/// Sizes before placement, without geometry-to-state writes or a first-frame
/// resize. The system still measures the native button at every Dynamic Type size.
private struct OathActionAreaLayout: Layout {
    var existingInset: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width.flatMap { $0.isFinite ? max(0, $0) : nil }
            ?? OathActionMetrics.maximumWidth + 64
        let innerWidth = OathActionMetrics.contentWidth(in: width, existingInset: existingInset)
        let height = subviews.first?.sizeThatFits(.init(width: innerWidth, height: nil)).height ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let width = OathActionMetrics.contentWidth(in: bounds.width, existingInset: existingInset)
        subviews.first?.place(at: CGPoint(x: bounds.midX, y: bounds.minY), anchor: .top,
                             proposal: .init(width: width, height: bounds.height))
    }
}
