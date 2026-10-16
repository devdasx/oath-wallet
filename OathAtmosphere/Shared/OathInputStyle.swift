import SwiftUI

/// Shared geometry for app-owned text-entry surfaces. Native search chrome
/// keeps its system shape; form fields use the same compact, accessible row.
enum OathInputMetrics {
    static let cornerRadius: CGFloat = 26
    static let horizontalInset: CGFloat = 16
    static let verticalInset: CGFloat = 6
    static let minimumContentHeight: CGFloat = 44
    static let actionInset: CGFloat = 6
    static let actionCornerRadius = cornerRadius - actionInset
}

private struct OathInputGroupKey: EnvironmentKey {
    static let defaultValue = false
}

private extension EnvironmentValues {
    var oathInputIsGrouped: Bool {
        get { self[OathInputGroupKey.self] }
        set { self[OathInputGroupKey.self] = newValue }
    }
}

/// One connected form surface around native fields. Each field keeps its own
/// placeholder, accessibility label, focus, and secure-entry behavior.
struct OathInputGroup<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0, content: content)
            .environment(\.oathInputIsGrouped, true)
            .oathFont(.body)
            .background(Color(uiColor: OathSurfaceColors.field),
                        in: .rect(cornerRadius: OathInputMetrics.cornerRadius))
            .accessibilityElement(children: .contain)
    }
}

struct OathInputSeparator: View {
    var body: some View {
        OathHairline().padding(.horizontal, OathInputMetrics.horizontalInset)
    }
}

private struct OathInputBackground: ViewModifier {
    @Environment(\.oathInputIsGrouped) private var isGrouped

    func body(content: Content) -> some View {
        content.background(isGrouped ? Color.clear : Color(uiColor: OathSurfaceColors.field),
                           in: .rect(cornerRadius: OathInputMetrics.cornerRadius))
    }
}

/// Paste belongs to the input surface, with concentric corners and an inset
/// hit target. Multiline and accessibility layouts keep it below the text so
/// it never covers the caret, selection, or private-key visibility control.
struct OathPasteInput<Content: View>: View {
    let hasText: Bool
    let identifier: String
    let clearIdentifier: String
    var multiline = false
    var scanIdentifier = "input.scan"
    var onScan: (() -> Void)? = nil
    let onPaste: () -> Void
    let onClear: () -> Void
    @ViewBuilder let content: () -> Content
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.oathLocalizer) private var strings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Joined address actions follow the interface direction. Existing key and
    // phrase inputs retain their explicitly requested physical right placement.
    private var actionDirection: LayoutDirection { onScan == nil ? .leftToRight : layoutDirection }

    var body: some View {
        Group {
            if multiline || dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 0) {
                    if multiline {
                        content()
                    } else {
                        content().oathInputRow()
                    }
                    HStack {
                        Spacer(minLength: 0)
                        actions.environment(\.layoutDirection, layoutDirection)
                    }
                    .padding(OathInputMetrics.actionInset)
                    .environment(\.layoutDirection, actionDirection)
                }
            } else {
                HStack(spacing: 10) {
                    content().frame(maxWidth: .infinity)
                        .environment(\.layoutDirection, layoutDirection)
                    actions.environment(\.layoutDirection, layoutDirection)
                }
                .padding(.leading, OathInputMetrics.horizontalInset)
                .padding(.trailing, OathInputMetrics.actionInset)
                .padding(.vertical, OathInputMetrics.actionInset)
                .environment(\.layoutDirection, actionDirection)
            }
        }
        .oathInputBackground()
    }

    private var actions: some View {
        let replacement: AnyTransition = reduceMotion ? .opacity : AnyTransition(.blurReplace)
        return ZStack(alignment: .trailing) {
            if hasText {
                actionButton(.clear, identifier: clearIdentifier, feedback: .clear, action: onClear)
                    .clipShape(.rect(cornerRadius: OathInputMetrics.actionCornerRadius))
                    .transition(replacement)
            } else {
                // Clip the pair once: only the two outer ends are rounded. The
                // shared inner edges stay square in both LTR and RTL layouts.
                HStack(spacing: 2) {
                    if let onScan {
                        actionButton(.scan, identifier: scanIdentifier, feedback: .scan, action: onScan)
                    }
                    actionButton(.paste, identifier: identifier, feedback: nil, action: onPaste)
                }
                .clipShape(.rect(cornerRadius: OathInputMetrics.actionCornerRadius))
                .transition(replacement)
            }
        }
        .animation(reduceMotion ? .easeOut(duration: 0.12) : .smooth(duration: 0.25), value: hasText)
    }

    private func actionButton(_ title: OathStringKey, identifier: String,
                              feedback: OathHapticEvent?, action: @escaping () -> Void) -> some View {
        OathButton(feedback: feedback, action: action) {
            Text(strings.text(title))
                .oathFont(.subheadline, weight: .semibold)
                .foregroundStyle(Color(uiColor: onScan == nil ? .label : .secondaryLabel))
                .fixedSize(horizontal: true, vertical: true)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .frame(minHeight: OathInputMetrics.minimumContentHeight)
                .background(Color.primary.opacity(0.07))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }
}

extension View {
    func oathInputRow() -> some View {
        oathFont(.body)
            .padding(.horizontal, OathInputMetrics.horizontalInset)
            .padding(.vertical, OathInputMetrics.verticalInset)
    }

    func oathInputBackground() -> some View {
        modifier(OathInputBackground())
    }
}
