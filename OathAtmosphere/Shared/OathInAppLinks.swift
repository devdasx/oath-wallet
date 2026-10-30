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
    private weak var activeDestination: UIViewController?
    private var activeURL: URL?
    private var pendingURL: URL?
    private var pendingTask: Task<Void, Never>?
    private enum OpenResult { case handled, transitioning, rejected }

    func open(_ url: URL) -> Bool {
        if pendingURL == url { return true }
        pendingTask?.cancel(); pendingTask = nil; pendingURL = nil
        switch attempt(url) {
        case .handled: return true
        case .rejected: return false
        case .transitioning:
            // Keep only the latest user request while UIKit changes presenters.
            // A cancelled or inactive scene must never open a delayed browser.
            pendingURL = url
            pendingTask = Task { @MainActor [weak self] in
                for _ in 0..<40 {
                    // A newer request superseding this one is expected teardown.
                    try? await Task.sleep(for: .milliseconds(50))
                    guard !Task.isCancelled, let self else { return }
                    switch self.attempt(url) {
                    case .transitioning: continue
                    case .handled, .rejected:
                        self.pendingURL = nil; self.pendingTask = nil
                        return
                    }
                }
                guard let self else { return }
                self.pendingURL = nil; self.pendingTask = nil
                OathDiagnostics.record(DiagnosticFailure("Link presentation transition did not finish"),
                    component: "navigation", operation: "open_link", severity: "warning",
                    context: ["stage": "transition_timeout"])
            }
            return true
        }
    }

    private func attempt(_ url: URL) -> OpenResult {
        guard let window else { unavailable(stage: "window_missing"); return .rejected }
        guard window.windowScene?.activationState == .foregroundActive else {
            unavailable(stage: "scene_inactive"); return .rejected
        }
        guard var top = window.rootViewController else { unavailable(stage: "root_missing"); return .rejected }
        while let presented = top.presentedViewController { top = presented }
        // Duplicate taps while our destination is appearing or already visible
        // are handled by that destination. Never coalesce a dismissing browser.
        if top === activeDestination, activeURL == url, !top.isBeingDismissed { return .handled }
        if top.isBeingDismissed || top.isBeingPresented { return .transitioning }
        guard !(top is SFSafariViewController), !(top is MFMailComposeViewController),
              !(top is UIAlertController) else {
            OathDiagnostics.record(DiagnosticFailure("Presentation already in progress"), component: "navigation", operation: "open_link", severity: "warning", context: ["stage": "destination_busy"])
            return .rejected
        }
        top.view.endEditing(true)
        switch OathLinkDestination(url) {
        case .web(let url):
            let browser = SFSafariViewController(url: url)
            browser.delegate = self
            browser.dismissButtonStyle = .done
            // Present Safari itself, never embed it inside a custom browser or
            // navigation controller. It owns its native toolbar and safe areas.
            activeURL = url; activeDestination = browser
            top.present(browser, animated: true)
        case .email(let recipient):
            if MFMailComposeViewController.canSendMail() {
                let composer = MFMailComposeViewController()
                composer.setToRecipients([recipient])
                composer.mailComposeDelegate = self
                activeURL = url; activeDestination = composer
                top.present(composer, animated: true)
            } else {
                let strings = OathLocalizer.current
                let alert = UIAlertController(title: strings.text(.contactUs),
                    message: strings.format(.contactMailUnavailable, recipient), preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: strings.text(.copyEmailAddress), style: .default) { _ in
                    OathClipboard.copy(recipient)
                })
                alert.addAction(UIAlertAction(title: strings.text(.cancel), style: .cancel))
                activeURL = url; activeDestination = alert
                top.present(alert, animated: true)
            }
        default: return .rejected
        }
        OathHaptics.shared.play(.navigate)
        return .handled
    }

    private func unavailable(stage: String) {
        // Distinguish attachment loss from scene transitions without recording
        // the link, window identity or other user content.
        OathDiagnostics.record(DiagnosticFailure("No active scene for link presentation"),
            component: "navigation", operation: "open_link", severity: "warning", context: ["stage": stage])
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
        view.presenter = presenter
        if let window = view.window { presenter.window = window }
    }
    static func dismantleUIView(_ view: Anchor, coordinator: ()) {
        // The presented destination can still hold this presenter's openURL
        // action after SwiftUI disposes its background anchor. Retain the weak
        // scene window, as didMoveToWindow already does on detachment. Clearing
        // it here also invalidates a replacement anchor sharing the presenter.
        // Disconnect only this view; the active-scene check still gates opening.
        view.presenter = nil
    }

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
