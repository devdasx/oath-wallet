import SwiftUI
import UIKit

extension View {
    /// Reapply at each hosting/presentation boundary, where SwiftUI can derive
    /// locale and direction from the device instead of the in-app preference.
    func oathLanguage(_ language: OathLanguage) -> some View {
        environment(\.oathLanguage, language)
            .environment(\.locale, language.locale)
            .environment(\.layoutDirection, language.isRightToLeft ? .rightToLeft : .leftToRight)
    }
}

/// UIKit needs both native traits (symbols/child controllers) and semantic
/// layout (bar items/constraints). Neither alone covers a presented sheet.
@MainActor enum OathLayoutDirection {
    static func apply(_ language: OathLanguage, to controller: UIViewController) {
        let direction: UITraitEnvironmentLayoutDirection = language.isRightToLeft ? .rightToLeft : .leftToRight
        // Unlike traitCollection, reading an unset override raises an Obj-C
        // exception. Install one even when the inherited direction matches,
        // so the app language stays explicit if the parent/device changes.
        if !controller.traitOverrides.contains(UITraitLayoutDirection.self)
            || controller.traitOverrides.layoutDirection != direction {
            controller.traitOverrides.layoutDirection = direction
        }
        apply(language, to: controller.view)
    }

    static func apply(_ language: OathLanguage, to view: UIView) {
        let direction: UITraitEnvironmentLayoutDirection = language.isRightToLeft ? .rightToLeft : .leftToRight
        // A fresh window/view has no override; short-circuit before the getter.
        if !view.traitOverrides.contains(UITraitLayoutDirection.self)
            || view.traitOverrides.layoutDirection != direction {
            view.traitOverrides.layoutDirection = direction
        }
        let semantic: UISemanticContentAttribute = language.isRightToLeft ? .forceRightToLeft : .forceLeftToRight
        if view.semanticContentAttribute != semantic { view.semanticContentAttribute = semantic }
    }
}

private struct OathLanguageEnvironmentKey: EnvironmentKey {
    static let defaultValue = OathLanguagePreference.current.resolve()
}

extension EnvironmentValues {
    var oathLanguage: OathLanguage {
        get { self[OathLanguageEnvironmentKey.self] }
        set { self[OathLanguageEnvironmentKey.self] = newValue }
    }
    var oathLocalizer: OathLocalizer { OathLocalizer(oathLanguage) }
}

struct OathLocalizedRoot<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Bindable var settings: OathAppSettings
    @ViewBuilder let content: () -> Content

    var body: some View {
        // A stable container owns the long-lived settings task. Group applies
        // it to each conditional child and cancels it as loading completes.
        ZStack {
            if settings.loaded { content() }
            else {
                OathEmptyStateScrollView {
                    OathEmptyState(title: OathLocalizer.current.text(.walletUnavailable),
                                   systemImage: "externaldrive.badge.exclamationmark") {
                        OathActionButton(title: OathLocalizer.current.text(.tryAgain), appearance: .secondary) { Task { await settings.observe() } }
                            .oathActionArea()
                    }
                }
            }
        }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(uiColor: OathSurfaceColors.canvas).ignoresSafeArea())
            .oathInAppLinks()
            .oathLanguage(settings.language)
            .background {
                OathSceneAppearance(appearance: settings.appearance, language: settings.language)
                    .frame(width: 0, height: 0)
            }
            .contentTransition(.opacity)
            .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: settings.language)
            .task { await settings.observe() }
            .alert(OathLocalizer.current.text(.walletUnavailable), isPresented: $settings.showsError) {
                if #available(iOS 26.0, *) {
                    OathButton(role: .confirm) {}
                        .accessibilityLabel(OathLocalizer.current.text(.done))
                        .accessibilityIdentifier("confirmation.done")
                        .oathConfirmationControl()
                } else {
                    OathButton(OathLocalizer.current.text(.done)) {}
                        .accessibilityIdentifier("confirmation.done")
                        .oathConfirmationControl()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                Task { await settings.observe() }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSLocale.currentLocaleDidChangeNotification)) { _ in
                settings.refreshSystemLanguage()
            }
            // Cover presentation modifiers too, not just the ZStack's children.
            .environment(settings)
    }
}
