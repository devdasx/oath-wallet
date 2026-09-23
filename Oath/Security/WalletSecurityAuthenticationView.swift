import SwiftUI

struct WalletAuthenticationGrant: Sendable {
    private enum Method: Sendable {
        case protectionDisabled
        case passcode
        case biometrics
    }

    private let method: Method
    private let expiresAt: Date

    private init(method: Method) {
        self.method = method
        expiresAt = Date().addingTimeInterval(30)
    }

    fileprivate static func protectionDisabled() -> Self {
        Self(method: .protectionDisabled)
    }

    fileprivate static func passcode() -> Self {
        Self(method: .passcode)
    }

    fileprivate static func biometrics() -> Self {
        Self(method: .biometrics)
    }

    func permits(settings: WalletSecuritySettings) -> Bool {
        guard Date() <= expiresAt else { return false }
        switch method {
        case .protectionDisabled:
            return !settings.requiresAuthentication
        case .passcode:
            return settings.requiresAuthentication
        case .biometrics:
            return settings.allowsBiometricAuthentication
        }
    }
}

struct WalletAuthenticationPasscodeContext: Sendable {
    let settings: WalletSecuritySettings
    let initialErrorKey: String?
}

enum WalletAuthenticationActionPreparation: Sendable {
    case authorized(WalletAuthenticationGrant)
    case requiresPasscode(WalletAuthenticationPasscodeContext)
    case cancelled
}

@MainActor
enum WalletAuthenticationAction {
    static func preparePasscodeOnly(
        settings: WalletSecuritySettings
    ) -> WalletAuthenticationActionPreparation {
        guard settings.requiresAuthentication else {
            return .authorized(.protectionDisabled())
        }
        return .requiresPasscode(
            WalletAuthenticationPasscodeContext(
                settings: settings,
                initialErrorKey: nil
            )
        )
    }

    static func prepare(
        settings: WalletSecuritySettings,
        purpose: WalletSecurityAuthenticationPurpose
    ) async -> WalletAuthenticationActionPreparation {
        let preparation = await prepareAuthentication(settings: settings, purpose: purpose)
        return await finish(preparation) {
            try await WalletAuthenticationPresentationReadiness().wait()
        }
    }

    static func finish(
        _ preparation: WalletAuthenticationActionPreparation,
        waitForPresentation: @MainActor () async throws -> Void
    ) async -> WalletAuthenticationActionPreparation {
        guard !Task.isCancelled else { return .cancelled }
        if case .cancelled = preparation { return .cancelled }
        do {
            try await waitForPresentation()
            try Task.checkCancellation()
            return preparation
        } catch {
            return .cancelled
        }
    }

    private static func prepareAuthentication(
        settings: WalletSecuritySettings,
        purpose: WalletSecurityAuthenticationPurpose
    ) async -> WalletAuthenticationActionPreparation {
        let availability = WalletBiometricAuthenticator.shared
            .availability()
        switch WalletAuthenticationRequirementPolicy.requirement(
            settings: settings,
            availability: availability
        ) {
        case .none:
            return .authorized(.protectionDisabled())
        case .passcode:
            return .requiresPasscode(
                WalletAuthenticationPasscodeContext(
                    settings: settings,
                    initialErrorKey:
                        settings.allowsBiometricAuthentication
                        ? "security.authentication.biometric.unavailable"
                        : nil
                )
            )
        case .biometrics:
            break
        }

        do {
            try await WalletBiometricAuthenticator.shared.authenticate(
                reason: WalletLocalization.string(
                    purpose.biometricReasonKey
                ),
                source: purpose.diagnosticSource
            )
            UniHaptic.play(.success)
            return resolveBiometricResult(.success(()), settings: settings)
        } catch let error as WalletBiometricAuthenticationError {
            if error == .unavailable || error == .unsuccessful {
                UniHaptic.play(.error)
            }
            return resolveBiometricResult(.failure(error), settings: settings)
        } catch is CancellationError {
            return .cancelled
        } catch {
            UniHaptic.play(.error)
            return resolveBiometricResult(
                .failure(.unsuccessful),
                settings: settings
            )
        }
    }

    static func resolveBiometricResult(
        _ result: Result<Void, WalletBiometricAuthenticationError>,
        settings: WalletSecuritySettings
    ) -> WalletAuthenticationActionPreparation {
        switch result {
        case .success:
            return .authorized(.biometrics())
        case .failure(.fallbackRequested):
            return .requiresPasscode(
                WalletAuthenticationPasscodeContext(
                    settings: settings,
                    initialErrorKey: nil
                )
            )
        case .failure(.unavailable):
            return .requiresPasscode(
                WalletAuthenticationPasscodeContext(
                    settings: settings,
                    initialErrorKey:
                        "security.authentication.biometric.unavailable"
                )
            )
        case .failure(.unsuccessful):
            return .requiresPasscode(
                WalletAuthenticationPasscodeContext(
                    settings: settings,
                    initialErrorKey:
                        "security.authentication.biometric.error"
                )
            )
        case .failure(.cancelled):
            return .requiresPasscode(
                WalletAuthenticationPasscodeContext(
                    settings: settings,
                    initialErrorKey: nil
                )
            )
        case .failure(.interrupted),
             .failure(.busy):
            return .requiresPasscode(
                WalletAuthenticationPasscodeContext(
                    settings: settings,
                    initialErrorKey:
                        "security.authentication.biometric.unavailable"
                )
            )
        }
    }
}

struct WalletSecurityAuthenticationView: View {
    let database: WalletDatabase
    let settings: WalletSecuritySettings
    let purpose: WalletSecurityAuthenticationPurpose
    let beginsWithPasscode: Bool
    let allowsBiometricFallback: Bool
    let onAuthenticationGranted: (WalletAuthenticationGrant) -> Void

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.walletLaunchSplashFinished) private var launchSplashFinished
    @StateObject private var lockout = PasscodeLockoutCountdownModel()
    @State private var availability = WalletBiometricAvailability(
        isAvailable: false,
        kind: .generic
    )
    @State private var effectiveSettings: WalletSecuritySettings?
    @State private var entryPresentation:
        WalletAuthenticationEntryPresentation
    @State private var policyLoadFailed = false
    @State private var policyRetryID = 0
    @State private var didResolvePolicy = false
    @State private var isAuthenticating = false
    @State private var entryIdentity = UUID()
    @State private var errorMessage: String?
    @State private var errorFeedbackID: UUID?

    init(
        database: WalletDatabase,
        settings: WalletSecuritySettings,
        purpose: WalletSecurityAuthenticationPurpose,
        beginsWithPasscode: Bool = false,
        allowsBiometricFallback: Bool = true,
        initialErrorKey: String? = nil,
        onAuthenticated: @escaping () -> Void
    ) {
        self.database = database
        self.settings = settings
        self.purpose = purpose
        self.beginsWithPasscode = beginsWithPasscode
        self.allowsBiometricFallback = allowsBiometricFallback
        onAuthenticationGranted = { _ in onAuthenticated() }
        _effectiveSettings = State(initialValue: nil)
        _entryPresentation = State(
            initialValue: beginsWithPasscode
                ? .passcode
                : .biometricPrompt
        )
        _errorMessage = State(
            initialValue: initialErrorKey.map {
                WalletLocalization.string($0)
            }
        )
    }

    init(
        database: WalletDatabase,
        settings: WalletSecuritySettings,
        purpose: WalletSecurityAuthenticationPurpose,
        beginsWithPasscode: Bool = false,
        allowsBiometricFallback: Bool = true,
        initialErrorKey: String? = nil,
        onAuthenticationGranted: @escaping (
            WalletAuthenticationGrant
        ) -> Void
    ) {
        self.database = database
        self.settings = settings
        self.purpose = purpose
        self.beginsWithPasscode = beginsWithPasscode
        self.allowsBiometricFallback = allowsBiometricFallback
        self.onAuthenticationGranted = onAuthenticationGranted
        _effectiveSettings = State(initialValue: nil)
        _entryPresentation = State(
            initialValue: beginsWithPasscode
                ? .passcode
                : .biometricPrompt
        )
        _errorMessage = State(
            initialValue: initialErrorKey.map {
                WalletLocalization.string($0)
            }
        )
    }

    var body: some View {
        Group {
            if policyLoadFailed {
                VStack(spacing: 16) {
                    Text("security.authentication.unavailable")
                        .multilineTextAlignment(.center)
                    Button("common.retry") {
                        policyLoadFailed = false
                        didResolvePolicy = false
                        policyRetryID += 1
                    }
                }
                .padding()
            } else if let effectiveSettings,
               effectiveSettings.requiresAuthentication {
                if entryPresentation == .passcode || isAppUnlock {
                    authenticationContent
                } else {
                    AppBiometricPrivacyCover()
                }
            } else if isAppUnlock {
                // The passcode surface stays behind Face ID. The older logo
                // cover looked like a second splash and interrupted the reveal.
                authenticationContent
            } else {
                AppBiometricPrivacyCover()
            }
        }
        .task(id: AuthenticationStartID(retry: policyRetryID, launchReady: launchSplashFinished)) {
            // Starting Face ID while the splash is animating makes the scene
            // inactive and cancels its task. Wait for the reveal, keeping the
            // wallet locked and the existing navigation hierarchy mounted.
            guard launchSplashFinished, scenePhase == .active else { return }
            guard !didResolvePolicy else { return }
            didResolvePolicy = true

            let resolvedSettings: WalletSecuritySettings
            do {
                resolvedSettings =
                    try await database.walletSecuritySettings()
            } catch {
                // A failed settings read neither grants access nor invents an
                // enabled passcode policy. Retry before presenting any challenge.
                policyLoadFailed = true
                return
            }
            guard resolvedSettings.requiresAuthentication else {
                effectiveSettings = resolvedSettings
                await Task.yield()
                guard !Task.isCancelled else { return }
                onAuthenticationGranted(.protectionDisabled())
                return
            }

            availability = WalletBiometricAuthenticator.shared.availability()
            await refreshLockoutState()
            effectiveSettings = resolvedSettings
            guard !beginsWithPasscode else {
                entryPresentation = .passcode
                return
            }
            isAuthenticating = true
            let preparation = await WalletAuthenticationAction.prepare(
                settings: resolvedSettings,
                purpose: purpose
            )
            isAuthenticating = false
            apply(preparation)
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            if launchSplashFinished, !didResolvePolicy {
                policyRetryID += 1
            }
            Task {
                await refreshLockoutState()
            }
        }
    }

    private struct AuthenticationStartID: Equatable {
        let retry: Int
        let launchReady: Bool
    }

    private var isAppUnlock: Bool {
        if case .appUnlock = purpose { return true }
        return false
    }

    private var authenticationContent: some View {
        ZStack {
            WalletBackground()

            PasscodeResponsiveContainer {
                PINCodeEntryView(
                    length: 6,
                    isEnabled: isPasscodeEntryEnabled,
                    leadingKeypadAction: biometricKeypadAction,
                    resetID: entryIdentity,
                    errorMessage: presentedErrorMessage,
                    errorFeedbackID: errorFeedbackID,
                    isLockedOut: lockout.isLockedOut,
                    lockoutRemainingSeconds: lockout.remainingSeconds,
                    prompt: {
                        PasscodeAuthenticationHeader(
                            title: purpose.titleKey,
                            message: purpose.messageKey
                        )
                    },
                    onComplete: verifyPasscode
                )
            }
        }
    }

    private var resolvedSettings: WalletSecuritySettings {
        effectiveSettings ?? .secureDefault
    }

    private var isPasscodeEntryEnabled: Bool {
        lockout.hasResolvedState
            && !lockout.isLockedOut
            && !isAuthenticating
    }

    private var presentedErrorMessage: String? {
        guard let seconds = lockout.remainingSeconds else {
            return errorMessage
        }
        return PasscodeLockoutMessageFormatter.message(
            remainingSeconds: seconds
        )
    }

    private var biometricKeypadAction:
        PINCodeEntryView.KeypadAction? {
        guard allowsBiometricFallback,
              resolvedSettings.allowsBiometricAuthentication,
              availability.isAvailable else {
            return nil
        }
        return PINCodeEntryView.KeypadAction(
            systemImageName: availability.kind.systemImageName,
            accessibilityLabelKey: availability.kind.unlockActionKey
        ) {
            Task {
                await authenticateWithBiometrics()
            }
        }
    }

    private func verifyPasscode(_ passcode: String) {
        guard !lockout.isLockedOut else { return }
        isAuthenticating = true
        errorMessage = nil
        errorFeedbackID = nil
        Task {
            do {
                let result = try await database.authenticatePasscode(passcode)
                switch result {
                case .success:
                    UniHaptic.play(.success)
                    await PasscodeKeyboard.dismissBeforeTransition()
                    onAuthenticationGranted(.passcode())
                case .incorrect:
                    showError(
                        WalletLocalization.string(
                            "security.authentication.passcode.error"
                        )
                    )
                case let .locked(until):
                    showLockout(until: until)
                }
            } catch {
                showError(
                    WalletLocalization.string(
                        "security.authentication.unavailable"
                    )
                )
            }
        }
    }

    @MainActor
    private func authenticateWithBiometrics() async {
        guard !isAuthenticating else { return }
        isAuthenticating = true
        errorMessage = nil
        errorFeedbackID = nil
        let preparation = await WalletAuthenticationAction.prepare(
            settings: resolvedSettings,
            purpose: purpose
        )
        isAuthenticating = false
        apply(preparation)
    }

    @MainActor
    private func apply(
        _ preparation: WalletAuthenticationActionPreparation
    ) {
        switch preparation {
        case let .authorized(grant):
            onAuthenticationGranted(grant)
        case let .requiresPasscode(context):
            availability = WalletBiometricAuthenticator.shared
                .availability()
            errorMessage = lockout.isLockedOut
                ? nil
                : context.initialErrorKey.map {
                    WalletLocalization.string($0)
                }
            errorFeedbackID = nil
            entryIdentity = UUID()
            entryPresentation = .passcode
        case .cancelled:
            errorMessage = nil
            errorFeedbackID = nil
            entryIdentity = UUID()
            entryPresentation = .passcode
        }
    }

    private func showError(_ message: String) {
        isAuthenticating = false
        errorMessage = message
        let feedbackID = UUID()
        entryIdentity = feedbackID
        errorFeedbackID = feedbackID
    }

    private func showLockout(until deadline: Date) {
        isAuthenticating = false
        errorMessage = nil
        let feedbackID = UUID()
        entryIdentity = feedbackID
        errorFeedbackID = feedbackID
        lockout.begin(until: deadline)
    }

    @MainActor
    private func refreshLockoutState() async {
        await lockout.refresh(from: database)
        guard lockout.isLockedOut else { return }
        errorMessage = nil
        errorFeedbackID = nil
        entryIdentity = UUID()
    }
}

struct WalletAuthenticationFullScreenContainer<Content: View>: View {
    let title: LocalizedStringKey
    let allowsDismissal: Bool
    private let content: Content

    @Environment(\.dismiss) private var dismiss

    init(
        title: LocalizedStringKey,
        allowsDismissal: Bool = true,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.allowsDismissal = allowsDismissal
        self.content = content()
    }

    var body: some View {
        NavigationStack {
            Group {
                content
                    .navigationTitle(title)
                    .navigationBarTitleDisplayMode(.inline)
                    .navigationBarBackButtonHidden(true)
                    .toolbar {
                        if allowsDismissal {
                            ToolbarItem(placement: .cancellationAction) {
                                WalletCloseButton {
                                    dismiss()
                                }
                            }
                        }
                    }
            }

        }
        .environment(\.walletRootBackground, WalletTheme.background)
        .background(WalletTheme.background)
        .presentationBackground(WalletTheme.background)
        .walletLocalePresentation()
        .interactiveDismissDisabled(!allowsDismissal)
    }
}
