import SwiftUI
import UIKit

extension View {
    /// Applies the current presentation's native horizontal margins once to
    /// an action or action group. Native list-row actions keep their row insets.
    func walletActionScreenMargins() -> some View {
        modifier(WalletActionScreenMargins())
    }

    /// Native list rows and other inset containers already own their margins.
    func walletActionUsesContainerMargins() -> some View {
        environment(\.walletActionMarginsProvided, true)
    }

    func walletAutomaticActionMargins() -> some View {
        modifier(WalletAutomaticActionMargins())
    }
}

private struct WalletActionMarginsProvidedKey: EnvironmentKey {
    static let defaultValue = false
}

private extension EnvironmentValues {
    var walletActionMarginsProvided: Bool {
        get { self[WalletActionMarginsProvidedKey.self] }
        set { self[WalletActionMarginsProvidedKey.self] = newValue }
    }
}

private struct WalletAutomaticActionMargins: ViewModifier {
    @Environment(\.walletActionMarginsProvided) private var marginsProvided

    @ViewBuilder
    func body(content: Content) -> some View {
        if marginsProvided {
            content
        } else {
            content.walletActionScreenMargins()
        }
    }
}

private struct WalletActionScreenMargins: ViewModifier {
    @State private var margins: EdgeInsets?

    func body(content: Content) -> some View {
        content
            .walletActionUsesContainerMargins()
            .frame(maxWidth: 560)
            .padding(.leading, margins?.leading)
            .padding(.trailing, margins?.trailing)
            .frame(maxWidth: .infinity)
            .background {
                NativeMarginsReader { value in
                    margins = value
                }
                .accessibilityHidden(true)
            }
    }

    private struct NativeMarginsReader: UIViewRepresentable {
        let onChange: (EdgeInsets) -> Void

        func makeUIView(context: Context) -> MarginView {
            let view = MarginView()
            view.isUserInteractionEnabled = false
            view.preservesSuperviewLayoutMargins = true
            view.onChange = onChange
            return view
        }

        func updateUIView(_ view: MarginView, context: Context) {
            view.onChange = onChange
            view.publishMargins()
        }

        final class MarginView: UIView {
            var onChange: ((EdgeInsets) -> Void)?
            private var publishedMargins: EdgeInsets?

            override init(frame: CGRect) {
                super.init(frame: frame)
                registerForTraitChanges([
                    UITraitHorizontalSizeClass.self,
                    UITraitVerticalSizeClass.self
                ]) { (view: MarginView, _: UITraitCollection) in
                    view.publishMargins()
                }
            }

            required init?(coder: NSCoder) {
                fatalError("init(coder:) has not been implemented")
            }

            override func didMoveToWindow() {
                super.didMoveToWindow()
                publishMargins()
            }

            override func layoutSubviews() {
                super.layoutSubviews()
                publishMargins()
            }

            override func layoutMarginsDidChange() {
                super.layoutMarginsDidChange()
                publishMargins()
            }

            func publishMargins() {
                guard window != nil else { return }
                var responder = next
                while let current = responder {
                    if let controller = current as? UIViewController {
                        let native = controller.systemMinimumLayoutMargins
                        let value = EdgeInsets(
                            top: 0, leading: native.leading,
                            bottom: 0, trailing: native.trailing
                        )
                        guard value != publishedMargins else { return }
                        publishedMargins = value
                        // UIKit can report margins during a SwiftUI layout pass.
                        DispatchQueue.main.async { [weak self] in
                            guard let self, self.window != nil else { return }
                            self.onChange?(value)
                        }
                        return
                    }
                    responder = current.next
                }
            }
        }
    }
}
