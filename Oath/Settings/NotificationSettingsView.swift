import SwiftUI

struct NotificationSettingsView: View {
    @Environment(WalletSettingsStore.self) private var settings
    @Environment(PushNotificationCoordinator.self)
    private var pushNotifications

    var body: some View {
        List {
            Group {
                Section {
                    Toggle(isOn: masterPreference) {
                        Text("settings.notifications.enable")
                    }
                } footer: {
                    Text("settings.notifications.privacy.footer")
                }

                Section("settings.notifications.categories") {
                    Toggle(isOn: receivedPreference) {
                        Text("settings.notifications.received")
                    }

                    Toggle(isOn: sentPreference) {
                        Text("settings.notifications.sent")
                    }

                    Toggle(isOn: adminPreference) {
                        Text("settings.notifications.admin")
                    }
                }
                .disabled(!settings.notificationsEnabled)
            }
            .walletListRowSurface()
        }
        .walletListAppearance()
        .listStyle(.insetGrouped)
        .navigationTitle("settings.notifications.title")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await pushNotifications.appDidBecomeActive(
                settings: settings
            )
        }
    }

    private var masterPreference: Binding<Bool> {
        Binding(
            get: { settings.notificationsEnabled },
            set: { enabled in
                UniHaptic.play(.toggle)
                Task {
                    if enabled {
                        _ = await pushNotifications.enableNotifications(
                            settings: settings
                        )
                    } else {
                        await pushNotifications.disableNotifications(
                            settings: settings
                        )
                    }
                }
            }
        )
    }

    private var receivedPreference: Binding<Bool> {
        Binding(
            get: {
                settings.receivedTransactionNotificationsEnabled
            },
            set: { enabled in
                UniHaptic.play(.toggle)
                settings.setReceivedTransactionNotificationsEnabled(
                    enabled
                )
                Task {
                    await pushNotifications.preferencesDidChange(
                        settings: settings
                    )
                }
            }
        )
    }

    private var sentPreference: Binding<Bool> {
        Binding(
            get: {
                settings.sentTransactionNotificationsEnabled
            },
            set: { enabled in
                UniHaptic.play(.toggle)
                settings.setSentTransactionNotificationsEnabled(enabled)
                Task {
                    await pushNotifications.preferencesDidChange(
                        settings: settings
                    )
                }
            }
        )
    }

    private var adminPreference: Binding<Bool> {
        Binding(
            get: { settings.adminNotificationsEnabled },
            set: { enabled in
                UniHaptic.play(.toggle)
                settings.setAdminNotificationsEnabled(enabled)
                Task {
                    await pushNotifications.preferencesDidChange(
                        settings: settings
                    )
                }
            }
        )
    }
}
