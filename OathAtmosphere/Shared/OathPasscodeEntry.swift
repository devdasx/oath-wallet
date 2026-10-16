import SwiftUI
import UIKit

/// Shared presentation only. Callers keep ownership of secrets, authentication,
/// navigation and lifecycle; this view receives a PIN count, never the digits.
struct OathPasscodeEntry: View {
    struct Prompt {
        let title: String
        let detail: String
    }

    let title: String
    var detail: String? = nil
    var alternatePrompt: Prompt? = nil
    let filledCount: Int
    var length = 6
    let isEnabled: Bool
    let isDeleteEnabled: Bool
    var biometrics: OathNumericKeypad.Biometrics? = nil
    var errorMessage: String? = nil
    var isPresented = true
    let titleIdentifier: String
    var pinsIdentifier = "passcode.dots"
    let onKey: (OathNumericKeypad.Key) -> Void

    @Environment(\.oathLocalizer) private var strings
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var feedback = OathPasscodeFeedback()
    @ScaledMetric(relativeTo: .title2) private var titleSize = 24
    @ScaledMetric(relativeTo: .largeTitle) private var keySize = OathKeypadGeometry.circularDiameter
    @ScaledMetric(relativeTo: .body) private var pinSize = 14

    var body: some View {
        GeometryReader { geometry in
            let layout = OathPasscodeLayout(size: geometry.size, preferredKeyDiameter: keySize,
                divisions: reservedFrames(in: geometry, division: true),
                occlusions: reservedFrames(in: geometry, division: false),
                rightToLeft: layoutDirection == .rightToLeft)
            ZStack(alignment: .topLeading) {
                switch layout.regions {
                case .stacked(let bounds):
                    if OathLayoutGeometry.isUsable(bounds) {
                        let contentWidth = max(layout.keypadSize.width, min(OathPasscodeLayout.maximumContentWidth,
                            max(0, bounds.width - OathPasscodeLayout.horizontalPadding * 2)))
                        ScrollView(contentWidth + OathPasscodeLayout.horizontalPadding * 2 > bounds.width
                                   ? [.vertical, .horizontal] : .vertical) {
                            VStack(spacing: 0) {
                                Spacer(minLength: 28)
                                introduction
                                Spacer(minLength: 36)
                                keypad(size: layout.keypadSize)
                                Spacer(minLength: 28)
                            }
                            .frame(width: contentWidth)
                            .frame(minHeight: max(0, bounds.height - OathPasscodeLayout.verticalPadding * 2))
                            .padding(.horizontal, OathPasscodeLayout.horizontalPadding)
                            .padding(.vertical, OathPasscodeLayout.verticalPadding)
                            .frame(minWidth: bounds.width)
                        }
                        .scrollIndicators(.hidden)
                        .scrollBounceBehavior(.basedOnSize)
                    }
                case .split(let introductionRegion, let keypadRegion):
                    if OathLayoutGeometry.isUsable(introductionRegion) {
                        ScrollView {
                            introduction
                                .frame(maxWidth: OathPasscodeLayout.maximumContentWidth)
                                .padding(.vertical, OathPasscodeLayout.verticalPadding)
                                .frame(maxWidth: .infinity)
                                .frame(minHeight: introductionRegion.height)
                        }
                        .scrollIndicators(.hidden)
                        .scrollBounceBehavior(.basedOnSize)
                        .frame(width: introductionRegion.width, height: introductionRegion.height)
                        .position(x: introductionRegion.midX, y: introductionRegion.midY)
                    }
                    if OathLayoutGeometry.isUsable(keypadRegion) {
                        ScrollView(layout.keypadSize.width > keypadRegion.width ? [.vertical, .horizontal] : .vertical) {
                            keypad(size: layout.keypadSize)
                                .padding(.vertical, OathPasscodeLayout.verticalPadding)
                                .frame(minWidth: keypadRegion.width, minHeight: keypadRegion.height)
                        }
                        .scrollIndicators(.hidden)
                        .scrollBounceBehavior(.basedOnSize)
                        .frame(width: keypadRegion.width, height: keypadRegion.height)
                        .position(x: keypadRegion.midX, y: keypadRegion.midY)
                    }
                }
            }
        }
        .foregroundStyle(.primary)
        .tint(.primary)
        .onChange(of: errorMessage) { _, message in
            guard let message, isPresented, scenePhase == .active else {
                feedback.reset()
                return
            }
            // One event drives the red pins, shake and native error haptic.
            feedback.reject()
            OathHaptics.shared.play(.error)
            UIAccessibility.post(notification: .announcement, argument: message)
        }
        .task(id: feedback.revision) {
            guard feedback.isRejecting else { return }
            let revision = feedback.revision
            do { try await Task.sleep(for: OathPasscodeFeedback.holdDuration) }
            catch { return }
            guard !Task.isCancelled else { return }
            feedback.finish(revision: revision)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { feedback.reset() }
        }
        .onChange(of: isPresented) { _, presented in
            if !presented { feedback.reset() }
        }
        .onDisappear { feedback.reset() }
    }

    private var introduction: some View {
        VStack(spacing: 28) {
            OathPasscodeLockIcon()
            ZStack {
                // Measure both setup prompts using the actual localized fonts.
                // Set/Confirm can wrap differently; the keypad must not jump.
                if let alternatePrompt {
                    prompt(title: alternatePrompt.title, detail: alternatePrompt.detail, isPlaceholder: true)
                        .hidden()
                        .accessibilityHidden(true)
                }
                prompt(title: title, detail: detail)
                    .id(title)
                    .transition(.blurReplace)
            }
            .animation(reduceMotion ? nil : .smooth(duration: 0.35), value: title)
            pins.padding(.top, 2)
        }
    }

    private func prompt(title: String, detail: String?, isPlaceholder: Bool = false) -> some View {
        VStack(spacing: 6) {
            Text(title)
                .oathFont(.title2, size: titleSize, alreadyScaled: true)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier(isPlaceholder ? "" : titleIdentifier)
            ZStack {
                // Reserve the error subtitle at its actual localized size so
                // entering a wrong PIN never moves the keypad under a finger.
                Text(strings.text(alternatePrompt == nil ? .unlockIncorrect : .mismatch))
                    .hidden().accessibilityHidden(true)
                if let detail { Text(detail).hidden().accessibilityHidden(true) }
                if let message = errorMessage ?? detail {
                    Text(message)
                        .foregroundStyle(errorMessage == nil ? Color.secondary : Color.red)
                        .accessibilityIdentifier(isPlaceholder ? "" : pinsIdentifier + ".message")
                }
            }
            .oathFont(.body)
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var pins: some View {
        HStack(spacing: 22) {
            ForEach(0..<length, id: \.self) { index in
                Image(systemName: index < displayedCount ? "circle.fill" : "circle")
                    .font(.system(size: min(pinSize, 20), weight: .regular))
                    .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
            }
        }
        .foregroundStyle(errorMessage == nil ? Color.primary : Color.red)
        .animation(reduceMotion ? nil : .snappy(duration: 0.16), value: displayedCount)
        .keyframeAnimator(initialValue: 0.0, trigger: feedback.revision) { [reduceMotion] content, offset in
            content.offset(x: reduceMotion ? 0 : offset)
        } keyframes: { _ in
            CubicKeyframe(-9, duration: 0.07)
            CubicKeyframe(9, duration: 0.07)
            CubicKeyframe(-6, duration: 0.07)
            CubicKeyframe(6, duration: 0.07)
            CubicKeyframe(0, duration: 0.1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(strings.text(.passcode))
        .accessibilityValue(errorMessage ?? strings.format(.pinCount, strings.number(filledCount), strings.number(length)))
        .accessibilityIdentifier(pinsIdentifier)
    }

    private func keypad(size: CGSize) -> some View {
        OathNumericKeypad(isEnabled: isEnabled && !feedback.isRejecting,
                         isDeleteEnabled: isDeleteEnabled, biometrics: biometrics) { key in
            guard isEnabled, !feedback.isRejecting else { return }
            onKey(key)
        }
            .frame(width: size.width, height: size.height)
    }

    private var displayedCount: Int { feedback.isRejecting ? length : filledCount }

    private func reservedFrames(in geometry: GeometryProxy, division: Bool) -> [CGRect] {
        #if canImport(SwiftUI, _version: 8.0.85.27)
        if #available(iOS 27.1, *) {
            return geometry.reservedRegions(kind: division ? .division : .occlusion,
                                           layoutDirectionBehavior: .fixed)
                .filter(\.isActive).map(\.frame)
        }
        #endif
        return []
    }
}
