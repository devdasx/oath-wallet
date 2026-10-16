import SwiftUI

/// A single persistent glass surface whose contents cycle through wallet features.
struct OathFeatureCapsule: View {
    @Environment(\.oathLocalizer) private var strings
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @State private var feature = Feature.send

    private var displayedFeature: Feature {
        reduceMotion || voiceOverEnabled ? .selfCustody : feature
    }

    private var shouldCycle: Bool {
        scenePhase == .active && !reduceMotion && !voiceOverEnabled
    }

    var body: some View {
        glassCaption
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(strings.text(.featuresAccessibility))
            .accessibilityAddTraits(.isStaticText)
            .accessibilityIdentifier("onboarding.featureCapsule")
            .allowsHitTesting(false)
            .task(id: shouldCycle) {
                guard shouldCycle else { return }
                while !Task.isCancelled {
                    do {
                        try await Task.sleep(for: feature.dwell)
                    } catch {
                        return
                    }
                    guard !Task.isCancelled else { return }
                    withAnimation(.smooth(duration: 0.52)) {
                        feature = feature.next
                    }
                }
            }
    }

    @ViewBuilder
    private var glassCaption: some View {
        if reduceTransparency {
            // The white artwork label needs an opaque blue surface when
            // transparency is disabled, without overriding the scene's theme.
            caption.background(Color(red: 0.12, green: 0.24, blue: 0.43), in: Capsule())
        } else if #available(iOS 26.0, *) {
            // The caption floats over animated artwork. Keep one untinted,
            // native clear-glass surface as its feature labels transition.
            caption.glassEffect(.clear, in: Capsule())
        } else {
            caption.background(.ultraThinMaterial, in: Capsule())
        }
    }

    private var caption: some View {
        HStack(spacing: 8) {
            if let symbol = displayedFeature.symbol {
                Image(systemName: symbol)
                    .symbolRenderingMode(.monochrome)
                    .flipsForRightToLeftLayoutDirection(displayedFeature == .send || displayedFeature == .receive)
                    .id(displayedFeature)
                    .transition(.blurReplace)
                    .accessibilityHidden(true)
            }

            Text(strings.text(displayedFeature.title))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .id(displayedFeature)
                .transition(.blurReplace)
        }
        .oathFont(.subheadline, weight: .medium)
        .foregroundStyle(.white)
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
        .frame(minWidth: 112, minHeight: 42)
    }

    private enum Feature: Int, CaseIterable {
        case send, receive, pay, request, selfCustody

        var title: OathStringKey {
            switch self {
            case .send: .send
            case .receive: .receive
            case .pay: .pay
            case .request: .requestCrypto
            case .selfCustody: .selfCustody
            }
        }

        var symbol: String? {
            switch self {
            case .send: "arrow.up.right"
            case .receive: "arrow.down.left"
            case .pay: "qrcode.viewfinder"
            case .request: "arrow.down.message"
            case .selfCustody: nil
            }
        }

        var dwell: Duration {
            switch self {
            case .send, .receive, .pay: .seconds(2.4)
            case .request: .seconds(2.8)
            case .selfCustody: .seconds(3.2)
            }
        }

        var next: Self {
            Self.allCases[(rawValue + 1) % Self.allCases.count]
        }
    }
}
