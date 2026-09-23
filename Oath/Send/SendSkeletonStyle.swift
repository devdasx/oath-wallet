import SwiftUI

private struct SendSkeletonPulseModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isDimmed = false

    func body(content: Content) -> some View {
        content
            .opacity(isDimmed ? 0.38 : 1)
            .onAppear {
                startPulseIfNeeded()
            }
            .onChange(of: reduceMotion) {
                startPulseIfNeeded()
            }
    }

    private func startPulseIfNeeded() {
        if reduceMotion {
            withAnimation(nil) {
                isDimmed = false
            }
            return
        }

        isDimmed = false
        withAnimation(
            .easeInOut(duration: 0.68)
                .repeatForever(autoreverses: true)
        ) {
            isDimmed = true
        }
    }
}

extension View {
    func sendSkeletonPulse() -> some View {
        modifier(SendSkeletonPulseModifier())
    }
}
