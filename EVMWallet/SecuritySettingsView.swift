import SwiftUI

struct SecuritySettingsView: View {
    let database: WalletDatabase
    let isDeviceMigrationAuthorizationInProgress: Bool
    let onDeviceMigrationRequested: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var settings: WalletSecuritySettings
    @State private var biometricAvailability =
        WalletBiometricAvailability(isAvailable: false, kind: .generic)
    @State private var isUpdating = false
    @State private var isPasscodeSetupPresented = false
    @State private var isPasscodeChangePresented = false
    @State private var isDisablePasscodeWarningPresented = false
    @State private var alertMessage: String?

    init(
        database: WalletDatabase,
        initialSettings: WalletSecuritySettings,
        isDeviceMigrationAuthorizationInProgress: Bool = false,
        onDeviceMigrationRequested: @escaping () -> Void = {}
    ) {
        self.database = database
        self.isDeviceMigrationAuthorizationInProgress =
            isDeviceMigrationAuthorizationInProgress
        self.onDeviceMigrationRequested = onDeviceMigrationRequested
        _settings = State(initialValue: initialSettings)
    }

    var body: some View {
        List {
            Group {
                Section {
                    Button(action: UniHaptic.action {
                        if settings.requiresAuthentication {
                            UniHaptic.play(.warning)
                            isDisablePasscodeWarningPresented = true
                        } else {
                            UniHaptic.play(.commit)
                            isPasscodeSetupPresented = true
                        }
                    }) {
                        Text(
                            LocalizedStringKey(
                                settings.requiresAuthentication
                                    ? "settings.security.app_lock.turn_off"
                                    : "settings.security.app_lock.turn_on"
                            )
                        )
                        .foregroundStyle(WalletTheme.primaryAction)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.automatic)
                    .disabled(isUpdating)

                    if settings.requiresAuthentication {
                        Button(action: UniHaptic.action(nil) {
                            isPasscodeChangePresented = true
                        }) {
                            Text("settings.security.change_passcode")
                                .foregroundStyle(WalletTheme.primaryAction)
                                .frame(
                                    maxWidth: .infinity,
                                    alignment: .leading
                                )
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.automatic)
                        .disabled(isUpdating)
                    }
                } header: {
                    Text("settings.security.app_lock.section")
                } footer: {
                    Text("settings.security.app_lock.footer")
                }

                Section {
                    Toggle(
                        isOn: Binding(
                            get: { settings.biometricEnabled },
                            set: { isEnabled in
                                UniHaptic.play(.toggle)
                                updateBiometrics(isEnabled)
                            }
                        )
                    ) {
                        Text(
                            LocalizedStringKey(
                                biometricAvailability.kind.titleKey
                            )
                        )
                    }
                    .disabled(
                        !settings.requiresAuthentication
                            || (
                                !biometricAvailability.isAvailable
                                    && !settings.biometricEnabled
                            )
                            || isUpdating
                    )
                } header: {
                    Text("settings.security.biometrics.section")
                } footer: {
                    Text(
                        LocalizedStringKey(
                            biometricAvailability.isAvailable
                                ? "settings.security.face_id.footer"
                                : "settings.security.biometrics.unavailable"
                        )
                    )
                }

                Section {
                    NavigationLink {
                        Group {
                            AutoLockSettingsView(
                                database: database,
                                initialSelection: settings.autoLockDuration
                            ) { duration in
                                replaceSettings {
                                    settings.autoLockDuration = duration
                                }
                            }
                        }

                    } label: {
                        LabeledContent("settings.security.auto_lock") {
                            Text(
                                LocalizedStringKey(
                                    settings.autoLockDuration.titleKey
                                )
                            )
                                .foregroundStyle(.secondary)
                                .id(settings.autoLockDuration)
                        }
                    }
                    .disabled(!settings.requiresAuthentication || isUpdating)
                } header: {
                    Text("settings.security.auto_lock.section")
                } footer: {
                    Text("settings.security.auto_lock.footer")
                }

                Section {
                    Toggle(
                        isOn: Binding(
                            get: { settings.privacyShieldEnabled },
                            set: { isEnabled in
                                UniHaptic.play(.toggle)
                                updatePrivacyShield(isEnabled)
                            }
                        )
                    ) {
                        Text("settings.security.privacy_screen")
                    }
                    .disabled(isUpdating)
                } header: {
                    Text("settings.security.privacy.section")
                } footer: {
                    Text("settings.security.privacy.footer")
                }

                Section {
                    Button(action: UniHaptic.action(nil, perform: onDeviceMigrationRequested)) {
                        Text("device_migration.security.action")
                            .foregroundStyle(WalletTheme.primaryLabel)
                            .frame(
                                maxWidth: .infinity,
                                alignment: .leading
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.automatic)
                    .disabled(
                        isUpdating
                            || isDeviceMigrationAuthorizationInProgress
                    )
                } header: {
                    Text("device_migration.security.section")
                } footer: {
                    Text("device_migration.security.footer")
                }
            }
            .walletListRowSurface()
        }
        .walletListAppearance()
        .listStyle(.insetGrouped)
        .navigationTitle("settings.security.title")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            biometricAvailability =
                WalletBiometricAuthenticator.shared.availability()
        }
        .fullScreenCover(
            isPresented: $isPasscodeSetupPresented,
            onDismiss: {
                Task {
                    await reloadPersistedSettings()
                }
            }
        ) {
            NavigationStack {
                Group {
                    EnablePasscodeSettingsView(database: database) {
                        replaceSettings {
                            settings.appLockEnabled = true
                            settings.biometricEnabled = false
                        }
                        isPasscodeSetupPresented = false
                    }
                }

            }
            .walletLocalePresentation()
            .interactiveDismissDisabled()
        }
        .fullScreenCover(
            isPresented: $isPasscodeChangePresented,
            onDismiss: {
                Task {
                    await reloadPersistedSettings()
                }
            }
        ) {
            WalletAuthenticationFullScreenContainer(
                title: "settings.security.change_passcode"
            ) {
                ChangePasscodeSettingsView(database: database)
            }
        }
        .alert(
            "settings.security.app_lock.disable.title",
            isPresented: $isDisablePasscodeWarningPresented
        ) {
            Button("common.cancel", role: .cancel, action: UniHaptic.action {
                UniHaptic.play(.selectionDeselect)
            })
            Button(
                "settings.security.app_lock.disable.confirm",
                role: .destructive
            , action: UniHaptic.action {
                UniHaptic.play(.consequential)
                disableAppLock()
            })
        } message: {
            Text("settings.security.app_lock.disable.message")
        }
        .alert(
            "settings.security.update.error.title",
            isPresented: Binding(
                get: { alertMessage != nil },
                set: { if !$0 { alertMessage = nil } }
            )
        ) {
            Button("common.ok", action: UniHaptic.action {})
        } message: {
            if let alertMessage {
                Text(alertMessage)
            }
        }
        .animation(
            reduceMotion ? nil : .smooth(duration: 0.22),
            value: settings
        )
    }

    @MainActor
    private func reloadPersistedSettings() async {
        guard let persisted =
            try? await database.walletSecuritySettings() else {
            return
        }
        replaceSettings {
            settings = persisted
        }
    }

    private func disableAppLock() {
        guard !isUpdating, settings.requiresAuthentication else {
            return
        }
        let previous = settings
        replaceSettings {
            settings.appLockEnabled = false
            settings.biometricEnabled = false
        }
        isUpdating = true
        Task {
            do {
                try await database.disableAppLock()
                UniHaptic.play(.successQuiet)
                isUpdating = false
            } catch {
                UniHaptic.play(.error)
                replaceSettings {
                    settings = previous
                }
                isUpdating = false
                alertMessage = WalletLocalization.string(
                    "settings.security.update.error.message"
                )
            }
        }
    }

    private func updateBiometrics(_ isEnabled: Bool) {
        guard !isUpdating, isEnabled != settings.biometricEnabled else {
            return
        }
        if !isEnabled {
            persistBiometricSetting(false)
            return
        }

        isUpdating = true
        Task {
            do {
                try await WalletBiometricAuthenticator.shared.authenticate(
                    reason: WalletLocalization.string(
                        "settings.security.biometrics.enable.reason"
                    )
                )
                try await database.setBiometricEnabled(true)
                replaceSettings {
                    settings.biometricEnabled = true
                }
                isUpdating = false
            } catch WalletBiometricAuthenticationError.cancelled {
                isUpdating = false
            } catch {
                UniHaptic.play(.error)
                isUpdating = false
                alertMessage = WalletLocalization.string(
                    "settings.security.biometrics.enable.error"
                )
            }
        }
    }

    private func persistBiometricSetting(_ isEnabled: Bool) {
        let previous = settings.biometricEnabled
        replaceSettings {
            settings.biometricEnabled = isEnabled
        }
        isUpdating = true
        Task {
            do {
                try await database.setBiometricEnabled(isEnabled)
                isUpdating = false
            } catch {
                UniHaptic.play(.error)
                replaceSettings {
                    settings.biometricEnabled = previous
                }
                isUpdating = false
                alertMessage = WalletLocalization.string(
                    "settings.security.update.error.message"
                )
            }
        }
    }

    private func updatePrivacyShield(_ isEnabled: Bool) {
        guard !isUpdating,
              isEnabled != settings.privacyShieldEnabled else {
            return
        }
        let previous = settings.privacyShieldEnabled
        replaceSettings {
            settings.privacyShieldEnabled = isEnabled
        }
        isUpdating = true
        Task {
            do {
                try await database.setPrivacyShieldEnabled(isEnabled)
                isUpdating = false
            } catch {
                UniHaptic.play(.error)
                replaceSettings {
                    settings.privacyShieldEnabled = previous
                }
                isUpdating = false
                alertMessage = WalletLocalization.string(
                    "settings.security.update.error.message"
                )
            }
        }
    }

    private func replaceSettings(_ update: () -> Void) {
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.22)) {
            update()
        }
    }
}
