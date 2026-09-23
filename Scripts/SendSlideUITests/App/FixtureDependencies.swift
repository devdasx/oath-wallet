import SwiftUI

// Same semantic surfaces and native glass used by the production slider.
// Gesture, view, and haptic behavior compile directly from production sources.
enum WalletTheme {
    static let primaryAction = Color(uiColor: .systemBlue)
    static let onAccentLabel = Color(uiColor: .white)
    static let disabledControlLabel = Color(uiColor: .secondaryLabel)
    static let disabledControlFill = Color(uiColor: .systemGray4)
    static let groupedSurface = Color(uiColor: .secondarySystemGroupedBackground)
    static let groupedBackground = Color(uiColor: .systemGroupedBackground)
}

extension View {
    func walletRegularGlassEffect<S: Shape>(tint: Color, interactive: Bool = false, in shape: S) -> some View {
        glassEffect(.regular.tint(tint).interactive(interactive), in: shape)
    }
}
