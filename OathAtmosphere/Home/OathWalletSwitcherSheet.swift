import OathDiagnostics
import SwiftUI
import OathDatabase

struct OathWalletSwitcherSheet: View {
    let session: OathWalletSession
    let onImport: () -> Void
    let onImportPrivateKey: () -> Void
    let onCreated: (String) -> Void
    let onCustomize: (String) -> Void
    let onWalletSettings: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.oathLocalizer) private var strings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var restoresFromICloud = false
    @State private var restore = OathCloudRestoreModel()
    @State private var work: Task<Void, Never>?
    @State private var pendingWalletID: String?
    @State private var createRequestID = UUID()
    @State private var failed = false
    @State private var balances = OathWalletListBalances()

    var body: some View {
        OathContentSizedSheet(contentID: "\(restoresFromICloud)-\(restore.selected?.id ?? "list")-\(restore.busy)", navigation: .init(
            strings: strings, title: restoresFromICloud ? .restoreICloud : .wallets,
            backIdentifier: "wallets.back",
            onBack: restoresFromICloud ? {
                if restore.selected != nil { restore.backToList() }
                else { restore.stop(); restoresFromICloud = false }
            } : nil,
            onClose: { dismiss() }, actionsEnabled: work == nil && restore.phase != .saving
        )) {
            Group {
                if restoresFromICloud {
                    if restore.selected != nil {
                        OathCloudRestorePasswordPage(model: restore) { restored in
                            try await session.restoreWallet(restored)
                            try Task.checkCancellation()
                            dismiss()
                        }
                    } else {
                        OathCloudRestoreList(model: restore, onChoose: restore.choose)
                    }
                } else {
                    walletList
                }
            }
            .id(restoresFromICloud)
            .transition(.blurReplace)
            .padding(.vertical, 12)
            .fixedSize(horizontal: false, vertical: true)
        }
        .animation(reduceMotion ? nil : .smooth, value: restoresFromICloud)
        .interactiveDismissDisabled(work != nil || restore.phase == .saving)
        .oathHapticFeedback(.error, trigger: failed, when: failed)
        .alert(strings.text(.walletChangeFailed), isPresented: $failed) {
            if #available(iOS 26.0, *) {
                OathButton(role: .confirm) {}
                    .accessibilityLabel(strings.text(.done))
                    .accessibilityIdentifier("confirmation.done")
                    .oathConfirmationControl()
            } else {
                OathButton(strings.text(.done)) {}
                    .accessibilityIdentifier("confirmation.done")
                    .oathConfirmationControl()
            }
        } message: {
            Text(strings.text(.walletChangeFailedDetail))
        }
        .onDisappear { work?.cancel(); work = nil; restore.stop() }
        .task(id: restoresFromICloud ? [] : balances.scope(session: session)) {
            if !restoresFromICloud { await balances.observe(session: session) }
        }
        .onChange(of: session.isUnlocked) { _, unlocked in
            if !unlocked { restore.stop() }
            else if restoresFromICloud { restore.start() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { restore.stop() }
            else if phase == .active, restoresFromICloud, session.isUnlocked { restore.start() }
        }
    }

    private var walletList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(session.wallets, id: \.id) { wallet in
                OathButton {
                    guard let id = UUID(uuidString: wallet.id) else { return }
                    pendingWalletID = wallet.id
                    run { try await session.selectWallet(id) }
                } label: {
                    OathWalletListRow(wallet: wallet, session: session, balances: balances,
                                      showsDisclosure: false,
                                      isWorking: work != nil && pendingWalletID == wallet.id)
                }
                .buttonStyle(OathSettingsRowButtonStyle())
                .accessibilityIdentifier("wallets.select.\(wallet.id)")
                .contextMenu {
                    OathButton {
                        openWallet(wallet.id, using: onCustomize)
                    } label: {
                        Label(strings.text(.customizeWallet), systemImage: "paintpalette")
                    }
                    .accessibilityIdentifier("wallets.customize.\(wallet.id)")
                    OathButton {
                        openWallet(wallet.id, using: onWalletSettings)
                    } label: {
                        Label(strings.text(.walletDetails), systemImage: "slider.horizontal.3")
                    }
                    .accessibilityIdentifier("wallets.settings.\(wallet.id)")
                }
            }
            OathSettingsSectionRule()
            OathWalletActions(identifier: "wallets", isCreating: work != nil && pendingWalletID == nil,
                onCreate: { pendingWalletID = nil; createWallet() },
                onImport: onImport, onImportPrivateKey: onImportPrivateKey,
                onRestore: { restoresFromICloud = true; restore.start() })
        }
        .disabled(work != nil || session.changingWallet || !session.isUnlocked)
        .accessibilityIdentifier("wallets.list")
    }

    private func openWallet(_ id: String, using action: (String) -> Void) {
        guard work == nil, session.isUnlocked, !session.changingWallet,
              session.wallets.contains(where: { $0.id == id }) else { return }
        action(id)
    }

    private func createWallet() {
        guard work == nil else { return }
        work = Task {
            defer { work = nil }
            do {
                let id = try await session.addWallet(requestID: createRequestID)
                guard !Task.isCancelled, session.isUnlocked else { return }
                onCreated(id)
            } catch is CancellationError { }
            catch { OathDiagnostics.record(error); if !Task.isCancelled, session.isUnlocked { failed = true } }
        }
    }

    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        guard work == nil else { return }
        work = Task {
            defer { work = nil }
            do {
                try await action()
                guard !Task.isCancelled, session.isUnlocked else { return }
                dismiss()
            } catch is CancellationError { }
            catch { OathDiagnostics.record(error); if !Task.isCancelled, session.isUnlocked { failed = true } }
        }
    }
}

/// Additional wallets inherit the existing app lock. Reuse the full validated
/// phrase editor and scanner without asking the user to set another passcode.
struct OathAdditionalWalletImportPage: View {
    let session: OathWalletSession
    var scannedPhrase: OathValidatedMnemonic? = nil
    @State private var didSeedScan = false
    let onImported: (String) -> Void
    @Environment(\.oathLocalizer) private var strings
    @State private var draft = OathRecoveryPhraseDraft()
    @State private var requestID = UUID()
    @State private var work: Task<Void, Never>?
    @State private var failed = false

    var body: some View {
        OathRecoveryPhraseScreen(draft: draft, isImporting: work != nil, onImport: importPhrase)
        .onAppear { if !didSeedScan { didSeedScan = true; if let scannedPhrase { draft.replace(with: scannedPhrase.phrase) } } }
        .oathHapticFeedback(.error, trigger: failed, when: failed)
        .alert(strings.text(.walletChangeFailed), isPresented: $failed) {
            if #available(iOS 26.0, *) {
                OathButton(role: .confirm) {}
                    .accessibilityLabel(strings.text(.done))
                    .accessibilityIdentifier("confirmation.done")
                    .oathConfirmationControl()
            } else {
                OathButton(strings.text(.done)) {}
                    .accessibilityIdentifier("confirmation.done")
                    .oathConfirmationControl()
            }
        } message: {
            Text(strings.text(.walletChangeFailedDetail))
        }
        .overlay {
            if work != nil { ProgressView().accessibilityLabel(strings.text(.importAction)) }
        }
        .navigationBarBackButtonHidden(work != nil)
        .oathNativeLocalization()
        .interactiveDismissDisabled(work != nil)
        .onChange(of: draft.text) { _, _ in
            if work == nil { requestID = UUID() }
        }
        .onDisappear { work?.cancel(); work = nil }
        // A scanner temporarily covers this view. Keep its draft intact while
        // scanning; clear on explicit close/success, or release with the cover.
    }

    private func importPhrase(_ phrase: OathValidatedMnemonic) {
        guard work == nil else { return }
        work = Task {
            defer { work = nil }
            do {
                let id = try await session.addWallet(requestID: requestID, importing: phrase)
                guard !Task.isCancelled, session.isUnlocked else { return }
                draft.clear()
                onImported(id)
            } catch is CancellationError { }
            catch { OathDiagnostics.record(error); if !Task.isCancelled, session.isUnlocked { failed = true } }
        }
    }
}

/// The switcher hands off after its sheet has dismissed. Import and Customize
/// share one full-screen native navigation stack; no PIN setup is repeated.
enum OathAdditionalWalletDestination: Identifiable {
    case importPhrase, importPrivateKey, customize(String)
    var id: String {
        switch self {
        case .importPhrase: "import"
        case .importPrivateKey: "import-private-key"
        case .customize(let id): "customize-" + id
        }
    }
}

struct OathAdditionalWalletFlow: View {
    let session: OathWalletSession
    let start: OathAdditionalWalletDestination
    var scannedPhrase: OathValidatedMnemonic? = nil
    var scannedPrivateKey: String? = nil
    @Environment(\.dismiss) private var dismiss
    @Environment(\.oathLocalizer) private var strings
    private enum Route: Hashable { case privateKey(OathPrivateKeyChoice), customize(String) }
    @State private var path: [Route] = []

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                switch start {
                case .importPhrase:
                    OathAdditionalWalletImportPage(session: session, scannedPhrase: scannedPhrase) { id in path.append(.customize(id)) }
                        .toolbar {
                            ToolbarItem(placement: .topBarLeading) {
                                OathCloseButton { dismiss() }
                                    .disabled(session.changingWallet)
                                    .accessibilityIdentifier("options.close")
                            }
                        }
                case .importPrivateKey:
                    OathChooseChainScreen { path.append(.privateKey($0)) }
                        .toolbar {
                            ToolbarItem(placement: .topBarLeading) {
                                OathCloseButton { dismiss() }
                                    .accessibilityIdentifier("options.close")
                            }
                        }
                case .customize(let id): customize(id)
                }
            }
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .customize(let id): customize(id)
                case .privateKey(let choice):
                    OathPrivateKeyImportScreen(choice: choice, isAllowed: session.isUnlocked, scannedKey: scannedPrivateKey) { key, requestID in
                        let id = try await session.addWallet(requestID: requestID, privateKey: key)
                        try Task.checkCancellation()
                        if session.isUnlocked { path.append(.customize(id)) }
                    }
                }
            }
        }
        .interactiveDismissDisabled()
        .onChange(of: session.isUnlocked) { _, unlocked in
            // A vault commit can precede a background lock. Resume its existing
            // wallet after authentication instead of repeating the import.
            guard unlocked, let id = session.pendingCustomizationID, !path.contains(.customize(id)) else { return }
            switch start {
            case .importPhrase, .importPrivateKey: path.append(.customize(id))
            case .customize: break
            }
        }
    }

    private func customize(_ id: String) -> some View {
        OathWalletCustomizationScreen(session: session, walletID: id, mode: .setup) { dismiss() }
            .oathWalletCustomizationNavigation()
            .navigationBarBackButtonHidden()
    }
}
