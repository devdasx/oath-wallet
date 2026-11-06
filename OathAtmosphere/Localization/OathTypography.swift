import OathDiagnostics
import SwiftUI
import UIKit

/// iOS 27 can stop status-style delegation at SwiftUI's navigation controller:
/// the destination requests lightContent but the container returns default.
/// Forward through the documented container API to the visible destination.
/// This preserves SwiftUI's per-screen preference, including scrolling, without
/// changing the window theme, navigation background, or presented sheet theme.
/// https://developer.apple.com/documentation/technotes/tn3105-customizing-uistatusbar-syle
struct OathStatusBarHost<Content: View>: UIViewControllerRepresentable {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        // Build in the caller's SwiftUI update so scene/settings observations
        // remain attached to that update rather than a deferred UIKit callback.
        self.content = content()
    }

    func makeUIViewController(context: Context) -> Controller {
        Controller(rootView: content)
    }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.rootView = content
    }

    final class Controller: UIHostingController<Content> {
        override var childForStatusBarStyle: UIViewController? {
            var candidate = super.childForStatusBarStyle
            var visited = Set<ObjectIdentifier>()
            while let current = candidate, current !== self,
                  visited.insert(ObjectIdentifier(current)).inserted {
                if let navigation = current as? UINavigationController {
                    return navigation.visibleViewController
                }
                guard let child = current.childForStatusBarStyle else { return current }
                candidate = child
            }
            return nil
        }
    }
}

extension View {
    /// Native system fonts in every language. Text styles retain Dynamic Type;
    /// callers providing an explicit size own any scaling through ScaledMetric.
    func oathFont(_ style: Font.TextStyle, weight: Font.Weight = .regular,
                  size: CGFloat? = nil) -> some View {
        font(size.map { .system(size: $0, weight: weight) }
             ?? .system(style, design: .default, weight: weight))
    }

    func oathNativeLocalization(navigationTint: UIColor? = nil, onArtwork: Bool = false,
                                navigationBackground: Visibility = .automatic,
                                navigationMaterial: Material? = .regular,
                                systemNavigationAppearance: Bool = false,
                                file: StaticString = #fileID, line: UInt = #line) -> some View {
        background { OathNativeLocalizationChrome(
            navigationTint: systemNavigationAppearance ? nil : navigationTint ?? (onArtwork ? .white : .label)) }
            // Native symbol-only buttons read SwiftUI tint, while UIKit back
            // items read the bar tint. Set both to avoid a blue inherited accent
            // reappearing when navigation/Face ID rebuilds the native toolbar.
            .tint(systemNavigationAppearance ? nil : Color(uiColor: navigationTint ?? (onArtwork ? .white : .label)))
            .modifier(OathNativeNavigationAppearance(onArtwork: onArtwork, background: navigationBackground,
                                                      material: navigationMaterial, systemAppearance: systemNavigationAppearance))
            .modifier(OathDiagnosticScreen(file: file, line: line, active: true))
    }
}

/// Destination-scoped native chrome. Never attach an artwork preference to a
/// NavigationStack itself: it would also style the neutral screens pushed on it.
private struct OathNativeNavigationAppearance: ViewModifier {
    let onArtwork: Bool
    let background: Visibility
    let material: Material?
    let systemAppearance: Bool
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        if #available(iOS 27, *) {
            navigationAppearance(content)
                .toolbarVisibility(.visible, for: .statusBar)
                .toolbarBackgroundVisibility(background, for: .navigationBar)
        } else {
            navigationAppearance(content)
                .statusBarHidden(false)
                .toolbarBackground(background, for: .navigationBar)
        }
    }

    @ViewBuilder private func navigationAppearance(_ content: Content) -> some View {
        if systemAppearance {
            // The shared artwork app bar owns its native contrast preference.
            // A second nil preference here also participates in SwiftUI's
            // toolbar preference resolution; it is not an absence of styling.
            navigationContent(content)
        } else {
            navigationContent(content)
                .toolbarColorScheme(onArtwork ? .dark : colorScheme, for: .navigationBar)
        }
    }

    @ViewBuilder private func navigationContent(_ content: Content) -> some View {
        if let material {
            content.toolbarBackground(material, for: .navigationBar)
        } else {
            // Leave the native scroll-edge appearance in charge. A clear fill
            // would override it too, rather than restoring system behavior.
            content
        }
    }
}

/// Uses UIKit's native semantic direction and appearance APIs for navigation
/// chrome that lives outside SwiftUI stacks. Never replaces gesture delegates,
/// swaps coordinates, flips transforms, or rebuilds the navigation hierarchy.
private struct OathNativeLocalizationChrome: UIViewControllerRepresentable {
    @Environment(\.oathLanguage) private var language
    let navigationTint: UIColor?

    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.language = language
        controller.navigationTint = navigationTint
        controller.apply()
    }

    final class Controller: UIViewController {
        var language = OathLanguage.english
        var navigationTint: UIColor?
        override func loadView() {
            view = UIView()
            view.isUserInteractionEnabled = false
            view.isAccessibilityElement = false
            NotificationCenter.default.addObserver(self, selector: #selector(searchBeganEditing),
                name: UITextField.textDidBeginEditingNotification, object: nil)
        }
        override func viewWillAppear(_ animated: Bool) { super.viewWillAppear(animated); apply() }
        override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); apply() }

        func apply() {
            OathLayoutDirection.apply(language, to: self)
            if let tabBar = tabBarController?.tabBar { OathTabBarStyle.apply(to: tabBar) }
            guard let navigation = navigationController else { return }
            OathLayoutDirection.apply(language, to: navigation)
            OathLayoutDirection.apply(language, to: navigation.navigationBar)
            let bar = navigation.navigationBar
            // Clear a previous destination's explicit tint when returning to
            // system-managed chrome; otherwise artwork white can remain stuck.
            if bar.tintColor != navigationTint { bar.tintColor = navigationTint }
            for controller in navigation.viewControllers {
                OathLayoutDirection.apply(language, to: controller)
                // Keep UIKit's native back indicator and swipe gestures, with
                // no visible title on this or the next navigation destination.
                if controller.navigationItem.backButtonDisplayMode != .minimal {
                    controller.navigationItem.backButtonDisplayMode = .minimal
                }
                let backTitle = OathLocalizer(language).text(.back)
                if controller.navigationItem.backButtonTitle != backTitle {
                    controller.navigationItem.backButtonTitle = backTitle
                }
            }
            if let field = navigation.topViewController?.navigationItem.searchController?.searchBar.searchTextField {
                OathKeyboardAccessory.removeFromSearch(field)
                OathLayoutDirection.apply(language, to: field)
                let font = UIFont.preferredFont(forTextStyle: .body)
                field.adjustsFontForContentSizeCategory = true
                if field.font != font { field.font = font }
            }
        }

        @objc private func searchBeganEditing(_ notification: Notification) {
            guard let field = notification.object as? UISearchTextField,
                  let window = view.window, field.window === window else { return }
            OathKeyboardAccessory.removeFromSearch(field)
        }

        deinit { NotificationCenter.default.removeObserver(self) }
    }
}

/// Fixed source labels only; no screen text or model values enter diagnostics.
private struct OathDiagnosticScreen: ViewModifier {
    let file: StaticString
    let line: UInt
    let active: Bool
    @State private var token = UUID()
    func body(content: Content) -> some View {
        content.onAppear { if active { OathDiagnostics.screenAppeared(token, file: file, line: line) } }
            .onChange(of: active) { _, active in
                if active { OathDiagnostics.screenAppeared(token, file: file, line: line) }
                else { OathDiagnostics.screenDisappeared(token) }
            }
            .onDisappear { OathDiagnostics.screenDisappeared(token) }
    }
}

extension View {
    func oathDiagnosticsScreen(active: Bool = true, file: StaticString = #fileID, line: UInt = #line) -> some View {
        modifier(OathDiagnosticScreen(file: file, line: line, active: active))
    }
}
