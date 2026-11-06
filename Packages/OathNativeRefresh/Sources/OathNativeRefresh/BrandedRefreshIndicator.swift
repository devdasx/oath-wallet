import SwiftUI

struct BrandedRefreshIndicator: View {
    let model: RefreshIndicatorModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var label: String {
        switch model.cycle.phase {
        case .idle, .pulling: model.labels.pull
        case .refreshing, .acknowledged: model.labels.refreshing
        case .succeeded: model.labels.succeeded
        case .failed: model.labels.failed
        }
    }

    var body: some View {
        let phase = model.cycle.phase
        ZStack {
            if phase == .succeeded || phase == .acknowledged {
                Image(systemName: "checkmark")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.white)
                    .transition(replacement)
                    .accessibilityIdentifier("refresh.logo.success")
            } else if phase == .failed {
                Image(systemName: "exclamationmark")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.white)
                    .transition(replacement)
                    .accessibilityIdentifier("refresh.logo.failure")
            } else {
                OathRefreshSolidMark(model: model)
                    .transition(replacement)
                    .accessibilityIdentifier("refresh.logo.mark")
            }
        }
        .frame(width: 54, height: 40)
        .animation(reduceMotion ? .easeOut(duration: 0.15) : .smooth(duration: 0.28), value: phase)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(phase == .pulling ? model.cycle.progress.formatted(.percent.precision(.fractionLength(0))) : "")
        .accessibilityIdentifier("refresh.logo")
    }

    private var replacement: AnyTransition { reduceMotion ? .opacity : AnyTransition(.blurReplace) }
}

private struct OathRefreshSolidMark: View {
    let model: RefreshIndicatorModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let animates = model.cycle.phase == .refreshing && !model.cycle.isReturning && model.isActive && !reduceMotion
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !animates)) { context in
            let elapsed = animates ? max(0, context.date.timeIntervalSince(model.startedAt)) : 0
            // A single white mark fills with the pull, then gently breathes while
            // loading. No rainbow fill or material can recolor the approved mark.
            OathRefreshMark()
                .fill(.white)
                .opacity(animates ? 0.8 + 0.2 * cos(elapsed * .pi * 2) : 1)
                .mask(alignment: .bottom) {
                    GeometryReader { geometry in
                        Rectangle()
                            .frame(height: geometry.size.height * model.cycle.progress)
                            .frame(maxHeight: .infinity, alignment: .bottom)
                    }
                }
        }
        .frame(width: 54, height: 54 * 504.465087890625 / 748)
    }
}
