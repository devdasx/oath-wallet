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
                OathRefreshGlassMark(model: model)
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

private struct OathRefreshGlassMark: View {
    let model: RefreshIndicatorModel
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        ZStack {
            if reduceTransparency {
                OathRefreshMark().fill(.white)
            }
            // A separate, small color surface lets the native glass refract
            // the fill. Neither the glass path nor Home rerenders every tick.
            OathRefreshColorFill(model: model)
            if !reduceTransparency {
                if #available(iOS 26, macOS 26, *) {
                    Color.clear.glassEffect(.clear, in: OathRefreshMark())
                } else {
                    OathRefreshMark().fill(.ultraThinMaterial)
                }
            }
        }
        .frame(width: 54, height: 54 * 580 / 860)
    }
}

private struct OathRefreshColorFill: View {
    let model: RefreshIndicatorModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let colors: [Color] = [.cyan, .blue, .indigo, .purple, .pink, .orange, .mint, .cyan]

    var body: some View {
        let animates = model.cycle.phase == .refreshing && !model.cycle.isReturning && model.isActive && !reduceMotion
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !animates)) { context in
            let elapsed = animates ? max(0, context.date.timeIntervalSince(model.startedAt)) : 0
            let angle = model.cycle.progress * 90 + elapsed * 300
            OathRefreshMark()
                .fill(AngularGradient(colors: colors, center: .center, angle: .degrees(angle)))
                .mask {
                    GeometryReader { geometry in
                        // A soft leading edge rises through both rings; at 1
                        // the full vector, including every crossing, is filled.
                        let progress = model.cycle.progress
                        LinearGradient(stops: [
                            .init(color: .clear, location: max(0, 1 - progress - 0.045)),
                            .init(color: .white, location: max(0, 1 - progress)),
                            .init(color: .white, location: 1)
                        ], startPoint: .top, endPoint: .bottom)
                        .opacity(progress > 0 ? 1 : 0)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                    }
                }
        }
    }
}
