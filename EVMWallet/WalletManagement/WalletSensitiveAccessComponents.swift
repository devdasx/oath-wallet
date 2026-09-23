import SwiftUI

enum WalletSensitiveContentLifecycleTrigger:
    String,
    Equatable,
    Sendable {
    case sceneInactive = "scene_inactive"
    case sceneBackground = "scene_background"
    case viewDisappeared = "view_disappeared"
}

struct WalletSensitiveContentLoadToken: Equatable, Sendable {
    fileprivate let generation: UInt64
}

struct WalletSensitiveContentProtectionTransition:
    Equatable,
    Sendable {
    let trigger: WalletSensitiveContentLifecycleTrigger
    let hadLoadedContent: Bool
    let wasAlreadyProtected: Bool
    let shouldDismissPresentation: Bool
}

struct WalletSensitiveContentLifecycleState: Equatable, Sendable {
    static let awayGracePeriod: Duration = .seconds(20)
    private(set) var isProtected = false
    private(set) var isSceneActive = true
    private(set) var hasLoadedContent = false
    private(set) var hasExpired = false
    private var generation: UInt64 = 0
    private var inactiveSince: ContinuousClock.Instant?

    var isMasked: Bool {
        isProtected || !isSceneActive
    }

    mutating func beginContentLoad()
        -> WalletSensitiveContentLoadToken? {
        guard !isProtected, isSceneActive else { return nil }
        generation &+= 1
        return WalletSensitiveContentLoadToken(generation: generation)
    }

    func canPublishContent(
        for token: WalletSensitiveContentLoadToken
    ) -> Bool {
        !isProtected
            && isSceneActive
            && token.generation == generation
    }

    @discardableResult
    mutating func contentDidLoad(
        for token: WalletSensitiveContentLoadToken
    ) -> Bool {
        guard canPublishContent(for: token) else { return false }
        hasLoadedContent = true
        return true
    }

    @discardableResult
    mutating func acceptLoadedContent() -> Bool {
        guard !isProtected, isSceneActive else { return false }
        hasLoadedContent = true
        return true
    }

    mutating func protect(
        for trigger: WalletSensitiveContentLifecycleTrigger,
        now: ContinuousClock.Instant = .now
    ) -> WalletSensitiveContentProtectionTransition {
        let transition = WalletSensitiveContentProtectionTransition(
            trigger: trigger,
            hadLoadedContent: hasLoadedContent,
            wasAlreadyProtected: isProtected,
            shouldDismissPresentation: false
        )
        isSceneActive = false
        hasLoadedContent = false
        switch trigger {
        case .sceneInactive:
            if inactiveSince == nil { inactiveSince = now }
            if transition.hadLoadedContent {
                generation &+= 1
            }
        case .sceneBackground:
            if inactiveSince == nil { inactiveSince = now }
            isProtected = true
            generation &+= 1
        case .viewDisappeared:
            isProtected = true
            generation &+= 1
        }
        return transition
    }

    @discardableResult
    mutating func resumeAfterInactive(now: ContinuousClock.Instant = .now) -> Bool {
        guard !hasExpired else { return false }
        guard !isSceneActive else { return false }
        if let inactiveSince,
           inactiveSince.duration(to: now) >= Self.awayGracePeriod {
            // A suspended app may never execute a timer. Check elapsed continuous
            // time before unmasking; the owning flow dismisses only this secret.
            hasExpired = true
            isProtected = true
            hasLoadedContent = false
            generation &+= 1
            return false
        }
        inactiveSince = nil
        isProtected = false
        isSceneActive = true
        return true
    }
}

enum WalletSceneSecurityEvent: String, Equatable, Sendable {
    case inactive
    case background
}

enum WalletSceneSecurityAction: Equatable, Sendable {
    case applyConfiguredPrivacyShield
    case lockWallet
}

struct WalletSceneSecurityTransitionPlan: Equatable, Sendable {
    let event: WalletSceneSecurityEvent
    let actions: [WalletSceneSecurityAction]

    static func make(
        event: WalletSceneSecurityEvent,
        locksImmediately: Bool
    ) -> Self {
        var actions: [WalletSceneSecurityAction] = [
            .applyConfiguredPrivacyShield
        ]
        if event == .background, locksImmediately {
            actions.append(.lockWallet)
        }
        return Self(event: event, actions: actions)
    }
}

enum WalletCoveringModalID: String, CaseIterable, Hashable, Sendable {
    case settings
    case walletSwitcherSettings = "wallet_switcher_settings"
    case receive
    case selectedReceiveAsset = "selected_receive_asset"
    case send
    case scanner
    case notificationInbox = "notification_inbox"
    case homeWalletSwitcher = "home_wallet_switcher"
    case homeWalletAdd = "home_wallet_add"
    case postCreationWalletBackup = "post_creation_wallet_backup"
    case destructiveFlow = "destructive_flow"
    case appReviewPrompt = "app_review_prompt"
}

struct WalletCoveringModalCallbacks {
    let didPresent: (WalletCoveringModalID) -> Void
    let didDismiss: (WalletCoveringModalID) -> Void

    static var noOp: Self {
        Self(
            didPresent: { _ in },
            didDismiss: { _ in }
        )
    }

    func dismissalAction(
        for id: WalletCoveringModalID
    ) -> () -> Void {
        {
            didDismiss(id)
        }
    }
}

struct WalletSensitiveLockPresentationState: Equatable, Sendable {
    private var presentedModalIDs: Set<WalletCoveringModalID> = []
    private var awaitedModalIDs: Set<WalletCoveringModalID> = []
    private(set) var isLockPending = false

    mutating func modalDidPresent(_ id: WalletCoveringModalID) {
        presentedModalIDs.insert(id)
        if isLockPending {
            awaitedModalIDs.insert(id)
        }
    }

    mutating func requestLock() -> Bool {
        awaitedModalIDs = presentedModalIDs
        guard !awaitedModalIDs.isEmpty else { return true }
        isLockPending = true
        return false
    }

    mutating func modalDidDismiss(_ id: WalletCoveringModalID) -> Bool {
        presentedModalIDs.remove(id)
        awaitedModalIDs.remove(id)
        guard isLockPending, awaitedModalIDs.isEmpty else { return false }
        isLockPending = false
        return true
    }

    mutating func reset() {
        presentedModalIDs.removeAll(keepingCapacity: false)
        didUnlock()
    }

    mutating func didUnlock() {
        // Authentication does not dismiss the user's sheets. Keep their owners
        // registered so the next lock is presented above the same hierarchy.
        awaitedModalIDs.removeAll(keepingCapacity: false)
        isLockPending = false
    }

    var hasPresentedModal: Bool {
        !presentedModalIDs.isEmpty
    }

    func isPresented(_ id: WalletCoveringModalID) -> Bool {
        presentedModalIDs.contains(id)
    }
}

extension View {
    func walletCoveringModal(
        _ id: WalletCoveringModalID,
        callbacks: WalletCoveringModalCallbacks
    ) -> some View {
        onAppear {
            callbacks.didPresent(id)
        }
    }
}

extension View {
    func walletAppLockOverlay(
        isPresented: Bool,
        database: WalletDatabase,
        settings: WalletSecuritySettings,
        onAuthenticated: @escaping () -> Void
    ) -> some View {
        // Authentication is owned by the scene, above every presentation. Keep
        // this state in each modal so secret screens defer expiry navigation
        // until the global lock is gone, without presenting another cover.
        environment(\.walletAppLockIsPresented, isPresented)
    }
}

extension EnvironmentValues {
    @Entry var walletAppLockIsPresented = false
}

extension View {
    func walletSensitiveContentMask(
        isProtected: Bool,
        requiresProtection: Bool = false
    ) -> some View {
        modifier(
            WalletSensitiveContentMaskModifier(
                isProtected: isProtected,
                requiresProtection: requiresProtection
            )
        )
    }

    func walletSensitiveValue() -> some View {
        modifier(WalletSensitiveValueModifier())
    }

    func walletSensitiveGraphic(
        cornerRadius: CGFloat = 16
    ) -> some View {
        modifier(
            WalletSensitiveGraphicModifier(
                cornerRadius: cornerRadius
            )
        )
    }
}

private struct WalletSensitiveValuesProtectedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var walletSensitiveValuesProtected: Bool {
        get { self[WalletSensitiveValuesProtectedKey.self] }
        set { self[WalletSensitiveValuesProtectedKey.self] = newValue }
    }
}

private struct WalletSensitiveContentMaskModifier: ViewModifier {
    let isProtected: Bool
    let requiresProtection: Bool

    @Environment(\.walletSensitiveValuesProtected)
    private var inheritedProtection

    @Environment(\.walletPrivacyShieldEnabled)
    private var isPrivacyShieldEnabled

    func body(content: Content) -> some View {
        content
            .environment(
                \.walletSensitiveValuesProtected,
                inheritedProtection || requiresProtection
                    || (isPrivacyShieldEnabled && isProtected)
            )
    }
}

private struct WalletSensitiveValueModifier: ViewModifier {
    @Environment(\.walletSensitiveValuesProtected)
    private var isProtected

    func body(content: Content) -> some View {
        content
            .redacted(reason: isProtected ? .placeholder : [])
            .walletPrivacySensitive()
            .accessibilityHidden(isProtected)
            .allowsHitTesting(!isProtected)
    }
}

private struct WalletSensitiveGraphicModifier: ViewModifier {
    let cornerRadius: CGFloat

    @Environment(\.walletSensitiveValuesProtected)
    private var isProtected

    func body(content: Content) -> some View {
        ZStack {
            content
                .opacity(isProtected ? 0 : 1)
                .walletPrivacySensitive()

            if isProtected {
                RoundedRectangle(
                    cornerRadius: cornerRadius,
                    style: .continuous
                )
                .fill(WalletTheme.tertiaryFill)
                .accessibilityHidden(true)
            }
        }
        .accessibilityHidden(isProtected)
        .allowsHitTesting(!isProtected)
    }
}

struct WalletPasscodeAuthenticationContent: View {
    let isVerifying: Bool
    let entryIdentity: UUID
    let errorMessage: String?
    let titleKey: LocalizedStringKey
    let messageKey: LocalizedStringKey
    let leadingKeypadAction: PINCodeEntryView.KeypadAction?
    let onComplete: (String) -> Void

    var body: some View {
        PasscodeResponsiveContainer {
            PINCodeEntryView(
                length: 6,
                isEnabled: !isVerifying,
                leadingKeypadAction: leadingKeypadAction,
                resetID: entryIdentity,
                errorMessage: errorMessage,
                errorFeedbackID: errorMessage == nil
                    ? nil
                    : entryIdentity,
                prompt: {
                    PasscodeAuthenticationHeader(
                        title: titleKey,
                        message: messageKey
                    )
                },
                onComplete: onComplete
            )
        }
        .background(WalletBackground())
    }
}
