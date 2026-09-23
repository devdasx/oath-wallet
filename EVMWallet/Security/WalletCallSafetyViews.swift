import SwiftUI

extension EnvironmentValues {
    @Entry var walletCallSafety: WalletCallSafetyState? = nil
}

enum WalletCallSafetyContext {
    case sending, secret

    var messageKey: LocalizedStringKey {
        switch self {
        case .sending: "call_safety.send"
        case .secret: "call_safety.secret"
        }
    }
}

extension View {
    func walletCallSafetyBanner() -> some View {
        modifier(WalletCallSafetyBannerModifier())
    }

    func walletCallSafetyWarning(_ context: WalletCallSafetyContext) -> some View {
        safeAreaInset(edge: .top, spacing: 0) {
            WalletCallSafetyWarning(context: context)
        }
    }
}

private struct WalletCallSafetyBannerModifier: ViewModifier {
    @Environment(\.walletCallSafety) private var safety
    @State private var isExplanationPresented = false

    func body(content: Content) -> some View {
        // Give the banner its own layout space above the navigation container.
        // An outer safe-area inset can overlap the container's native toolbar.
        // Keep content in the same structural position when call state changes.
        VStack(spacing: 0) {
            if safety?.shouldShowWarning == true {
                Button(action: UniHaptic.action {
                    isExplanationPresented = true
                }) {
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.shield.fill")
                            .accessibilityHidden(true)
                        Text("call_safety.title")
                            .fixedSize(horizontal: false, vertical: true)
                        Image(systemName: "chevron.forward")
                            .accessibilityHidden(true)
                    }
                    .font(.headline)
                    .foregroundStyle(WalletTheme.onDangerLabel)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .padding(.horizontal)
                    .padding(.vertical, 6)
                    .background(WalletTheme.callSafetyBanner)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("callSafety.banner")
                .layoutPriority(1)
                .zIndex(1)
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .sheet(isPresented: $isExplanationPresented) {
            WalletCallSafetyExplanationSheet()
        }
    }
}

struct WalletCallSafetyWarning: View {
    let context: WalletCallSafetyContext
    @Environment(\.walletCallSafety) private var safety

    var body: some View {
        if safety?.shouldShowWarning == true {
            Label {
                Text(context.messageKey)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.shield")
            }
            .font(.subheadline)
            .foregroundStyle(.primary)
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("callSafety.contextWarning")
        }
    }
}

private struct WalletCallSafetyExplanationSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.walletCallSafety) private var safety

    var body: some View {
        NavigationStack {
            List {
                Group {
                    Section {
                        Text("call_safety.title")
                            .font(.title2.bold())
                            .accessibilityAddTraits(.isHeader)
                        Label("call_safety.no_calls", systemImage: "phone.down.fill")
                        Label("call_safety.send", systemImage: "arrow.up.right")
                        Label("call_safety.secret", systemImage: "key.fill")
                        Label("call_safety.screen", systemImage: "rectangle.slash")
                    }
                    if safety?.shouldShowWarning == true {
                        Section {
                            Button("call_safety.hide_call") {
                                safety?.hideForCurrentCalls()
                                dismiss()
                            }
                            .accessibilityIdentifier("callSafety.hideCurrentCall")
                        } footer: {
                            Text("call_safety.hide_call.footer")
                        }
                    }
                }
                .walletListRowSurface()
            }
            .walletListAppearance()
            .listStyle(.insetGrouped)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    WalletCloseButton { dismiss() }
                }
            }
        }
        .walletLocalePresentation()
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }
}
