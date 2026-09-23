import SwiftUI

struct SendActivityExpandedCapsule: View {
    let operations: [SendOperation]
    let maximumHeight: CGFloat
    let onOpen: (SendOperation) -> Void
    let onCollapse: () -> Void
    let onDismissAll: () -> Void
    let onDismissConfirmed: @MainActor (SendOperation) -> Void
    // Initial viewport estimate only; native List geometry supplies the actual content height.
    @ScaledMetric(relativeTo: .body) private var viewportAllowance = 104.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var contentHeight: CGFloat?
    @State private var viewportHeight: CGFloat = 0
    @State private var headerHeight: CGFloat = 52
    @State private var isDismissing = false
    @State private var nativeDrag = CGSize.zero
    @GestureState private var drag = CGSize.zero

    private let shape = RoundedRectangle(cornerRadius: 34, style: .continuous)

    private var contentFits: Bool {
        guard let contentHeight, viewportHeight > 0 else { return false }
        return contentHeight <= viewportHeight + 1
    }

    private var listHeight: CGFloat {
        min(max(44, maximumHeight - headerHeight),
            max(44, contentHeight ?? CGFloat(min(operations.count, 3)) * viewportAllowance))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("wallet.activity.all.title")
                    .font(.headline)
                    .foregroundStyle(WalletTheme.primaryLabel)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("sendActivityTitle")
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                SendActivityCountBadge(count: operations.count, isExpanded: true, onToggle: onCollapse)
                WalletCloseButton(action: UniHaptic.action(nil, perform: dismiss))
                    .tint(WalletTheme.secondaryLabel)
                    .frame(minWidth: 44, minHeight: 44)
                    .accessibilityIdentifier("sendActivityDismiss")
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerHeight = $0 }
            .highPriorityGesture(dismissGesture)

            List {
                Group {
                    Section {
                        ForEach(operations) { operation in
                            SendActivityListItem(operation: operation, onOpen: { onOpen(operation) },
                                                 onDismissConfirmed: { onDismissConfirmed(operation) })
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden, edges: .top)
                                .listRowSeparator(operation.id == operations.last?.id ? .hidden : .visible, edges: .bottom)
                        }
                    }
                }
                .walletListRowSurface()
            }
            .walletListAppearance()
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color.clear)
            .contentMargins(.vertical, 0, for: .scrollContent)
            .scrollBounceBehavior(.basedOnSize)
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                (geometry.contentSize.height + geometry.contentInsets.top + geometry.contentInsets.bottom).rounded(.up)
            } action: { _, height in
                if height > 0 { contentHeight = height }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { viewportHeight = $0 }
            .frame(height: listHeight)
            .scrollDisabled(contentFits)
            .accessibilityIdentifier("sendActivityList")
        }
        .gesture(SendActivitySwipeGesture(isEnabled: contentFits && !isDismissing,
                                         onTranslation: { nativeDrag = $0 }, onDismiss: dismiss))
        .onChange(of: contentFits) { _, fits in
            if !fits { nativeDrag = .zero }
        }
        .walletRegularGlassEffect(interactive: false, in: shape)
        .clipShape(shape)
        .offset(y: reduceMotion ? 0 : min(drag.height, nativeDrag.height))
        .animation(reduceMotion || drag != .zero ? nil : .snappy(duration: 0.22), value: drag)
        .accessibilityAction(.escape, dismiss)
        .accessibilityAction(named: Text("common.close"), dismiss)
        .onKeyPress(.escape) { dismiss(); return .handled }
        .disabled(isDismissing)
    }

    private var dismissGesture: some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .global)
            .updating($drag) { value, state, _ in
                guard !isDismissing, value.translation.height < 0,
                      abs(value.translation.height) > abs(value.translation.width) else { return }
                state = CGSize(width: 0, height: value.translation.height)
            }
            .onEnded { value in
                if SendStatusCapsule.shouldDismiss(translation: value.translation) { dismiss() }
            }
    }

    private func dismiss() {
        guard !isDismissing else { return }
        isDismissing = true
        onDismissAll()
    }
}

private struct SendActivityListItem: View {
    let operation: SendOperation
    let onOpen: () -> Void
    let onDismissConfirmed: @MainActor () -> Void
    @State private var isVisible = false

    var body: some View {
        Button(action: UniHaptic.action(nil, perform: onOpen)) {
            SendActivityRow(operation: operation)
        }
        .accessibilityHint(Text("send.broadcast.navigation_title"))
        .accessibilityIdentifier("sendActivityRow_" + operation.id.uuidString)
        .onScrollVisibilityChange(threshold: 0.5) { isVisible = $0 }
        .modifier(SendActivityAutomaticDismissal(operation: operation, isEnabled: isVisible,
                                               onDismiss: onDismissConfirmed))
    }
}
