import SwiftUI
import UIKit

enum PasscodeEntryControlLayout {
    static let direction = WalletNumericKeypadLayout.direction
}

enum PasscodePromptTypography {
    static let title = WalletTypography.title(.title2)
    static let subtitle = Font.subheadline
}

enum PasscodeStepReplacementPosition: Equatable, Sendable {
    case entry
    case intermediate
    case confirmation

    var insertionEdge: Edge {
        switch self {
        case .entry:
            .leading
        case .intermediate, .confirmation:
            .trailing
        }
    }

    var removalEdge: Edge {
        switch self {
        case .entry, .intermediate:
            .leading
        case .confirmation:
            .trailing
        }
    }

    var transition: AnyTransition {
        .asymmetric(
            insertion: .move(edge: insertionEdge),
            removal: .move(edge: removalEdge)
        )
    }
}

struct PINSetupFlowView: View {
    let onPasscodeConfirmed: @MainActor (String) async -> Void

    private enum Step {
        case enter
        case confirm
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var step: Step = .enter
    @State private var firstPIN = ""
    @State private var entryIdentity = UUID()
    @State private var mismatchMessage: String?
    @State private var isConfirmed = false
    @State private var completionTask: Task<Void, Never>?

    private let pinLength = PasscodeDraft.requiredLength

    var body: some View {
        ZStack {
            WalletBackground()

            PasscodeResponsiveContainer {
                PINCodeEntryView(
                    length: pinLength,
                    isEnabled: !isConfirmed,
                    resetID: entryIdentity,
                    errorMessage: mismatchMessage,
                    errorFeedbackID: mismatchMessage == nil
                        ? nil
                        : entryIdentity,
                    showsStaticLock: true,
                    replacementIdentity: step == .enter
                        ? "set"
                        : "confirm",
                    replacementPosition: step == .enter
                        ? .entry
                        : .confirmation,
                    prompt: {
                        PINStepHeader(
                            title: step == .enter
                                ? "passcode.title.set"
                                : "passcode.title.confirm",
                            message: step == .enter
                                ? EnglishNumbers.localized(
                                    "passcode.message.set",
                                    pinLength
                                )
                                : WalletLocalization.string(
                                    "passcode.message.confirm"
                                )
                        )
                    },
                    onComplete: handleCompletedPIN
                )
            }
        }
        .navigationTitle("passcode.navigation.set")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(isConfirmed)
        .onDisappear {
            completionTask?.cancel()
            completionTask = nil
            firstPIN = ""
            step = .enter
            mismatchMessage = nil
            isConfirmed = false
            entryIdentity = UUID()
        }
    }

    private func handleCompletedPIN(_ pin: String) {
        switch step {
        case .enter:
            UniHaptic.play(.passcodeComplete)
            replaceState {
                firstPIN = pin
                mismatchMessage = nil
                step = .confirm
                entryIdentity = UUID()
            }
        case .confirm:
            if PasscodeConfirmation.matches(
                confirmation: pin,
                original: firstPIN
            ) {
                UniHaptic.play(.passcodeComplete)
                let confirmedPIN = pin
                replaceState {
                    firstPIN = ""
                    isConfirmed = true
                    entryIdentity = UUID()
                }
                completionTask = Task { @MainActor in
                    await PasscodeKeyboard.dismissBeforeTransition()
                    guard !Task.isCancelled else { return }
                    await onPasscodeConfirmed(confirmedPIN)
                }
            } else {
                restartPINSetup(
                    errorMessage: WalletLocalization.string(
                        "passcode.error.mismatch"
                    )
                )
            }
        }
    }

    private func restartPINSetup(errorMessage: String? = nil) {
        replaceState {
            firstPIN = ""
            mismatchMessage = errorMessage
            isConfirmed = false
            step = .enter
            entryIdentity = UUID()
        }
    }

    private func replaceState(_ updates: () -> Void) {
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.32)) {
            updates()
        }
    }
}

struct PasscodeResponsiveContainer<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        GeometryReader { proxy in
            let compactHeight = proxy.size.height < 720
            let verticalPadding: CGFloat = compactHeight ? 8 : 24

            content()
                .frame(maxWidth: 760, maxHeight: .infinity)
                .padding(.vertical, verticalPadding)
                .frame(
                    width: proxy.size.width,
                    height: proxy.size.height
                )
        }
    }
}

struct PINStepHeader: View {
    let title: LocalizedStringKey
    let message: String

    var body: some View {
        VStack(spacing: 0) {
            Text(title)
                .font(PasscodePromptTypography.title)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)

            Text(message)
                .font(PasscodePromptTypography.subtitle)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12)
        }
        .frame(maxWidth: .infinity)
    }
}

struct PasscodeAuthenticationHeader: View {
    let title: LocalizedStringKey
    let message: LocalizedStringKey

    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: "lock")
                .font(
                    .system(
                        size: 34,
                        weight: WalletSFSymbol.weight
                    )
                )
                .foregroundStyle(WalletTheme.ink)
                .accessibilityHidden(true)

            Text(title)
                .font(PasscodePromptTypography.title)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 22)

            Text(message)
                .font(PasscodePromptTypography.subtitle)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct PINSetupLockSymbol: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isVisible = false

    var body: some View {
        ZStack {
            if isVisible {
                Image(systemName: "lock")
                    .font(.system(size: 34, weight: WalletSFSymbol.weight))
                    .foregroundStyle(WalletTheme.ink)
                    .transition(
                        .symbolEffect(
                            .appear.up.wholeSymbol,
                            options: .nonRepeating
                        )
                    )
                    .symbolEffectsRemoved(reduceMotion)
                    .accessibilityHidden(true)
            }
        }
        .frame(width: 40, height: 40)
        .padding(.bottom, 22)
        .task {
            await Task.yield()
            withAnimation(reduceMotion ? nil : .smooth(duration: 0.32)) {
                isVisible = true
            }
        }
    }
}

struct PasscodeSlidingReplacement<Content: View>: View {
    let identity: String
    let position: PasscodeStepReplacementPosition
    @ViewBuilder let content: () -> Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            content()
                .frame(maxWidth: .infinity)
                .id(identity)
                .transition(
                    reduceMotion
                        ? .identity
                        : position.transition
                )
        }
        .frame(maxWidth: .infinity)
        .clipped()
        .animation(
            reduceMotion ? nil : .smooth(duration: 0.32),
            value: identity
        )
    }
}

struct PINCodeEntryView: View {
    struct KeypadAction {
        let systemImageName: String
        let accessibilityLabelKey: String
        let action: () -> Void
    }

    let length: Int
    let isEnabled: Bool
    let onComplete: (String) -> Void

    private let prompt: AnyView?
    private let leadingKeypadAction: KeypadAction?
    private let resetID: UUID?
    private let errorMessage: String?
    private let errorFeedbackID: UUID?
    private let isLockedOut: Bool
    private let lockoutRemainingSeconds: Int?
    private let showsStaticLock: Bool
    private let replacementIdentity: String?
    private let replacementPosition: PasscodeStepReplacementPosition

    @State private var input: PasscodeInputBuffer
    @State private var handledErrorFeedbackID: UUID?
    @State private var isShowingErrorIndicators = false
    @State private var errorShakePhase: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .title3)
    private var accessoryIconSize: CGFloat = 26
    private let digits = [
        "1", "2", "3",
        "4", "5", "6",
        "7", "8", "9"
    ]

    init(
        length: Int,
        isEnabled: Bool,
        leadingKeypadAction: KeypadAction? = nil,
        resetID: UUID? = nil,
        errorMessage: String? = nil,
        errorFeedbackID: UUID? = nil,
        isLockedOut: Bool = false,
        lockoutRemainingSeconds: Int? = nil,
        showsStaticLock: Bool = false,
        replacementIdentity: String? = nil,
        replacementPosition: PasscodeStepReplacementPosition = .entry,
        onComplete: @escaping (String) -> Void
    ) {
        self.length = length
        self.isEnabled = isEnabled
        self.leadingKeypadAction = leadingKeypadAction
        self.resetID = resetID
        self.errorMessage = errorMessage
        self.errorFeedbackID = errorFeedbackID
        self.isLockedOut = isLockedOut
        self.lockoutRemainingSeconds = lockoutRemainingSeconds
        self.showsStaticLock = showsStaticLock
        self.replacementIdentity = replacementIdentity
        self.replacementPosition = replacementPosition
        self.onComplete = onComplete
        _input = State(
            initialValue: PasscodeInputBuffer(length: length)
        )
        prompt = nil
    }

    init<Prompt: View>(
        length: Int,
        isEnabled: Bool,
        leadingKeypadAction: KeypadAction? = nil,
        resetID: UUID? = nil,
        errorMessage: String? = nil,
        errorFeedbackID: UUID? = nil,
        isLockedOut: Bool = false,
        lockoutRemainingSeconds: Int? = nil,
        showsStaticLock: Bool = false,
        replacementIdentity: String? = nil,
        replacementPosition: PasscodeStepReplacementPosition = .entry,
        @ViewBuilder prompt: () -> Prompt,
        onComplete: @escaping (String) -> Void
    ) {
        self.length = length
        self.isEnabled = isEnabled
        self.leadingKeypadAction = leadingKeypadAction
        self.resetID = resetID
        self.errorMessage = errorMessage
        self.errorFeedbackID = errorFeedbackID
        self.isLockedOut = isLockedOut
        self.lockoutRemainingSeconds = lockoutRemainingSeconds
        self.showsStaticLock = showsStaticLock
        self.replacementIdentity = replacementIdentity
        self.replacementPosition = replacementPosition
        self.onComplete = onComplete
        _input = State(
            initialValue: PasscodeInputBuffer(length: length)
        )
        self.prompt = AnyView(prompt())
    }

    var body: some View {
        GeometryReader { proxy in
            let metrics = PasscodeLayoutMetrics(
                size: proxy.size,
                dynamicTypeSize: dynamicTypeSize
            )

            Group {
                if metrics.usesHorizontalLayout {
                    horizontalLayout(metrics)
                } else {
                    verticalLayout(metrics)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("passcode.accessibility.label"))
        .accessibilityValue(accessibilityProgress)
        .onChange(of: resetID) { _, _ in
            input.reset()
        }
        .onChange(of: errorMessage) { _, message in
            if message == nil {
                isShowingErrorIndicators = false
            }
        }
        .onChange(of: errorFeedbackID) { _, _ in
            presentErrorFeedbackIfNeeded()
        }
        .onChange(of: isLockedOut) { _, lockedOut in
            guard lockedOut else { return }
            input.reset()
            isShowingErrorIndicators = false
        }
        .onAppear {
            presentErrorFeedbackIfNeeded()
        }
    }

    private func verticalLayout(
        _ metrics: PasscodeLayoutMetrics
    ) -> some View {
        VStack(spacing: 0) {
            Spacer(minLength: metrics.minimumSpacer)

            promptAndFeedback(metrics)

            Spacer(minLength: metrics.minimumSpacer)

            keypad(metrics)
        }
    }

    private func horizontalLayout(
        _ metrics: PasscodeLayoutMetrics
    ) -> some View {
        HStack(spacing: metrics.sectionSpacing) {
            promptAndFeedback(metrics)
                .frame(maxWidth: .infinity)

            keypad(metrics)
        }
    }

    private func promptAndFeedback(
        _ metrics: PasscodeLayoutMetrics
    ) -> some View {
        VStack(spacing: 0) {
            if showsStaticLock {
                PINSetupLockSymbol()
            }

            replacementStepContent(metrics)

            PasscodeFeedbackSlot(
                message: errorMessage,
                height: metrics.feedbackRegionHeight,
                countdownSeconds: lockoutRemainingSeconds
            )
            .padding(
                .horizontal,
                metrics.contentHorizontalPadding
            )
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func replacementStepContent(
        _ metrics: PasscodeLayoutMetrics
    ) -> some View {
        if let replacementIdentity {
            PasscodeSlidingReplacement(
                identity: replacementIdentity,
                position: replacementPosition
            ) {
                stepContent(metrics)
            }
        } else {
            stepContent(metrics)
        }
    }

    private func stepContent(
        _ metrics: PasscodeLayoutMetrics
    ) -> some View {
        VStack(spacing: 0) {
            if let prompt {
                prompt
            }

            indicatorRow(metrics)
        }
        .padding(.horizontal, metrics.contentHorizontalPadding)
        .frame(maxWidth: .infinity)
    }

    private func indicatorRow(
        _ metrics: PasscodeLayoutMetrics
    ) -> some View {
        HStack(spacing: metrics.indicatorSpacing) {
            ForEach(0..<length, id: \.self) { index in
                ZStack {
                    Circle()
                        .strokeBorder(
                            isLockedOut
                                ? WalletTheme.disabledControlLabel.opacity(0.42)
                                : isShowingErrorIndicators
                                ? WalletTheme.danger
                                : WalletTheme.secondaryLabel.opacity(0.42),
                            lineWidth: 1.5
                        )

                    if index < input.value.count {
                        filledIndicator(
                            isError: isShowingErrorIndicators
                        )
                    }
                }
                .frame(
                    width: metrics.indicatorSize,
                    height: metrics.indicatorSize
                )
            }
        }
        .walletNumericKeypadLayout()
        .modifier(
            PasscodeErrorShakeEffect(
                animatableData: errorShakePhase
            )
        )
        .padding(
            .top,
            prompt == nil ? 0 : metrics.indicatorTopPadding
        )
        .animation(
            reduceMotion ? nil : .smooth(duration: 0.18),
            value: input.value.count
        )
        .accessibilityHidden(true)
    }

    private func filledIndicator(isError: Bool) -> some View {
        Circle()
            .fill(
                isLockedOut
                    ? WalletTheme.disabledControlLabel
                    : isError ? WalletTheme.danger : WalletTheme.ink
            )
    }

    private func keypad(
        _ metrics: PasscodeLayoutMetrics
    ) -> some View {
        LazyVGrid(
            columns: [
                GridItem(
                    .flexible(),
                    spacing: metrics.columnSpacing,
                    alignment: .center
                ),
                GridItem(
                    .flexible(),
                    spacing: metrics.columnSpacing,
                    alignment: .center
                ),
                GridItem(
                    .flexible(),
                    spacing: metrics.columnSpacing,
                    alignment: .center
                )
            ],
            spacing: metrics.rowSpacing
        ) {
            ForEach(digits, id: \.self) { digit in
                digitButton(digit, metrics: metrics)
            }

            if let leadingKeypadAction {
                keypadActionButton(
                    leadingKeypadAction,
                    metrics: metrics
                )
            } else {
                Color.clear
                    .frame(
                        width: metrics.keypadButtonDiameter,
                        height: metrics.keypadButtonDiameter
                    )
                    .accessibilityHidden(true)
            }

            digitButton("0", metrics: metrics)

            Button(action: UniHaptic.action {
                deleteLastDigit()
            }) {
                ZStack {
                    Color.clear

                    Image(systemName: "delete.left")
                        .font(
                            .system(
                                size: accessoryIconSize,
                                weight: WalletSFSymbol.weight
                            )
                        )
                        .minimumScaleFactor(0.7)
                }
                .frame(
                    width: metrics.keypadButtonDiameter,
                    height: metrics.keypadButtonDiameter
                )
                .contentShape(Circle())
            }
            .buttonStyle(PasscodeKeypadAccessoryButtonStyle())
            .contentShape(Circle())
            .disabled(!isEnabled || input.value.isEmpty)
            .accessibilityLabel(
                Text("passcode.keypad.delete")
            )
        }
        .frame(maxWidth: metrics.keypadWidth)
        .walletNumericKeypadLayout()
    }

    private func digitButton(
        _ digit: String,
        metrics: PasscodeLayoutMetrics
    ) -> some View {
        Button(action: UniHaptic.action {
            appendDigit(digit)
        }) {
            ZStack {
                Color.clear

                Text(verbatim: digit)
                    .font(PasscodeKeypadDesign.digitFont)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            .frame(
                width: metrics.keypadButtonDiameter,
                height: metrics.keypadButtonDiameter
            )
            .contentShape(Circle())
        }
        .buttonStyle(PasscodeKeypadButtonStyle())
        .contentShape(Circle())
        .disabled(
            !isEnabled
                || input.hasSubmitted
                || input.value.count >= length
        )
        .accessibilityLabel(Text(verbatim: digit))
    }

    private func keypadActionButton(
        _ action: KeypadAction,
        metrics: PasscodeLayoutMetrics
    ) -> some View {
        Button(action: UniHaptic.action(action.action)) {
            ZStack {
                Color.clear

                Image(systemName: action.systemImageName)
                    .font(
                        .system(
                            size: accessoryIconSize,
                            weight: WalletSFSymbol.weight
                        )
                    )
                    .minimumScaleFactor(0.7)
            }
            .frame(
                width: metrics.keypadButtonDiameter,
                height: metrics.keypadButtonDiameter
            )
            .contentShape(Circle())
        }
        .buttonStyle(PasscodeKeypadAccessoryButtonStyle())
        .contentShape(Circle())
        .disabled(!isEnabled)
        .accessibilityLabel(
            Text(LocalizedStringKey(action.accessibilityLabelKey))
        )
    }

    private func appendDigit(_ digit: String) {
        guard isEnabled else { return }
        let previousCount = input.value.count
        let completedPasscode = input.append(digit)
        guard input.value.count > previousCount else { return }
        isShowingErrorIndicators = false
        UniHaptic.play(.passcodeDigit)
        if let completedPasscode {
            onComplete(completedPasscode)
        }
    }

    private func deleteLastDigit() {
        guard isEnabled, input.deleteLastDigit() else { return }
        UniHaptic.play(.passcodeDelete)
    }

    private var accessibilityProgress: String {
        EnglishNumbers.localized(
            "passcode.accessibility.progress",
            input.value.count,
            length
        )
    }

    private func presentErrorFeedbackIfNeeded() {
        guard let errorFeedbackID,
              errorMessage != nil,
              handledErrorFeedbackID != errorFeedbackID else {
            return
        }

        handledErrorFeedbackID = errorFeedbackID
        input.reset()
        isShowingErrorIndicators = true
        UniHaptic.play(.passcodeError)

        guard !reduceMotion else { return }
        withAnimation(.linear(duration: 0.42)) {
            errorShakePhase += 1
        }
    }
}

struct PasscodeInputBuffer: Equatable, Sendable {
    let length: Int
    private(set) var value = ""
    private(set) var hasSubmitted = false

    init(length: Int) {
        self.length = max(length, 1)
    }

    mutating func append(_ digit: String) -> String? {
        guard !hasSubmitted,
              value.count < length,
              digit.count == 1,
              let character = digit.first,
              character.isASCII,
              character >= "0",
              character <= "9" else {
            return nil
        }

        value.append(character)
        guard value.count == length else { return nil }
        hasSubmitted = true
        return value
    }

    @discardableResult
    mutating func deleteLastDigit() -> Bool {
        guard !hasSubmitted, !value.isEmpty else { return false }
        value.removeLast()
        return true
    }

    mutating func reset() {
        value = ""
        hasSubmitted = false
    }
}

private enum PasscodeKeypadDesign {
    static let digitFont = Font.system(.title, weight: .medium)
    static let digitSurface = WalletTheme.keypadSurface
    static let digitPressedOpacity = 0.72
    static let accessoryPressedOpacity = 0.55
}

private struct PasscodeKeypadButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(
                isEnabled
                    ? WalletTheme.primaryLabel
                    : WalletTheme.disabledControlLabel
            )
            .background {
                Circle()
                    .fill(PasscodeKeypadDesign.digitSurface)
            }
            .opacity(
                configuration.isPressed
                    ? PasscodeKeypadDesign.digitPressedOpacity
                    : 1
            )
    }
}

private struct PasscodeKeypadAccessoryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(
                isEnabled
                    ? WalletTheme.primaryLabel
                    : WalletTheme.disabledControlLabel
            )
            .opacity(
                configuration.isPressed
                    ? PasscodeKeypadDesign.accessoryPressedOpacity
                    : 1
            )
    }
}

private struct PasscodeLayoutMetrics {
    let size: CGSize
    let dynamicTypeSize: DynamicTypeSize

    var usesHorizontalLayout: Bool {
        size.width > size.height && size.height < 600
    }

    var keypadWidth: CGFloat {
        if !usesHorizontalLayout {
            let availableWidth = max(132, size.width - 40)
            return min(referenceKeypadWidth, availableWidth)
        }

        let horizontalShare = size.width * 0.44
        return max(
            min(referenceKeypadWidth, horizontalShare),
            min(132, horizontalShare)
        )
    }

    var keypadButtonDiameter: CGFloat {
        max(
            44,
            (referenceKeypadWidth - (columnSpacing * 2)) / 3 - 10
        )
    }

    private var referenceKeypadWidth: CGFloat {
        let proposedWidth: CGFloat
        if usesHorizontalLayout {
            proposedWidth = dynamicTypeSize.isAccessibilitySize ? 204 : 260
        } else if dynamicTypeSize.isAccessibilitySize {
            if size.height >= 620 {
                proposedWidth = 260
            } else {
                proposedWidth = 224
            }
        } else if size.height >= 620 {
            proposedWidth = 348
        } else {
            proposedWidth = 280
        }

        return min(proposedWidth, size.width)
    }

    var contentHorizontalPadding: CGFloat {
        size.width < 350 ? 16 : 28
    }

    var columnSpacing: CGFloat {
        if usesHorizontalLayout { return 10 }
        return size.height >= 620 ? 22 : 12
    }

    var rowSpacing: CGFloat {
        if usesHorizontalLayout { return 8 }
        return size.height >= 620 ? 18 : 10
    }

    var minimumSpacer: CGFloat {
        if size.height >= 800 { return 24 }
        if size.height >= 680 { return 16 }
        return 8
    }

    var sectionSpacing: CGFloat {
        dynamicTypeSize.isAccessibilitySize ? 12 : 24
    }

    var indicatorTopPadding: CGFloat {
        if usesHorizontalLayout { return 18 }
        if size.height >= 800 { return 42 }
        if size.height >= 680 { return 28 }
        return 16
    }

    var indicatorSpacing: CGFloat {
        size.width < 350 ? 12 : 18
    }

    var indicatorSize: CGFloat {
        dynamicTypeSize.isAccessibilitySize ? 16 : 18
    }

    var feedbackRegionHeight: CGFloat {
        if dynamicTypeSize.isAccessibilitySize {
            return size.width < 400 ? 148 : 124
        }
        return size.width < 350 ? 78 : 68
    }
}

@MainActor
enum PasscodeKeyboard {
    static func dismissBeforeTransition() async {
        await Task.yield()
    }
}

#Preview("Set Passcode") {
    NavigationStack {
        PINSetupFlowView(onPasscodeConfirmed: { _ in })
    }
}
