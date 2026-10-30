import SwiftUI
import Observation
import OathAnkr
import OathDiagnostics

@MainActor @Observable final class OathStellarMultisigSetupModel {
    var address = ""
    var state: StellarMultisigState?
    var quote: OathStellarQuote?
    var pending = false
    var loading = false
    var sending = false
    var passcode = false
    var notice: OathStringKey?

    func refresh(session: OathWalletSession, walletID: String) async {
        guard session.isUnlocked, !loading, !sending else { return }
        loading = true; quote = nil; notice = nil
        defer { loading = false }
        do {
            let result = try await OathStellarSendService.shared.multisigSetup(walletID: walletID, vault: session.vault)
            try Task.checkCancellation()
            guard session.isUnlocked else { return }
            address = result.0; state = result.1; quote = result.2; pending = result.3
        } catch {
            if error is CancellationError || Task.isCancelled { return }
            OathDiagnostics.record(error, component: "stellar_send", operation: "multisig_setup_refresh", context: ["chain": "stellar"])
            notice = (error as? StellarSendError) == .unsupportedAccount ? .walletUnavailable : .walletUnavailable
        }
    }
    func activate(session: OathWalletSession, walletID: String, reason: String, digits: [UInt8]? = nil) {
        guard session.isUnlocked, !sending, !loading, !pending, let quote, (state?.configured == false || quote.plan.kind == .changeTrust) else { return }
        sending = true; notice = nil
        // The app-lifetime submission service journals before broadcast. Dismissal
        // never cancels or replaces an already signed permission transaction.
        Task {
            var digits = digits
            defer { if digits != nil { _ = digits!.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) } } }
            do {
                _ = try await OathStellarSendService.shared.submit(quote, vault: session.vault, digits: digits, reason: reason)
                self.quote = nil; passcode = false; pending = true; sending = false
                await refresh(session: session, walletID: walletID)
            } catch {
                sending = false
                OathDiagnostics.record(error, component: "stellar_send", operation: "multisig_setup_submit", context: ["chain": "stellar"])
                if error is OathBiometricCredentialError { passcode = true }
                else if error as? OathWalletError == .wrongPasscode { passcode = true; notice = .unlockIncorrect }
                else if case OathWalletError.throttled = error { passcode = true; notice = .unlockWait }
                else if !(error is CancellationError) { passcode = false; self.quote = nil; notice = .walletUnavailable }
            }
        }
    }
}

struct OathStellarMultisigSetupScreen: View {
    let session: OathWalletSession
    let walletID: String
    @State private var model = OathStellarMultisigSetupModel()
    @State private var showsTokenAuthorization = false
    @Environment(\.oathLocalizer) private var strings
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if model.passcode {
                OathSecretPasscodePage(session: session, busy: model.sending, notice: $model.notice,
                    title: .multisigStellarActivate, identifier: "multisig.stellar.passcode") { digits in
                    model.activate(session: session, walletID: walletID, reason: strings.text(.multisigStellarActivate), digits: digits)
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        OathSettingsRow(title: strings.text(model.state?.configured == true ? .multisigStellarReady : .multisigStellarSetup),
                            icon: model.state?.configured == true ? "checkmark.shield" : "exclamationmark.shield", accessory: .none)
                        OathSettingsFooter { Text(strings.text(model.state?.configured == true ? .multisigStellarReadyDetail : .multisigStellarSetupDetail)) }
                        if !model.address.isEmpty {
                            OathSettingsSectionRule()
                            Text(model.address).oathFont(.body).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(24)
                            OathButton {
                                OathClipboard.copy(model.address)
                            } label: {
                                OathSettingsRow(title: strings.text(.copyAddress), icon: "doc.on.doc", accessory: .none)
                            }.buttonStyle(OathSettingsRowButtonStyle())
                        }
                        if let state = model.state, !state.configured {
                            OathSettingsSectionRule()
                            OathSettingsRow(title: strings.text(.totalBalance), icon: "banknote", value: xlm(state.balance), accessory: .none)
                            OathSettingsRow(title: strings.text(.multisigStellarReserve), icon: "lock", value: xlm(state.reserve), accessory: .none)
                            OathSettingsRow(title: strings.text(.transactionNetworkFee), icon: "network", value: xlm(UInt64(model.quote?.plan.fee ?? 0)), accessory: .none)
                            OathSettingsFooter { Text(strings.text(.multisigStellarFeeDetail)) }
                        }
                        if model.state?.configured == true {
                            OathSettingsSectionRule()
                            OathButton { showsTokenAuthorization = true } label: {
                                OathSettingsRow(title: strings.text(.multisigStellarTokenAdd), icon: "plus.circle")
                            }.buttonStyle(OathSettingsRowButtonStyle())
                        }
                        if model.pending { OathSettingsFooter { Text(strings.text(.multisigStellarPending)) } }
                        if let notice = model.notice { Text(strings.text(notice)).oathFont(.footnote).foregroundStyle(.red).padding(24) }
                    }
                    .frame(maxWidth: 600).frame(maxWidth: .infinity)
                }
                .oathBottomActions {
                    if model.state?.configured != true {
                        OathBottomAction(title: strings.text(.multisigStellarActivate), identifier: "multisig.stellar.activate",
                            isEnabled: model.quote != nil && !model.pending && session.isUnlocked && scenePhase == .active,
                            isWorking: model.sending) {
                            model.activate(session: session, walletID: walletID, reason: strings.text(.multisigStellarActivate))
                        }
                    }
                }
            }
        }
        .background(Color(uiColor: OathSurfaceColors.canvas).ignoresSafeArea())
        .navigationTitle(strings.text(.multisigStellarSetup)).navigationBarTitleDisplayMode(.inline)
        .oathNativeLocalization()
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { OathCloseButton { dismiss() }.disabled(model.sending) }
            ToolbarItem(placement: .primaryAction) {
                OathButton {
                    Task { await model.refresh(session: session, walletID: walletID) }
                } label: {
                    if model.loading { ProgressView() }
                    else { Label(strings.text(.tryAgain), systemImage: "arrow.clockwise") }
                }.disabled(model.loading || model.sending || model.passcode)
            }
        }
        .sheet(isPresented: $showsTokenAuthorization) {
            NavigationStack { OathStellarTokenAuthorizationScreen(session:session,walletID:walletID) }
        }
        .task { await model.refresh(session: session, walletID: walletID) }
        .task(id: model.pending) {
            guard model.pending else { return }
            for _ in 0..<60 {
                do { try await Task.sleep(for: .seconds(4)) } catch { return }
                guard session.isUnlocked, scenePhase == .active, model.pending else { return }
                await model.refresh(session: session, walletID: walletID)
            }
        }
    }
    private func xlm(_ sun: UInt64) -> String { NSDecimalNumber(decimal: Decimal(sun) / 10_000_000).stringValue + " XLM" }
}

/// Issued assets require an explicitly authorized trustline.
private struct OathStellarTokenAuthorizationScreen: View {
    let session: OathWalletSession
    let walletID: String
    @State private var model = OathStellarMultisigSetupModel()
    @State private var currency = ""
    @State private var issuer = ""
    @Environment(\.oathLocalizer) private var strings
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
    private var ready: Bool { !currency.isEmpty && !issuer.isEmpty }
    var body: some View {
        Group {
            if model.passcode {
                OathSecretPasscodePage(session:session,busy:model.sending,notice:$model.notice,title:.multisigStellarTokenAdd,identifier:"multisig.stellar.token.passcode") { digits in
                    model.activate(session:session,walletID:walletID,reason:strings.text(.multisigStellarTokenAdd),digits:digits)
                }
            } else {
                ScrollView {
                    VStack(alignment:.leading,spacing:20) {
                        Text(strings.text(.multisigStellarTokenDetail)).oathFont(.footnote).foregroundStyle(.secondary)
                        TextField(strings.text(.multisigStellarCurrency),text:$currency).oathSettingsField()
                        TextField(strings.text(.multisigStellarIssuer),text:$issuer).oathSettingsField()
                        if let quote = model.quote {
                            Text(strings.text(.transactionNetworkFee)+": "+NSDecimalNumber(decimal:Decimal(quote.plan.fee)/10_000_000).stringValue+" XLM").oathFont(.body)
                            Text(strings.text(.multisigStellarTokenReview)).oathFont(.footnote).foregroundStyle(.secondary)
                        }
                        if model.pending { Text(strings.text(.multisigStellarPending)).oathFont(.footnote) }
                        if let notice = model.notice { Text(strings.text(notice)).oathFont(.footnote).foregroundStyle(.red) }
                    }.textInputAutocapitalization(.never).autocorrectionDisabled()
                        .disabled(model.sending || model.loading || model.pending)
                        .padding(24).frame(maxWidth:600).frame(maxWidth:.infinity)
                }
                .oathBottomActions {
                    OathBottomAction(title:strings.text(model.quote == nil ? .multisigStellarTokenReviewAction:.multisigStellarTokenAdd),identifier:"multisig.stellar.token.confirm",
                        isEnabled:ready && !model.pending && session.isUnlocked && scenePhase == .active,isWorking:model.loading || model.sending) {
                        if model.quote != nil { model.activate(session:session,walletID:walletID,reason:strings.text(.multisigStellarTokenAdd)) }
                        else { prepare() }
                    }
                }
            }
        }
        .background(Color(uiColor:OathSurfaceColors.canvas).ignoresSafeArea())
        .navigationTitle(strings.text(.multisigStellarTokenAdd)).navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement:.cancellationAction) { OathCloseButton { dismiss() }.disabled(model.sending) } }
        .oathNativeLocalization()
        .onChange(of:currency) { _,_ in model.quote=nil }
        .onChange(of:issuer) { _,_ in model.quote=nil }
        .task(id:model.pending) {
            guard model.pending else { return }
            for _ in 0..<60 {
                do { try await Task.sleep(for:.seconds(4)) } catch { return }
                guard session.isUnlocked, scenePhase == .active, model.pending else { return }
                await model.refresh(session:session,walletID:walletID)
                if !model.pending { dismiss(); return }
            }
        }
    }
    private func prepare() {
        guard ready, !model.loading, !model.sending else { return }
        let code = currency.trimmingCharacters(in: .whitespacesAndNewlines)
        let issuer = issuer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...12).contains(code.utf8.count), code.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }),
              (try? StellarIdentity.address(issuer)) == issuer else { model.notice = .multisigStellarTokenInvalid; return }
        model.loading=true;model.notice=nil
        Task {
            defer { model.loading=false }
            do {
                model.quote = try await OathStellarSendService.shared.tokenAuthorization(walletID:walletID,code:code,issuer:issuer,vault:session.vault)
                model.state = try await OathStellarSendService.shared.multisigSetup(walletID:walletID,vault:session.vault).1
            } catch {
                if error is CancellationError { return }
                OathDiagnostics.record(error,component:"stellar_send",operation:"token_authorization_review",context:["chain":"stellar"])
                model.notice = .walletUnavailable
            }
        }
    }
}
