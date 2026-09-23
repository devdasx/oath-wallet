import SwiftUI

struct AppRootDestinationAppearanceStyle: Equatable, Sendable {
    let initialOpacity: Double
    let initialScale: CGFloat
    let duration: TimeInterval

    static func resolved(
        reduceMotion: Bool
    ) -> AppRootDestinationAppearanceStyle {
        if reduceMotion {
            return AppRootDestinationAppearanceStyle(
                initialOpacity: 0,
                initialScale: 1,
                duration: 0.18
            )
        }

        return AppRootDestinationAppearanceStyle(
            initialOpacity: 0,
            initialScale: 0.985,
            duration: 0.30
        )
    }
}

private struct AppRootDestinationAppearanceModifier: ViewModifier {
    let reduceMotion: Bool
    let scalesContent: Bool

    @State private var isVisible = false

    func body(content: Content) -> some View {
        let style = AppRootDestinationAppearanceStyle.resolved(
            reduceMotion: reduceMotion
        )

        content
            .opacity(isVisible ? 1 : style.initialOpacity)
            .scaleEffect(isVisible || !scalesContent ? 1 : style.initialScale)
            .onAppear {
                guard !isVisible else { return }
                withAnimation(appearanceAnimation(style: style)) {
                    isVisible = true
                }
            }
    }

    private func appearanceAnimation(
        style: AppRootDestinationAppearanceStyle
    ) -> Animation {
        if reduceMotion {
            return .easeOut(duration: style.duration)
        }
        return .smooth(duration: style.duration)
    }
}

extension View {
    func appRootDestinationAppearance(
        reduceMotion: Bool,
        scalesContent: Bool = true
    ) -> some View {
        modifier(
            AppRootDestinationAppearanceModifier(
                reduceMotion: reduceMotion,
                scalesContent: scalesContent
            )
        )
    }
}
