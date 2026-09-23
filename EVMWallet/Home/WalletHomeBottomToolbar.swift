import SwiftUI
import UIKit

enum WalletHomeCompactAction {
    case send
    case receive

    var titleKey: LocalizedStringKey {
        switch self {
        case .send: "wallet.home.action.send"
        case .receive: "wallet.home.action.receive"
        }
    }
}

struct WalletHomeBottomToolbarHost: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let containerWidth: CGFloat
    let showsCompactActions: Bool
    @Binding var text: String
    @Binding var isPresented: Bool
    let requestsSearchFocus: Bool
    let onSend: () -> Void
    let onReceive: () -> Void

    @State private var displaysCompactActions: Bool
    @FocusState private var isSearchFieldFocused: Bool

    init(
        containerWidth: CGFloat,
        showsCompactActions: Bool,
        text: Binding<String>,
        isPresented: Binding<Bool>,
        requestsSearchFocus: Bool,
        onSend: @escaping () -> Void,
        onReceive: @escaping () -> Void
    ) {
        self.containerWidth = containerWidth
        self.showsCompactActions = showsCompactActions
        _text = text
        _isPresented = isPresented
        self.requestsSearchFocus = requestsSearchFocus
        self.onSend = onSend
        self.onReceive = onReceive
        _displaysCompactActions = State(initialValue: showsCompactActions)
    }

    @ViewBuilder
    var body: some View {
        Color.clear
            .allowsHitTesting(false)
            .modifier(
                WalletHomeSearchModifier(
                    text: $text,
                    isPresented: $isPresented,
                    isFocused: $isSearchFieldFocused
                )
            )
            .toolbar {
                if displaysCompactActions {
                    ToolbarItem(
                        id: "wallet-home-compact-send",
                        placement: .bottomBar
                    ) {
                        compactActionButton(
                            .send,
                            action: onSend
                        )
                    }

                    WalletToolbarSpacer(.fixed, placement: .bottomBar)

                    ToolbarItem(
                        id: "wallet-home-compact-receive",
                        placement: .bottomBar
                    ) {
                        compactActionButton(
                            .receive,
                            action: onReceive
                        )
                    }
                } else if #available(iOS 26.0, *) {
                    DefaultToolbarItem(
                        kind: .search,
                        placement: searchToolbarPlacement
                    )
                }
            }
            .onChange(of: showsCompactActions) { _, newValue in
                transitionCompactActions(to: newValue)
            }
            .task(id: requestsSearchFocus && !displaysCompactActions) {
                guard requestsSearchFocus, !displaysCompactActions else {
                    isSearchFieldFocused = false
                    return
                }
                // Wait for the native search toolbar item to enter the
                // hierarchy, present its search interface, and explicitly
                // focus the native field on the following render pass.
                await Task.yield()
                guard !Task.isCancelled,
                      requestsSearchFocus,
                      !displaysCompactActions
                else { return }
                if !isPresented {
                    isPresented = true
                    await Task.yield()
                }
                guard !Task.isCancelled,
                      requestsSearchFocus,
                      !displaysCompactActions,
                      isPresented
                else { return }
                isSearchFieldFocused = true
            }
    }

    @ViewBuilder
    private func compactActionButton(
        _ compactAction: WalletHomeCompactAction,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: UniHaptic.action(nil, perform: action)) {
            Text(compactAction.titleKey)
                .font(.headline)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(
                    width: WalletHomeBottomToolbarSizing.actionLabelWidth(
                        containerWidth: containerWidth
                    )
                )
        }
        .walletTransferAction()
    }

    @MainActor
    private func transitionCompactActions(to isDisplayed: Bool) {
        guard displaysCompactActions != isDisplayed else { return }
        guard !reduceMotion else {
            displaysCompactActions = isDisplayed
            return
        }

        withAnimation(.smooth(duration: 0.24)) {
            displaysCompactActions = isDisplayed
        }
    }

    private var searchToolbarPlacement: ToolbarItemPlacement {
        UIDevice.current.userInterfaceIdiom == .pad
            ? .topBarTrailing
            : .bottomBar
    }
}

private enum WalletHomeBottomToolbarSizing {
    private static let combinedOuterInsets: CGFloat = 48
    private static let settingsSurfaceWidth: CGFloat = 48
    private static let combinedGroupGapWidths: CGFloat = 24
    private static let textButtonHorizontalChrome: CGFloat = 32
    private static let separateActionEdgeAllowance: CGFloat = 10
    private static let minimumLabelWidth: CGFloat = 44

    static func actionLabelWidth(
        containerWidth: CGFloat
    ) -> CGFloat {
        let availableSurfaceWidth = max(
            0,
            containerWidth
                - combinedOuterInsets
                - settingsSurfaceWidth
                - combinedGroupGapWidths
                - separateActionEdgeAllowance
        )
        let equalSurfaceWidth = availableSurfaceWidth / 2
        return max(
            minimumLabelWidth,
            equalSurfaceWidth - textButtonHorizontalChrome
        )
    }
}

private struct WalletHomeSearchModifier: ViewModifier {
    @Binding var text: String
    @Binding var isPresented: Bool
    let isFocused: FocusState<Bool>.Binding

    func body(content: Content) -> some View {
        content
            .searchable(
                text: $text,
                isPresented: $isPresented,
                placement: .toolbar,
                prompt: Text("wallet.home.search.short_prompt")
            )
            .searchFocused(isFocused)
            .walletTextInputDirection()
            .walletAutomaticSearchToolbarBehavior()
    }
}
