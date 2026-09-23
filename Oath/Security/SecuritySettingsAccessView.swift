import SwiftUI
import UIKit

typealias SettingsSecurityPasscodeContext =
    WalletAuthenticationPasscodeContext

enum SettingsSecurityDestinationPreparation: Sendable {
    case authorized(WalletSecuritySettings)
    case requiresPasscode(SettingsSecurityPasscodeContext)
    case cancelled
}

enum SettingsSecurityNavigationPresentation: Equatable, Sendable {
    case settings
    case security
    case passcode
}

enum SettingsSecurityPresentationHost: Sendable {
    case home
    case settings
}

struct SettingsSecurityNavigationState {
    private(set) var presentationHost: SettingsSecurityPresentationHost = .settings
    private(set) var isPasscodePresentationActive = false
    private(set) var isAuthorizing = false
    private(set) var activeRequestID: UUID?
    private(set) var authorizedSettings: WalletSecuritySettings?
    private(set) var passcodeContext: SettingsSecurityPasscodeContext?

    private var deferredPreparation:
        SettingsSecurityDestinationPreparation?
    private var pendingPresentation:
        SettingsSecurityNavigationPresentation?

    var isAwaitingAuthorization: Bool {
        isAuthorizing || passcodeContext != nil || deferredPreparation != nil
    }

    mutating func beginAuthorization(
        from host: SettingsSecurityPresentationHost = .settings
    ) -> UUID? {
        guard !isAwaitingAuthorization, !isPasscodePresentationActive,
              pendingPresentation == nil else { return nil }
        presentationHost = host
        let requestID = UUID()
        activeRequestID = requestID
        isAuthorizing = true
        authorizedSettings = nil
        passcodeContext = nil
        deferredPreparation = nil
        pendingPresentation = nil
        return requestID
    }

    mutating func receive(
        _ preparation: SettingsSecurityDestinationPreparation,
        requestID: UUID,
        sceneIsActive: Bool,
        sceneIsBackground: Bool = false
    ) {
        guard activeRequestID == requestID else { return }
        guard !sceneIsBackground else {
            invalidateForBackground()
            return
        }
        activeRequestID = nil
        isAuthorizing = false
        if sceneIsActive {
            apply(preparation)
        } else {
            deferredPreparation = preparation
        }
    }

    mutating func fail(requestID: UUID) {
        guard activeRequestID == requestID else { return }
        activeRequestID = nil
        isAuthorizing = false
    }

    mutating func resumeAfterInactive() {
        guard let deferredPreparation else { return }
        self.deferredPreparation = nil
        apply(deferredPreparation)
    }

    mutating func invalidateForBackground() {
        // A queued fallback has no cover to deliver onDismiss after backgrounding.
        // Keep only an already-presented passcode screen's context alive.
        if !isPasscodePresentationActive {
            passcodeContext = nil
        }
        activeRequestID = nil
        isAuthorizing = false
        deferredPreparation = nil
        pendingPresentation = nil
    }

    mutating func acceptAfterPasscode(
        sceneIsBackground: Bool = false
    ) {
        guard !sceneIsBackground else {
            invalidateForBackground()
            return
        }
        guard let context = passcodeContext else { return }
        let preparation = SettingsSecurityDestinationPreparation
            .authorized(context.settings)
        passcodeContext = nil
        apply(preparation)
    }

    mutating func passcodeAuthenticationDidDismiss() {
        isPasscodePresentationActive = false
        if passcodeContext != nil {
            cancelPasscodeAuthentication()
        }
    }

    mutating func cancelPasscodeAuthentication() {
        isPasscodePresentationActive = false
        passcodeContext = nil
        deferredPreparation = nil
        pendingPresentation = .settings
    }

    mutating func takePendingPresentation(sceneIsActive: Bool = true)
        -> SettingsSecurityNavigationPresentation? {
        // A scene activation can arrive while the authenticated passcode
        // cover is still dismissing. Present Security only after onDismiss.
        guard sceneIsActive, !isPasscodePresentationActive else { return nil }
        defer { pendingPresentation = nil }
        if pendingPresentation == .passcode {
            isPasscodePresentationActive = true
        }
        return pendingPresentation
    }

    mutating func clear() {
        isPasscodePresentationActive = false
        isAuthorizing = false
        activeRequestID = nil
        authorizedSettings = nil
        passcodeContext = nil
        deferredPreparation = nil
        pendingPresentation = nil
    }

    private mutating func apply(
        _ preparation: SettingsSecurityDestinationPreparation
    ) {
        switch preparation {
        case let .authorized(settings):
            authorizedSettings = settings
            passcodeContext = nil
            pendingPresentation = .security
        case let .requiresPasscode(context):
            authorizedSettings = nil
            passcodeContext = context
            pendingPresentation = .passcode
        case .cancelled:
            authorizedSettings = nil
            passcodeContext = nil
            pendingPresentation = .settings
        }
    }
}

@MainActor
enum SettingsSecurityAccessAuthorizer {
    static func prepare(
        settings: WalletSecuritySettings
    ) async -> SettingsSecurityDestinationPreparation {
        let preparation: SettingsSecurityDestinationPreparation
        switch await WalletAuthenticationAction.prepare(
            settings: settings,
            purpose: .settings
        ) {
        case .authorized:
            preparation = .authorized(settings)
        case let .requiresPasscode(context):
            preparation = .requiresPasscode(context)
        case .cancelled:
            return .cancelled
        }

        guard !Task.isCancelled else { return .cancelled }
        return preparation
    }
}
