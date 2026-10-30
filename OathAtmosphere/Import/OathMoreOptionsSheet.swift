import SwiftUI

struct OathMoreOptionsSheet: View {
    @Environment(OathAppSettings.self) private var languageSettings
    @Environment(\.oathLocalizer) private var strings
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @State private var screen = Screen.options
    @State private var restore = OathCloudRestoreModel()
    private let onImportPrivateKey: () -> Void
    private let onCreateMultisigWallet: () -> Void
    private let onRestore: (OathRestoredWallet) -> Void

    private enum Screen { case options, restore, languages }

    init(onImportPrivateKey: @escaping () -> Void, onCreateMultisigWallet: @escaping () -> Void,
         onRestore: @escaping (OathRestoredWallet) -> Void) {
        self.onImportPrivateKey = onImportPrivateKey
        self.onCreateMultisigWallet = onCreateMultisigWallet
        self.onRestore = onRestore
    }

    var body: some View {
        OathContentSizedSheet(contentID: "\(screen)-\(restore.selected?.id ?? "list")-\(restore.busy)", nativeScreen: nativeLanguageScreen, navigation: navigation) {
            stateContent.fixedSize(horizontal: false, vertical: true)
        }
        // Shared sheet sizing preserves native glass at partial height and
        // supplies the adaptive grouped canvas when the content fills it.
        .presentationCompactAdaptation(.sheet)
        .animation(reduceMotion ? nil : .smooth, value: screen)
        .tint(colorScheme == .dark
              ? Color(red: 0.36, green: 0.56, blue: 1)
              : Color(red: 0.12, green: 0.30, blue: 0.90))
        .interactiveDismissDisabled(restore.phase == .saving)
        .onDisappear { restore.stop() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { restore.stop() }
            else if phase == .active, screen == .restore { restore.start() }
        }
    }

    private var nativeLanguageScreen: OathSheetNativeScreen? {
        guard screen == .languages else { return nil }
        let configuration = OathLanguageSheetConfiguration(
            strings: strings,
            preference: languageSettings.preference,
            onChoose: { preference in
                languageSettings.select(preference)
                screen = .options
            },
            onBack: { screen = .options },
            onClose: { dismiss() },
            style: .settings
        )
        return OathSheetNativeScreen(id: "languages", make: {
            OathLanguageSelectionController(configuration: configuration)
        }, update: { controller in
            (controller as? OathLanguageSelectionController)?.update(configuration: configuration)
        })
    }

    private var navigation: OathSheetNavigationConfiguration {
        OathSheetNavigationConfiguration(
            strings: strings,
            title: screen == .options ? .moreOptions : .restoreICloud,
            backIdentifier: "icloud.backToOptions",
            onBack: screen == .restore ? {
                if restore.selected != nil { restore.backToList() }
                else { restore.stop(); screen = .options }
            } : nil,
            onClose: { dismiss() }, actionsEnabled: restore.phase != .saving
        )
    }

    private var stateContent: some View {
        Group {
            switch screen {
            case .options: options
            case .restore:
                if restore.selected != nil {
                    OathCloudRestorePasswordPage(model: restore) { restored in onRestore(restored) }
                } else {
                    OathCloudRestoreList(model: restore, onChoose: restore.choose)
                }
            case .languages: EmptyView()
            }
        }
        .id(screen)
        .transition(.blurReplace)
        .padding(.vertical, 12)
    }

    private var options: some View {
        VStack(spacing: 0) {
            OathButton { screen = .restore; restore.start() } label: {
                OathSettingsRow(title: strings.text(.restoreICloud), icon: "icloud")
            }
            .accessibilityIdentifier("onboarding.restoreICloud")

            OathButton(action: onImportPrivateKey) {
                OathSettingsRow(title: strings.text(.importPrivateKey), icon: "key.horizontal")
            }
            .accessibilityIdentifier("onboarding.importPrivateKey")

            if OathWalletCreationOptions.showsMultisig {
                OathButton(action: onCreateMultisigWallet) {
                    OathSettingsRow(title: strings.text(.createMultisignatureWallet), icon: "signature")
                }
                .accessibilityIdentifier("onboarding.createMultisignatureWallet")
            }

            OathSettingsSectionRule()

            OathButton { screen = .languages } label: {
                OathSettingsRow(title: strings.text(.language), icon: "globe",
                    value: languageSettings.preference == .system ? strings.text(.systemLanguage) : strings.name(of: languageSettings.language))
            }
            .accessibilityIdentifier("settings.language")
        }
        .buttonStyle(OathSettingsRowButtonStyle())
    }
}
