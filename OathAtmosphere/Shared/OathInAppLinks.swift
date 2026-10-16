import OathDiagnostics
import SwiftUI
import SafariServices
import MessageUI

extension View {
    func oathInAppLinks() -> some View { modifier(OathInAppLinksModifier()) }
}

private struct OathInAppLinksModifier: ViewModifier {
    @State private var presenter = OathLinkPresenter()

    func body(content: Content) -> some View {
        content
            .environment(\.openURL, OpenURLAction { url in
                switch OathLinkDestination(url) {
                case .web, .email:
                    return presenter.open(url) ? .handled : .discarded
                case .system: return .systemAction
                case .unsupported: return .discarded
                }
            })
            .background(OathLinkAnchor(presenter: presenter).frame(width: 0, height: 0))
    }
}

/// Anchor to this scene, not UIApplication's first window. Present over the
/// currently visible sheet so explorer and information links work there too.
@MainActor private final class OathLinkPresenter: NSObject, SFSafariViewControllerDelegate, MFMailComposeViewControllerDelegate {
    weak var window: UIWindow?

    func open(_ url: URL) -> Bool {
        guard let window, window.windowScene?.activationState == .foregroundActive,
              var top = window.rootViewController else {
            OathDiagnostics.record(DiagnosticFailure("No active scene for link presentation"), component: "navigation", operation: "open_link", severity: "warning")
            return false
        }
        while let presented = top.presentedViewController { top = presented }
        guard !top.isBeingDismissed, !top.isBeingPresented,
              !(top is SFSafariViewController), !(top is MFMailComposeViewController),
              !(top is UIAlertController) else {
            OathDiagnostics.record(DiagnosticFailure("Presentation already in progress"), component: "navigation", operation: "open_link", severity: "warning")
            return false
        }
        top.view.endEditing(true)
        switch OathLinkDestination(url) {
        case .web(let url):
            let browser = SFSafariViewController(url: url)
            browser.delegate = self
            browser.dismissButtonStyle = .done
            // Present Safari itself, never embed it inside a custom browser or
            // navigation controller. It owns its native toolbar and safe areas.
            top.present(browser, animated: true)
        case .email(let recipient):
            if MFMailComposeViewController.canSendMail() {
                let composer = MFMailComposeViewController()
                composer.setToRecipients([recipient])
                composer.mailComposeDelegate = self
                top.present(composer, animated: true)
            } else {
                let strings = OathLocalizer.current
                let alert = UIAlertController(title: strings.text(.contactUs),
                    message: strings.format(.contactMailUnavailable, recipient), preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: strings.text(.copyEmailAddress), style: .default) { _ in
                    OathClipboard.copy(recipient)
                })
                alert.addAction(UIAlertAction(title: strings.text(.cancel), style: .cancel))
                top.present(alert, animated: true)
            }
        default: return false
        }
        OathHaptics.shared.play(.navigate)
        return true
    }

    nonisolated func safariViewControllerDidFinish(_ controller: SFSafariViewController) {
        Task { @MainActor in controller.dismiss(animated: true) }
    }

    nonisolated func mailComposeController(_ controller: MFMailComposeViewController,
                               didFinishWith result: MFMailComposeResult, error: Error?) {
        if let error { OathDiagnostics.record(error, component: "navigation", operation: "compose_email") }
        Task { @MainActor in controller.dismiss(animated: true) }
    }

    nonisolated func safariViewController(_ controller: SFSafariViewController, didCompleteInitialLoad didLoadSuccessfully: Bool) {
        if !didLoadSuccessfully {
            OathDiagnostics.record(DiagnosticFailure("Safari initial load failed"), component: "navigation", operation: "browser_load")
        }
    }
}

private struct OathLinkAnchor: UIViewRepresentable {
    let presenter: OathLinkPresenter
    func makeUIView(context: Context) -> Anchor {
        let view = Anchor()
        view.isUserInteractionEnabled = false
        view.presenter = presenter
        return view
    }
    func updateUIView(_ view: Anchor, context: Context) {
        if let window = view.window { presenter.window = window }
    }
    static func dismantleUIView(_ view: Anchor, coordinator: ()) { view.presenter?.window = nil }

    final class Anchor: UIView {
        weak var presenter: OathLinkPresenter?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            // Full-screen covers temporarily detach the presenting view. Keep
            // its scene's window so Settings links can present above that cover.
            if let window { presenter?.window = window }
        }
    }
}
