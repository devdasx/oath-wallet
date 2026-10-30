import SwiftUI
import UIKit
import OathDatabase

/// Shared neutral surfaces for SwiftUI and UIKit. Light uses white and soft gray;
/// Dark uses layered charcoal. Dynamic UIColors
/// follow the scene's native traits, including already-presented sheets.
@MainActor enum OathSurfaceColors {
    static let canvas = adaptive(light: OathNeutralColors.lightCanvas, dark: OathNeutralColors.darkCanvas)
    static let groupedCanvas = adaptive(light: OathNeutralColors.lightGroupedCanvas, dark: OathNeutralColors.darkCanvas)
    static let card = adaptive(light: OathNeutralColors.lightCanvas, dark: OathNeutralColors.darkCard)
    static let field = adaptive(light: OathNeutralColors.lightField, dark: OathNeutralColors.darkField)
    static let sheet = adaptive(light: OathNeutralColors.lightGroupedCanvas, dark: OathNeutralColors.darkSheet)
    static let sheetCard = adaptive(light: OathNeutralColors.lightCanvas, dark: OathNeutralColors.darkSheetCard)

    // SwiftUI also resolves dynamic colors on its asynchronous render thread,
    // notably during native navigation transitions. Construct the immutable
    // provider outside MainActor so invoking it there cannot trap in Swift 6.
    nonisolated private static func adaptive(light: UInt32, dark: UInt32) -> UIColor {
        func color(_ rgb: UInt32) -> UIColor {
            UIColor(red: CGFloat((rgb >> 16) & 255) / 255,
                    green: CGFloat((rgb >> 8) & 255) / 255,
                    blue: CGFloat(rgb & 255) / 255, alpha: 1)
        }
        let lightColor = color(light), darkColor = color(dark)
        return UIColor { traits in
            traits.userInterfaceStyle == .dark ? darkColor : lightColor
        }
    }
}

/// Own appearance at the scene's actual UIWindow. A SwiftUI presentation can
/// retain its own preferredColorScheme, so a root-view preference alone is not
/// sufficient for already presented UIKit sheets. All controllers inherit this
/// native window traits, including controllers created after the choice changes.
/// Language direction also belongs here so system presentations and newly
/// created hosting controllers inherit the app language, not the device's.
struct OathSceneAppearance: UIViewRepresentable {
    let appearance: AppAppearance
    let language: OathLanguage

    func makeUIView(context: Context) -> Anchor { Anchor() }

    func updateUIView(_ view: Anchor, context: Context) {
        view.configure(appearance: appearance, language: language)
    }

    final class Anchor: UIView {
        private var requestedAppearance: AppAppearance?
        private var requestedLanguage = OathLanguage.english

        init() {
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            isAccessibilityElement = false
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("Use init()") }

        func configure(appearance: AppAppearance, language: OathLanguage) {
            // Commit together: attaching an unconfigured anchor or updating the
            // language must never briefly release an explicit Light/Dark choice.
            requestedAppearance = appearance
            requestedLanguage = language
            apply()
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            apply()
        }

        private func apply() {
            guard let window, let requestedAppearance else { return }
            let style: UIUserInterfaceStyle
            switch requestedAppearance {
            case .system: style = .unspecified
            case .light: style = .light
            case .dark: style = .dark
            }
            if window.overrideUserInterfaceStyle != style {
                window.overrideUserInterfaceStyle = style
            }
            OathLayoutDirection.apply(requestedLanguage, to: window)
        }

        // These are saved scene preferences, not a temporary view override.
        // Detaching/recreating the bridge must not restore an older system style
        // while retained sheets and the lock presentation still use the window.
    }
}
