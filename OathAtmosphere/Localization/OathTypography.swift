import SwiftUI
import UIKit

enum OathArabicFont: String, CaseIterable {
    case regular = "IBMPlexSansArabic-Regular"
    case medium = "IBMPlexSansArabic-Medium"
    case semibold = "IBMPlexSansArabic-SemiBold"
    case bold = "IBMPlexSansArabic-Bold"

    static func face(for weight: Font.Weight) -> Self {
        switch weight {
        case .bold, .heavy, .black: .bold
        case .semibold: .semibold
        case .medium: .medium
        default: .regular
        }
    }

    func uiFont(size: CGFloat, relativeTo style: UIFont.TextStyle) -> UIFont {
        // UIAppFonts registers the bundled family. The fallback keeps content
        // readable if a damaged installation loses a resource; tests assert
        // every registered name so a fallback never counts as validation.
        let font = UIFont(name: rawValue, size: size) ?? .systemFont(ofSize: size)
        return UIFontMetrics(forTextStyle: style).scaledFont(for: font)
    }
}

private struct OathFontModifier: ViewModifier {
    @Environment(\.oathLanguage) private var language
    let style: Font.TextStyle
    let weight: Font.Weight
    let size: CGFloat?
    let alreadyScaled: Bool

    func body(content: Content) -> some View {
        content.font(font)
    }

    private var font: Font {
        if language == .arabic {
            let name = OathArabicFont.face(for: weight).rawValue
            if alreadyScaled, let size { return .custom(name, fixedSize: size) }
            return .custom(name, size: size ?? baseSize, relativeTo: style)
        }
        if let size { return .system(size: size, weight: weight) }
        return .system(style, design: .default).weight(weight)
    }

    private var baseSize: CGFloat {
        switch style {
        case .largeTitle: 34
        case .title: 28
        case .title2: 22
        case .title3: 20
        case .headline, .body: 17
        case .callout: 16
        case .subheadline: 15
        case .footnote: 13
        case .caption: 12
        case .caption2: 11
        @unknown default: 17
        }
    }
}

extension View {
    func oathFont(_ style: Font.TextStyle, weight: Font.Weight = .regular,
                  size: CGFloat? = nil, alreadyScaled: Bool = false) -> some View {
        modifier(OathFontModifier(style: style, weight: weight, size: size, alreadyScaled: alreadyScaled))
    }

    func oathNativeLocalization(navigationTint: UIColor? = nil, onArtwork: Bool = false,
                                navigationBackground: Visibility = .automatic) -> some View {
        background { OathNativeLocalizationChrome(navigationTint: navigationTint ?? (onArtwork ? .white : .label)) }
            // Native symbol-only buttons read SwiftUI tint, while UIKit back
            // items read the bar tint. Set both to avoid a blue inherited accent
            // reappearing when navigation/Face ID rebuilds the native toolbar.
            .tint(Color(uiColor: navigationTint ?? (onArtwork ? .white : .label)))
            .modifier(OathNativeNavigationAppearance(onArtwork: onArtwork, background: navigationBackground))
    }
}

/// Destination-scoped native chrome. Never attach an artwork preference to a
/// NavigationStack itself: it would also style the neutral screens pushed on it.
private struct OathNativeNavigationAppearance: ViewModifier {
    let onArtwork: Bool
    let background: Visibility
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let scheme: ColorScheme = onArtwork ? .dark : colorScheme
        if #available(iOS 27, *) {
            content
                .toolbarVisibility(.visible, for: .statusBar)
                .toolbarBackground(.regularMaterial, for: .navigationBar)
                .toolbarBackground(background, for: .navigationBar)
                .toolbarColorScheme(scheme, for: .navigationBar, .statusBar)
        } else {
            content
                .statusBarHidden(false)
                .toolbarBackground(.regularMaterial, for: .navigationBar)
                .toolbarBackground(background, for: .navigationBar)
                .toolbarColorScheme(scheme, for: .navigationBar)
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
            if let navigationTint, bar.tintColor != navigationTint { bar.tintColor = navigationTint }
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
            // Search/keyboard transitions update the hosting view repeatedly.
            // Reassigning equal appearance copies invalidates native bar layout
            // during that animation. Only change attributes that actually differ.
            if let updated = appearance(bar.standardAppearance) { bar.standardAppearance = updated }
            for path in [\UINavigationBar.scrollEdgeAppearance, \.compactAppearance, \.compactScrollEdgeAppearance] {
                if let current = bar[keyPath: path], let updated = appearance(current) {
                    bar[keyPath: path] = updated
                }
            }
            if let field = navigation.topViewController?.navigationItem.searchController?.searchBar.searchTextField {
                OathKeyboardAccessory.removeFromSearch(field)
                OathLayoutDirection.apply(language, to: field)
                let font: UIFont = language == .arabic
                    ? OathArabicFont.regular.uiFont(size: 17, relativeTo: .body)
                    : .preferredFont(forTextStyle: .body)
                if field.font != font { field.font = font }
            }
        }

        @objc private func searchBeganEditing(_ notification: Notification) {
            guard let field = notification.object as? UISearchTextField,
                  let window = view.window, field.window === window else { return }
            OathKeyboardAccessory.removeFromSearch(field)
        }

        deinit { NotificationCenter.default.removeObserver(self) }

        private func appearance(_ original: UINavigationBarAppearance) -> UINavigationBarAppearance? {
            let titleFont = language == .arabic ? OathArabicFont.semibold.uiFont(size: 17, relativeTo: .headline) : nil
            let largeFont = language == .arabic ? OathArabicFont.bold.uiFont(size: 34, relativeTo: .largeTitle) : nil
            let buttonFont = language == .arabic ? OathArabicFont.medium.uiFont(size: 17, relativeTo: .body) : nil
            // Compare the attributes we own, not opaque appearance-object
            // identity. Leave SwiftUI's glass, colors and backgrounds intact.
            let buttons = [original.buttonAppearance, original.doneButtonAppearance, original.backButtonAppearance]
            guard original.titleTextAttributes[.font] as? UIFont != titleFont
                || original.largeTitleTextAttributes[.font] as? UIFont != largeFont
                || buttons.contains(where: { $0.normal.titleTextAttributes[.font] as? UIFont != buttonFont })
            else { return nil }
            let copy = original.copy()
            if language == .arabic {
                copy.titleTextAttributes[.font] = titleFont
                copy.largeTitleTextAttributes[.font] = largeFont
                for button in [copy.buttonAppearance, copy.doneButtonAppearance, copy.backButtonAppearance] {
                    button.normal.titleTextAttributes[.font] = buttonFont
                }
            } else {
                copy.titleTextAttributes.removeValue(forKey: .font)
                copy.largeTitleTextAttributes.removeValue(forKey: .font)
                for button in [copy.buttonAppearance, copy.doneButtonAppearance, copy.backButtonAppearance] {
                    button.normal.titleTextAttributes.removeValue(forKey: .font)
                }
            }
            return copy
        }
    }
}
