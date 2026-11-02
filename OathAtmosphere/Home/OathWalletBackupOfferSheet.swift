import SwiftUI
import OathDatabase

/// The offer and each destination stay bound to the wallet that opened the sheet.
struct OathWalletBackupOfferSheet: View {
    let walletID: String
    let offer: WalletBackupOffer
    let cloudStatus: WalletCloudBackupStatus?
    let session: OathWalletSession
    @Environment(\.oathLocalizer) private var strings
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var step: Step = .choices
    @State private var cloud = OathCloudBackupModel()
    @State private var recovery: OathRecoveryPhraseModel

    private enum Step: Hashable { case choices, password, progress, manual }

    init(walletID: String, offer: WalletBackupOffer, cloudStatus: WalletCloudBackupStatus?, session: OathWalletSession) {
        self.walletID = walletID
        self.offer = offer
        self.cloudStatus = cloudStatus
        self.session = session
        _recovery = State(initialValue: OathRecoveryPhraseModel(walletID: walletID, reader: session.vault))
    }

    private var wallet: WalletRecord? { session.wallets.first { $0.id == walletID } }
    private var current: Bool {
        session.isUnlocked && !session.changingWallet && !session.resetting &&
            session.displayedProfile?.id.uuidString == walletID && wallet != nil
    }
    private var manualTitle: OathStringKey {
        wallet?.kind.hasSuffix("Multisig") == true ? .multisigRecovery : .showRecoveryPhrase
    }
    private var cloudOpen: Bool { step == .password || step == .progress }
    private var contentID: AnyHashable {
        if step == .manual { return AnyHashable(recovery.phase == .authenticating ? .warning : recovery.phase) }
        return AnyHashable(step)
    }
    private var navigation: OathSheetNavigationConfiguration {
        let title: OathStringKey = switch step {
        case .choices: .walletBackup
        case .password: .cloudBackupPasswordTitle
        case .progress: .cloudBackupSection
        case .manual: manualTitle
        }
        return .init(strings: strings, title: title, backIdentifier: "home.backupOffer.back",
                     onBack: step == .choices ? nil : { recovery.returnToWarning(); step = .choices },
                     onClose: { dismiss() }, actionsEnabled: current && !cloud.preparing,
                     preservesNativeButtonBackground: true, closeIdentifier: "home.backupOffer.close")
    }

    var body: some View {
        OathBackupPageLayout(contentID: contentID, navigation: navigation, avoidsKeyboard: step == .password,
                             showsActions: current && step == .manual && recovery.phase != .passcode) {
            if current { content }
        } actions: {
            if current { actions }
        }
        .presentationBackground(Color(uiColor: OathSurfaceColors.groupedCanvas))
        .interactiveDismissDisabled(cloud.preparing)
        .disabled(!current)
        .task(id: cloudOpen) {
            if cloudOpen && current { await cloud.observe(walletID: walletID) }
        }
        .onChange(of: cloudStatus, initial: true) { _, status in
            if status == .uploading && step == .password { step = .progress }
            if status == .uploaded && step != .progress {
                if step == .password { step = .choices }
                if offer == .cloudOnly { dismiss() }
            }
        }
        .onChange(of: step) { _, selection in
            if selection == .choices, offer == .cloudOnly, cloudStatus == .uploaded { dismiss() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                recovery.returnToWarning()
                if step != .progress { step = .choices }
            }
        }
        .onDisappear { recovery.returnToWarning(); cloud.cancelPreparation() }
        .accessibilityIdentifier("home.backupOffer")
    }

    @ViewBuilder private var content: some View {
        switch step {
        case .choices:
            OathBackupOfferMenu(offer: offer, cloudStatus: cloudStatus, manualTitle: manualTitle,
                onCloud: { select(cloudStatus == .uploading ? .progress : .password) },
                onManual: { select(.manual) })
        case .password:
            OathBackupPasswordForm { password in
                guard current, scenePhase == .active, step == .password, cloudStatus == .unconfirmed, !cloud.preparing else { return }
                cloud.create(walletID: walletID, password: password, vault: session.vault)
                step = .progress
            }
            .disabled(cloudStatus != .unconfirmed)
            .padding(20).frame(maxWidth: 700).frame(maxWidth: .infinity)
        case .progress: progress
        case .manual:
            switch recovery.phase {
            case .warning, .authenticating:
                OathRecoveryWarningContent(model: recovery, fitsBackupSheet: true)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("recoveryDisclosure.warning")
            case .passcode:
                OathRecoveryPasscodePage(model: recovery, session: session)
                    .environment(\.oathFitsPasscodeSheet, true)
            case .revealed:
                OathRecoveryWordsContent(model: recovery, session: session)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("recoveryDisclosure.words")
            }
        }
    }

    @ViewBuilder private var actions: some View {
        if step == .manual {
            switch recovery.phase {
            case .warning, .authenticating: OathRecoveryWarningAction(model: recovery, session: session)
            case .revealed: OathRecoveryWordsAction(model: recovery, session: session)
            case .passcode: EmptyView()
            }
        }
    }

    private func select(_ destination: Step) {
        guard current, step == .choices else { return }
        step = destination
    }

    private var progress: some View {
        VStack(spacing: 16) {
            if let failure = cloud.failure ?? cloud.record?.failureCode {
                Text(strings.text(OathCloudBackupSection.message(failure)))
                OathActionButton(title: strings.text(.tryAgain), appearance: .secondary) {
                    if cloud.record?.enabled == true, cloud.record?.encryptedDocument != nil {
                        cloud.retry(walletID: walletID)
                    } else { step = .password }
                }
            } else if !cloud.preparing && cloud.record?.state == "uploaded" {
                Label(strings.text(.cloudBackupComplete), systemImage: "checkmark.icloud")
            } else {
                if let percent = cloud.record?.percent, percent > 0 {
                    ProgressView(value: percent, total: 100)
                } else { ProgressView() }
                Text(strings.text(cloud.preparing ? .cloudBackupEncrypting : .cloudBackupUploading))
                if !cloud.preparing, cloud.record != nil {
                    Text(strings.text(.cloudBackupWaiting)).oathFont(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .oathFont(.body).multilineTextAlignment(.center).padding(24)
        .frame(maxWidth: 600).frame(maxWidth: .infinity)
    }
}

struct OathBackupOfferMenu: View {
    let offer: WalletBackupOffer
    let cloudStatus: WalletCloudBackupStatus?
    let manualTitle: OathStringKey
    let onCloud: () -> Void
    let onManual: () -> Void
    @Environment(\.oathLocalizer) private var strings

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 12) {
                Image(systemName: "externaldrive.badge.timemachine")
                    .font(.largeTitle)
                    .foregroundStyle(OathOnboardingColors.blue)
                    .accessibilityHidden(true)
                Text(strings.text(.backupOfferTitle))
                    .oathFont(.title2, weight: .semibold)
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                Text(strings.text(.backupOfferDetail))
                    .oathFont(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .padding(20)
            if let choices = cloudStatus?.visibleOffer(for: offer), choices != .manualOnly {
                choice(.cloudBackupSwitch, icon: "lock.icloud", action: onCloud)
                if choices == .cloudOrManual { OathSettingsSectionRule() }
            }
            if offer != .cloudOnly {
                choice(.backupManually, icon: "text.alignleft", subtitle: strings.text(manualTitle), action: onManual)
            }
        }.frame(maxWidth: 700).frame(maxWidth: .infinity)
    }

    private func choice(_ title: OathStringKey, icon: String, subtitle: String? = nil, action: @escaping () -> Void) -> some View {
        OathButton(action: action) {
            OathSettingsRow(title: strings.text(title), icon: icon, subtitle: subtitle)
        }.buttonStyle(OathSettingsRowButtonStyle())
    }
}

/// One host owns the detent for the entire offer. Only its measured content,
/// navigation items and pinned actions change when the user chooses a step.
struct OathBackupPageLayout<Content: View, Actions: View>: View {
    let contentID: AnyHashable
    let navigation: OathSheetNavigationConfiguration
    var avoidsKeyboard = false
    var showsActions = true
    @ViewBuilder let content: () -> Content
    @ViewBuilder let actions: () -> Actions
    @State private var footerHeight: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        OathContentSizedSheet(contentID: contentID, avoidsKeyboard: avoidsKeyboard, navigation: navigation,
                              opaqueBackground: true, bottomActionHeight: showsActions ? footerHeight : 0) {
            // Fade the incoming step without keeping the outgoing password
            // or recovery view around while UIKit animates the fitted height.
            content()
                .fixedSize(horizontal: false, vertical: true)
                .keyframeAnimator(initialValue: 1.0, trigger: contentID) { [reduceMotion] view, opacity in
                    view.opacity(reduceMotion ? 1 : opacity)
                } keyframes: { _ in
                    MoveKeyframe(0.0)
                    SpringKeyframe(1.0, spring: .smooth)
                }
        }
        .oathBottomActions(isPresented: showsActions, onHeightChange: { footerHeight = $0 }, content: actions)
    }
}
