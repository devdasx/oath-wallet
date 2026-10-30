import SwiftUI
import UIKit

/// One navigation destination with two in-page entry states.
public struct OathPasscodeSetupScreen: View {
    @Environment(\.oathLocalizer) private var strings
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var model: OathPasscodeSetupModel
    @State private var dialog: Dialog?
    private let onComplete: () -> Void

    public init(onComplete: @escaping () -> Void) {
        _model = State(initialValue: OathPasscodeSetupModel(
            store: OathKeychainPasscodeStore(), biometrics: OathDeviceBiometrics()
        ))
        self.onComplete = onComplete
    }

    init(store: any OathPasscodeSaving, biometrics: any OathBiometricsEnabling,
         onComplete: @escaping () -> Void) {
        _model = State(initialValue: OathPasscodeSetupModel(store: store, biometrics: biometrics))
        self.onComplete = onComplete
    }

    public var body: some View {
        OathPasscodeEntry(title: heading,
            detail: strings.text(model.step == .set ? .setPasscodeDetail : .confirmPasscodeDetail),
            alternatePrompt: .init(title: strings.text(model.step == .set ? .confirmPasscode : .setPasscode),
                detail: strings.text(model.step == .set ? .confirmPasscodeDetail : .setPasscodeDetail)),
            filledCount: model.filledCount, length: OathPasscodeSetupModel.length,
            isEnabled: model.acceptsInput && scenePhase == .active,
            isDeleteEnabled: model.canDelete,
            errorMessage: model.notice == .mismatch ? strings.text(.mismatch) : nil,
            titleIdentifier: "passcode.title") { key in
                switch key {
                case .digit(let digit): model.enter(digit)
                case .delete: model.deleteLast()
                case .biometrics: break // Setup has no biometric shortcut.
                }
            }
        .background(Color(uiColor: OathSurfaceColors.canvas).ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color(uiColor: OathSurfaceColors.canvas), for: .navigationBar)
        .oathNativeLocalization()
        .background {
            OathPasscodeBackNavigation(isEnabled: model.canLeave) {
                if model.backButtonPressed() { dismiss() }
            }
        }
        // Entry mismatches use the shared pin animation's haptic. Keep error
        // feedback here only for storage/enrollment failures with their dialog.
        .oathHapticFeedback(.error, trigger: model.errorRevision, when: model.notice != .mismatch)
        .oathHapticFeedback(.success, trigger: model.successRevision)
        .onChange(of: model.phase) { _, _ in handleResult() }
        .onChange(of: model.notice) { _, _ in handleResult() }
        .onChange(of: model.step) { _, _ in
            UIAccessibility.post(notification: .announcement, argument: heading)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                model.resume()
                handleResult()
            } else {
                model.suspend()
            }
        }
        .onAppear {
            if scenePhase == .active {
                model.resume()
                handleResult()
            } else {
                model.suspend()
            }
        }
        .onDisappear { model.cancel() }
        .alert(dialog?.title(strings) ?? "", isPresented: Binding(
            get: { dialog != nil },
            set: { if !$0 { dismissDialog() } }
        ), presenting: dialog) { result in
            if case .notice = result {
                if #available(iOS 26.0, *) {
                    OathButton(role: .confirm) { model.acknowledgeNotice() }
                        .accessibilityLabel(strings.text(.done))
                        .accessibilityIdentifier("confirmation.done")
                        .oathConfirmationControl()
                } else {
                    OathButton(strings.text(.done)) { model.acknowledgeNotice() }
                        .accessibilityIdentifier("confirmation.done")
                        .oathConfirmationControl()
                }
            } else if case .biometrics(let kind, _) = result {
                OathButton(kind.map { strings.format(.retryBiometrics, strings.invariant($0.name)) } ?? strings.text(.tryAgain)) { model.retryBiometrics() }
                OathButton(strings.text(.usePasscode), role: .cancel) {
                    model.continueWithPasscode()
                }
            } else {
                if result != .failure(.alreadyConfigured) {
                    OathButton(strings.text(.tryAgain)) { model.retry() }
                }
                OathButton(strings.text(.close), role: .cancel) {
                    model.cancel()
                    dismiss()
                }
            }
        } message: { result in
            Text(result.message(strings))
        }
        .accessibilityIdentifier("passcode.setup")
    }

    private var heading: String { strings.text(model.step == .set ? .setPasscode : .confirmPasscode) }
    private func handleResult() {
        if model.claimCompletion(isForeground: scenePhase != .background) {
            dialog = nil
            onComplete()
            return
        }
        // Starting a new system prompt or alert still requires an active scene.
        // Delivering already successful authentication above does not.
        guard scenePhase == .active else { return }
        switch model.phase {
        case .failed(let error): dialog = .failure(error)
        case .biometricsFailed:
            if case .failed(let kind, let reason) = model.biometricResult { dialog = .biometrics(kind, reason) }
        case .entering:
            if let notice = model.notice, notice != .mismatch { dialog = .notice(notice) }
        default: break
        }
    }

    private func dismissDialog() {
        if case .notice = dialog { model.acknowledgeNotice() }
        dialog = nil
    }

    private enum Dialog: Equatable {
        case failure(OathPasscodeSaveError)
        case biometrics(OathBiometricKind?, OathBiometricSetupError)
        case notice(OathPasscodeSetupModel.Notice)

        func title(_ strings: OathLocalizer) -> String {
            switch self {
            case .failure(.alreadyConfigured): strings.text(.passcodeAlreadySet)
            case .failure(.deviceLocked): strings.text(.unlockDevice)
            case .failure: strings.text(.passcodeSaveFailed)
            case .biometrics(let kind, _): strings.format(.biometricsUnavailable, kind.map { strings.invariant($0.name) } ?? strings.text(.biometricsName))
            case .notice: strings.text(.setPasscode)
            }
        }

        func message(_ strings: OathLocalizer) -> String {
            switch self {
            case .failure(.alreadyConfigured): strings.text(.passcodeAlreadySetDetail)
            case .failure(.deviceLocked): strings.text(.unlockDeviceDetail)
            case .failure: strings.text(.passcodeSaveFailedDetail)
            case .biometrics(_, .lockedOut):
                strings.text(.biometricsLocked)
            case .biometrics(_, .storage):
                strings.text(.biometricsStorageFailed)
            case .biometrics:
                strings.text(.biometricsFailed)
            case .notice(let notice):
                strings.text(notice == .mismatch ? .mismatch : .interrupted)
            }
        }
    }
}
