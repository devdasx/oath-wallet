import SwiftUI

extension View {
    func oathWalletConnectPresentation(session: OathWalletSession) -> some View {
        modifier(OathWalletConnectPresentation(session: session))
    }
}

private struct OathWalletConnectPresentation: ViewModifier {
    let session: OathWalletSession
    @Environment(\.scenePhase) private var scenePhase
    private let service = OathWalletConnectService.shared
    private let inbox = OathWalletLinkInbox.shared

    func body(content: Content) -> some View {
        content.background {
            Anchor(session: session,
                   enabled: scenePhase == .active && session.isUnlocked && !session.changingWallet && !session.resetting,
                   pending: service.needsPresentation || inbox.hasWalletConnectRequest,
                   occupied: service.presentationOpen)
                .frame(width: 0, height: 0)
        }
    }

    private struct Anchor: UIViewRepresentable {
        let session: OathWalletSession
        let enabled: Bool
        let pending: Bool
        let occupied: Bool

        func makeCoordinator() -> OathStackedSheetPresenter { OathStackedSheetPresenter() }
        func makeUIView(context: Context) -> WindowAnchor {
            let view = WindowAnchor()
            view.isUserInteractionEnabled = false
            view.presenter = context.coordinator
            return view
        }
        func updateUIView(_ view: WindowAnchor, context: Context) {
            let presenter = context.coordinator
            if let window = view.window { presenter.window = window }
            presenter.environment = context.environment
            presenter.hasPending = {
                enabled && pending && !occupied && session.isUnlocked && !session.changingWallet && !session.resetting &&
                    !OathWalletConnectService.shared.presentationOpen
            }
            presenter.takePending = {
                let service = OathWalletConnectService.shared
                let inbox = OathWalletLinkInbox.shared
                guard session.isUnlocked, !session.changingWallet, !session.resetting,
                      !service.presentationOpen else { return nil }
                let entry: OathWalletLinkInbox.Entry
                var consumedLink = false
                if service.needsPresentation {
                    if inbox.pending?.route == .connections { consumedLink = inbox.take(walletConnectOnly: true) != nil }
                    entry = .init(route: .connections, expires: .distantFuture)
                } else {
                    guard let next = inbox.take(walletConnectOnly: true) else { return nil }
                    entry = next
                    consumedLink = true
                }
                guard service.presentationDidOpen(entry.id) else { return nil }
                return .init(id: entry.id, content: { close, dismissDisabled in
                    AnyView(OathWalletConnectSheet(uri: entry.uri, session: session,
                        presentationID: entry.id, onDismiss: close, onDismissDisabledChange: dismissDisabled))
                }, onDismiss: {
                    if consumedLink { inbox.didDismiss() }
                    service.presentationDidDismiss(entry.id)
                })
            }
            presenter.update()
        }

        static func dismantleUIView(_ view: WindowAnchor, coordinator: OathStackedSheetPresenter) {
            // Full-screen covers detach the Home anchor. The presenter remains
            // attached to this scene through its weak window until it reappears.
            view.presenter = nil
        }

        final class WindowAnchor: UIView {
            weak var presenter: OathStackedSheetPresenter?
            override func didMoveToWindow() {
                super.didMoveToWindow()
                if let window { presenter?.window = window; presenter?.update() }
            }
        }
    }
}
