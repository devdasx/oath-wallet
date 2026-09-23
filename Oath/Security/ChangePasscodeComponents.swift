import SwiftUI

enum PasscodeLockoutDurationComponents: Equatable, Sendable {
    case seconds(Int)
    case minutesSeconds(minutes: Int, seconds: Int)
    case hoursMinutes(hours: Int, minutes: Int)
}

enum PasscodeLockoutMessageFormatter {
    nonisolated static func components(
        for remainingSeconds: Int
    ) -> PasscodeLockoutDurationComponents {
        let totalSeconds = max(remainingSeconds, 0)

        if totalSeconds >= 60 * 60 {
            return .hoursMinutes(
                hours: totalSeconds / (60 * 60),
                minutes: (totalSeconds % (60 * 60)) / 60
            )
        }

        if totalSeconds >= 60 {
            return .minutesSeconds(
                minutes: totalSeconds / 60,
                seconds: totalSeconds % 60
            )
        }

        return .seconds(totalSeconds)
    }

    static func message(remainingSeconds: Int) -> String {
        let duration: String
        switch components(for: remainingSeconds) {
        case let .seconds(seconds):
            duration = secondUnit(seconds)
        case let .minutesSeconds(minutes, seconds):
            duration = joined(
                minuteUnit(minutes),
                secondUnit(seconds)
            )
        case let .hoursMinutes(hours, minutes):
            duration = joined(
                hourUnit(hours),
                minuteUnit(minutes)
            )
        }

        return EnglishNumbers.localized(
            "security.authentication.passcode.locked.duration",
            duration
        )
    }

    private static func secondUnit(_ value: Int) -> String {
        if value == 1 {
            return EnglishNumbers.localized(
                "security.authentication.passcode.duration.second.one",
                value
            )
        }
        return EnglishNumbers.localized(
            "security.authentication.passcode.duration.second.other",
            value
        )
    }

    private static func minuteUnit(_ value: Int) -> String {
        if value == 1 {
            return EnglishNumbers.localized(
                "security.authentication.passcode.duration.minute.one",
                value
            )
        }
        return EnglishNumbers.localized(
            "security.authentication.passcode.duration.minute.other",
            value
        )
    }

    private static func hourUnit(_ value: Int) -> String {
        if value == 1 {
            return EnglishNumbers.localized(
                "security.authentication.passcode.duration.hour.one",
                value
            )
        }
        return EnglishNumbers.localized(
            "security.authentication.passcode.duration.hour.other",
            value
        )
    }

    private static func joined(
        _ first: String,
        _ second: String
    ) -> String {
        EnglishNumbers.localized(
            "security.authentication.passcode.duration.join",
            first,
            second
        )
    }
}

@MainActor
final class PasscodeLockoutCountdownModel: ObservableObject {
    @Published private(set) var deadline: Date?
    @Published private(set) var currentDate = Date()
    @Published private(set) var hasResolvedState = false

    private var countdownTask: Task<Void, Never>?
    private var stateRevision: UInt64 = 0

    var remainingSeconds: Int? {
        guard let deadline else { return nil }
        return Self.remainingSeconds(
            until: deadline,
            at: currentDate
        )
    }

    var isLockedOut: Bool {
        remainingSeconds != nil
    }

    nonisolated static func remainingSeconds(
        until deadline: Date,
        at date: Date
    ) -> Int? {
        let interval = deadline.timeIntervalSince(date)
        guard interval > 0 else { return nil }
        return max(Int(ceil(interval)), 1)
    }

    func refresh(from database: WalletDatabase) async {
        let requestedRevision = stateRevision
        do {
            let storedDeadline = try await database
                .activePasscodeLockoutDeadline()
            guard requestedRevision == stateRevision else { return }
            apply(deadline: storedDeadline)
        } catch {
            guard requestedRevision == stateRevision else { return }
            currentDate = Date()
            hasResolvedState = true
        }
    }

    func begin(until deadline: Date) {
        stateRevision &+= 1
        apply(deadline: deadline)
    }

    private func apply(deadline proposedDeadline: Date?) {
        let now = Date()
        currentDate = now
        deadline = proposedDeadline.flatMap { $0 > now ? $0 : nil }
        hasResolvedState = true
        restartCountdown()
    }

    private func restartCountdown() {
        countdownTask?.cancel()
        countdownTask = nil
        guard deadline != nil else { return }

        countdownTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let deadline = self?.deadline else { return }
                let now = Date()
                self?.currentDate = now
                guard let seconds = Self.remainingSeconds(
                    until: deadline,
                    at: now
                ) else {
                    self?.stateRevision &+= 1
                    self?.deadline = nil
                    return
                }

                let interval = deadline.timeIntervalSince(now)
                let untilNextSecond = interval - Double(seconds - 1)
                let sleepInterval = max(
                    min(untilNextSecond, 1),
                    0.02
                )
                do {
                    try await Task.sleep(
                        for: .seconds(sleepInterval)
                    )
                } catch {
                    return
                }
            }
        }
    }
}

struct PasscodeFeedbackSlot: View {
    let message: String?
    let height: CGFloat
    let countdownSeconds: Int?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .top) {
            Color.clear
                .accessibilityHidden(true)

            if let message {
                Text(verbatim: message)
                    .font(.footnote)
                    .foregroundStyle(WalletTheme.danger)
                    .monospacedDigit()
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 14)
                    .contentTransition(
                        countdownSeconds != nil && !reduceMotion
                            ? .numericText(countsDown: true)
                            : .identity
                    )
                    .animation(
                        reduceMotion
                            ? nil
                            : .smooth(duration: 0.24),
                        value: countdownSeconds
                    )
                    .accessibilityLabel(
                        String.localizedStringWithFormat(
                            WalletLocalization.string(
                                "accessibility.error.format"
                            ),
                            message
                        )
                    )
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: height, alignment: .top)
        .transaction { transaction in
            guard countdownSeconds == nil else { return }
            transaction.animation = nil
        }
    }
}

struct PasscodeErrorShakeEffect: GeometryEffect {
    var animatableData: CGFloat

    func effectValue(size: CGSize) -> ProjectionTransform {
        let translation = 8 * sin(animatableData * .pi * 8)
        return ProjectionTransform(
            CGAffineTransform(translationX: translation, y: 0)
        )
    }
}

struct SecurityPasscodeHeader: View {
    let title: LocalizedStringKey
    let message: String
    let replacementIdentity: String?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        title: LocalizedStringKey,
        message: String,
        replacementIdentity: String? = nil
    ) {
        self.title = title
        self.message = message
        self.replacementIdentity = replacementIdentity
    }

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

            ZStack {
                replacementTitle
            }
            .font(PasscodePromptTypography.title)
            .multilineTextAlignment(.center)
            .padding(.top, 22)

            ZStack {
                replacementMessage
            }
            .font(PasscodePromptTypography.subtitle)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 12)
        }
        .animation(
            replacementIdentity == nil || reduceMotion
                ? nil
                : .smooth(duration: 0.32),
            value: replacementIdentity
        )
    }

    @ViewBuilder
    private var replacementTitle: some View {
        if replacementIdentity != nil, !reduceMotion {
            Text(title)
                .id("\(replacementIdentity ?? "static").title")
        } else {
            Text(title)
                .id("\(replacementIdentity ?? "static").title")
        }
    }

    @ViewBuilder
    private var replacementMessage: some View {
        if replacementIdentity != nil, !reduceMotion {
            Text(verbatim: message)
                .id("\(replacementIdentity ?? "static").message")
        } else {
            Text(verbatim: message)
                .id("\(replacementIdentity ?? "static").message")
        }
    }
}

struct ChangePasscodeCompleteView: View {
    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: "lock.shield")
                .font(
                    .system(
                        size: 46,
                        weight: WalletSFSymbol.weight
                    )
                )
                .foregroundStyle(WalletTheme.success)
                .accessibilityHidden(true)

            Text("settings.security.change.complete.title")
                .font(PasscodePromptTypography.title)
                .multilineTextAlignment(.center)
                .padding(.top, 24)

            Text("settings.security.change.complete.message")
                .font(PasscodePromptTypography.subtitle)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12)
        }
    }
}
