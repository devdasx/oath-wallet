import UIKit

@MainActor struct OathSheetNavigationConfiguration {
    let strings: OathLocalizer
    let title: OathStringKey
    let backIdentifier: String
    let onBack: (() -> Void)?
    let onClose: () -> Void
    var actionsEnabled = true
    var closeOnLeadingEdgeAtRoot = false
    var showsCloseButton = true
    var backLabel: OathStringKey = .back
}

/// Every sheet state uses the same native bar items. UIKit owns their symbol
/// metrics, glass treatment and hit targets; no state supplies a custom size.
@MainActor enum OathSheetNavigationControls {
    static func close(strings: OathLocalizer, action: @escaping () -> Void) -> UIBarButtonItem {
        let button = UIBarButtonItem(image: UIImage(systemName: "xmark"), primaryAction: UIAction { _ in OathHaptics.shared.perform(.dismiss, action: action) })
        button.tintColor = .label
        button.accessibilityLabel = strings.text(.close)
        button.accessibilityIdentifier = "options.close"
        return button
    }

    static func back(strings: OathLocalizer, identifier: String, label: OathStringKey = .back,
                     action: @escaping () -> Void) -> UIBarButtonItem {
        // The directional SF Symbol already supplies its RTL variant. Adding
        // imageFlippedForRightToLeftLayoutDirection mirrors that variant again.
        let button = UIBarButtonItem(image: UIImage(systemName: "chevron.backward"), primaryAction: UIAction { _ in OathHaptics.shared.perform(.navigate, action: action) })
        button.tintColor = .label
        button.accessibilityLabel = strings.text(label)
        button.accessibilityIdentifier = identifier
        return button
    }

    static func configure(_ bar: UINavigationBar, strings: OathLocalizer) {
        OathLayoutDirection.apply(strings.language, to: bar)
        let appearance = bar.standardAppearance.copy()
        if strings.language == .arabic {
            appearance.titleTextAttributes[.font] = OathArabicFont.semibold.uiFont(size: 17, relativeTo: .headline)
        } else {
            appearance.titleTextAttributes.removeValue(forKey: .font)
        }
        bar.standardAppearance = appearance
        bar.scrollEdgeAppearance = appearance
    }
}
