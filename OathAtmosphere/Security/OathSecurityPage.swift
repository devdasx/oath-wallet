import OathDiagnostics
import SwiftUI
import LocalAuthentication

struct OathSecurityPage: View {
    let session: OathWalletSession
    let model: OathSecurityModel
    let onLockDelay: () -> Void
    @Environment(OathAppSettings.self) private var settings
    @Environment(\.oathLocalizer) private var strings
    @Environment(\.scenePhase) private var scenePhase
    @State private var biometricKind = OathBiometricKind.faceID

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                rowToggle(strings.text(.passcode), icon: "lock", value: session.security.passcodeEnabled,
                    identifier: "security.passcode") { enabled in
                    if enabled { model.enablePasscode() } else { model.begin(.disablePasscode) }
                }
                rowToggle(strings.invariant(biometricKind.name), icon: biometricKind == .faceID ? "faceid" : "touchid",
                    value: session.security.biometricsEnabled, identifier: "security.biometrics") { enabled in
                    if enabled { model.enableBiometrics(strings: strings) } else { model.disableBiometrics() }
                }
                .disabled(!session.security.passcodeEnabled)
                OathButton {
                    guard scenePhase != .background, !model.busy else { return }
                    model.begin(.changePasscode)
                } label: {
                    OathSettingsRow(title: strings.text(.changePasscode), icon: "lock.rotation")
                }
                .buttonStyle(OathSettingsRowButtonStyle())
                .disabled(!session.security.passcodeEnabled)
                .accessibilityIdentifier("security.changePasscode")
                OathButton {
                    guard scenePhase != .background, !model.busy else { return }
                    onLockDelay()
                } label: {
                    OathSettingsRow(title: strings.text(.requirePasscode), icon: "clock",
                                    value: strings.text(settings.lockDelay.title))
                }
                .buttonStyle(OathSettingsRowButtonStyle())
                .disabled(!session.security.passcodeEnabled)
                .accessibilityIdentifier("security.lockDelay")
                Text(strings.text(.lockDelayDetail))
                    .oathFont(.footnote).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24).padding(.bottom, 24)
                    .accessibilityIdentifier("security.lockDelay.detail")
                OathSettingsSectionRule()
                rowToggle(strings.text(.appSwitcherPrivacy), icon: "rectangle.on.rectangle.slash",
                    value: settings.appSwitcherPrivacy, identifier: "security.switcherPrivacy",
                    onChange: settings.selectAppSwitcherPrivacy)
                Text(strings.text(.appSwitcherPrivacyDetail))
                    .oathFont(.footnote).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24).padding(.bottom, 24)
                OathSettingsSectionRule()
                rowToggle(strings.text(.hideRecentlyDeletedInSwitcher), icon: "trash.slash",
                    value: settings.hideRecentlyDeletedInSwitcher, identifier: "security.hideRecentlyDeletedInSwitcher",
                    onChange: settings.selectHideRecentlyDeletedInSwitcher)
                Text(strings.text(.hideRecentlyDeletedInSwitcherDetail))
                    .oathFont(.footnote).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24).padding(.bottom, 24)
            }
            .padding(.vertical, 12)
            .frame(maxWidth: 700).frame(maxWidth: .infinity)
            .disabled(!session.isUnlocked)
            .oathInteractionBlocked(model.busy)
        }
        .task {
            let context = LAContext()
            _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
            if context.biometryType == .touchID { biometricKind = .touchID }
            do { try await session.refreshSecurity() }
            catch { OathDiagnostics.record(error); model.notice = .securityChangeFailed }
        }
        .alert(strings.text(.security), isPresented: Binding(
            get: { model.notice != nil && model.phase == .idle },
            set: { if !$0 && model.phase == .idle { model.notice = nil } }
        )) {
            if #available(iOS 26.0, *) {
                OathButton(role: .confirm) { model.notice = nil }
                    .accessibilityLabel(strings.text(.done))
                    .accessibilityIdentifier("confirmation.done")
                    .oathConfirmationControl()
            } else {
                OathButton(strings.text(.done)) { model.notice = nil }
                    .accessibilityIdentifier("confirmation.done")
                    .oathConfirmationControl()
            }
        }
        message: { if let notice = model.notice { Text(strings.text(notice)) } }
        .accessibilityIdentifier("security.screen")
    }

    private func rowToggle(_ title: String, icon: String, value: Bool, identifier: String,
                           onChange: @escaping @MainActor @Sendable (Bool) -> Void) -> some View {
        Toggle(isOn: Binding(get: { value }, set: { value in
            guard scenePhase != .background, !model.busy, session.isUnlocked else { return }
            onChange(value)
        })) {
            HStack(spacing: 16) {
                OathSettingsIcon(symbol: icon)
                Text(title).oathFont(.body).foregroundStyle(.primary)
            }
        }
        .oathSwitchStyle()
        .padding(.horizontal, 20).padding(.vertical, 17)
        .accessibilityIdentifier(identifier)
    }
}

struct OathLockDelayPage: View {
    @Environment(OathAppSettings.self) private var settings
    @Environment(\.oathLocalizer) private var strings
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(OathLockDelay.allCases, id: \.rawValue) { delay in
                    OathButton { settings.selectLockDelay(delay); dismiss() } label: {
                        OathSettingsRow(title: strings.text(delay.title), icon: "clock",
                                        accessory: .selection(settings.lockDelay == delay))
                    }
                    .buttonStyle(OathSettingsRowButtonStyle())
                    .accessibilityIdentifier("security.delay.\(delay.rawValue)")
                }
                Text(strings.text(.lockDelayDetail))
                    .oathFont(.footnote).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(24)
            }.frame(maxWidth: 700).frame(maxWidth: .infinity)
        }
    }
}

extension OathLockDelay {
    var title: OathStringKey {
        switch self {
        case .immediately: .lockImmediately
        case .oneMinute: .lockOneMinute
        case .fiveMinutes: .lockFiveMinutes
        case .tenMinutes: .lockTenMinutes
        }
    }
}
