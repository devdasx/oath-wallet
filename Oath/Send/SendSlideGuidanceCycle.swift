import SwiftUI

/// Rebuild only the decorative animator when guidance resumes. A PhaseAnimator
/// created with one idle phase does not start cycling when its phases expand.
/// The slider's gesture and layout identity remain untouched.
struct SendSlideGuidanceCycle<Phase: Equatable, Content: View>: View {
    let isActive: Bool
    let phases: [Phase]
    let idlePhase: Phase
    @ViewBuilder let content: (Phase) -> Content
    let animation: (Phase) -> Animation

    var body: some View {
        PhaseAnimator(isActive ? phases : [idlePhase], content: content) { phase in
            isActive ? animation(phase) : nil
        }
        .id(isActive)
    }
}
