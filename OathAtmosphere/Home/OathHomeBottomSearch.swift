import SwiftUI
import UIKit

enum OathHomeTab: Hashable { case wallet, history, search }

/// Own only native tab icon colors; retain the system's glass and selection pill.
@MainActor enum OathTabBarStyle {
    static let selectedColor = UIColor.label
    static let unselectedColor = makeUnselectedColor()

    // Native color providers can be evaluated off the main thread.
    nonisolated private static func makeUnselectedColor() -> UIColor {
        UIColor { traits in
            UIColor(white: traits.userInterfaceStyle == .dark ? 0.68 : 0.35, alpha: 1)
        }
    }

    static func apply(to bar: UITabBar) {
        if bar.tintColor != selectedColor { bar.tintColor = selectedColor }
        if bar.unselectedItemTintColor != unselectedColor { bar.unselectedItemTintColor = unselectedColor }
        if let updated = updatedAppearance(bar.standardAppearance) { bar.standardAppearance = updated }
        if let current = bar.scrollEdgeAppearance, let updated = updatedAppearance(current) {
            bar.scrollEdgeAppearance = updated
        }
    }

    private static func updatedAppearance(_ original: UITabBarAppearance) -> UITabBarAppearance? {
        let layouts = [original.stackedLayoutAppearance, original.inlineLayoutAppearance,
                       original.compactInlineLayoutAppearance]
        guard layouts.contains(where: { $0.selected.iconColor != selectedColor || $0.normal.iconColor != unselectedColor })
        else { return nil }
        let copy = original.copy()
        for layout in [copy.stackedLayoutAppearance, copy.inlineLayoutAppearance, copy.compactInlineLayoutAppearance] {
            layout.selected.iconColor = selectedColor
            layout.normal.iconColor = unselectedColor
        }
        return copy
    }
}

/// The system search-role tab supplies the separate trailing control, keyboard,
/// cancellation and safe area. No floating field or toolbar spacer is installed.
struct OathSearchTabActivation: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content.tabViewSearchActivation(.searchTabSelection)
        } else {
            content
        }
    }
}

/// Keep one search controller on the dedicated search stack, with an explicit
/// toolbar placement. Automatic placement can fall back to the navigation
/// drawer when native search deactivates or the selected search context changes.
/// The presentation binding lets asset selection end search through SwiftUI;
/// resigning the keyboard alone leaves the search controller active.
struct OathHomeSearchField: ViewModifier {
    @Binding var query: String
    @Binding var isPresented: Bool
    let prompt: String

    func body(content: Content) -> some View {
        content.searchable(text: $query, isPresented: $isPresented, placement: .toolbar, prompt: Text(prompt))
    }
}
