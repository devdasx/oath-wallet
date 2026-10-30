import SwiftUI
import Observation
import OathAnkr
import OathDiagnostics

@MainActor @Observable final class OathXrplMultisigSetupModel {
    var address = ""
    var state: XrplMultisigState?
    var quote: OathXrplQuote?
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
            let result = try await OathXrplSendService.shared.multisigSetup(walletID: walletID, vault: session.vault)
            try Task.checkCancellation()
            guard session.isUnlocked else { return }
            address = result.0; state = result.1; quote = result.2; pending = result.3
        } catch {
            if error is CancellationError || Task.isCancelled { return }
            OathDiagnostics.record(error, component: "xrpl_send", operation: "multisig_setup_refresh", context: ["chain": "xrpl"])
            notice = (error as? XrplSendError) == .unsupportedAccount ? .walletUnavailable : .walletUnavailable
        }
    }
    func activate(session: OathWalletSession, walletID: String, reason: String, digits: [UInt8]? = nil) {
        guard session.isUnlocked, !sending, !loading, !pending, let quote, (state?.configured == false || quote.plan.tokenAuthorization == true) else { return }
        sending = true; notice = nil
        // The app-lifetime submission service journals before broadcast. Dismissal
        // never cancels or replaces an already signed permission transaction.
        Task {
            var digits = digits
            defer { if digits != nil { _ = digits!.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) } } }
            do {
                _ = try await OathXrplSendService.shared.submit(quote, vault: session.vault, digits: digits, reason: reason)
                self.quote = nil; passcode = false; pending = true; sending = false
                await refresh(session: session, walletID: walletID)
            } catch {
                sending = false
                OathDiagnostics.record(error, component: "xrpl_send", operation: "multisig_setup_submit", context: ["chain": "xrpl"])
                if error is OathBiometricCredentialError { passcode = true }
                else if error as? OathWalletError == .wrongPasscode { passcode = true; notice = .unlockIncorrect }
                else if case OathWalletError.throttled = error { passcode = true; notice = .unlockWait }
                else if !(error is CancellationError) { passcode = false; self.quote = nil; notice = .walletUnavailable }
            }
        }
    }
}

struct OathXrplMultisigSetupScreen: View {
    let session: OathWalletSession
    let walletID: String
    @State private var model = OathXrplMultisigSetupModel()
    @State private var showsTokenAuthorization = false
    @Environment(\.oathLocalizer) private var strings
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if model.passcode {
                OathSecretPasscodePage(session: session, busy: model.sending, notice: $model.notice,
                    title: .multisigXrplActivate, identifier: "multisig.xrpl.passcode") { digits in
                    model.activate(session: session, walletID: walletID, reason: strings.text(.multisigXrplActivate), digits: digits)
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        OathSettingsRow(title: strings.text(model.state?.configured == true ? .multisigXrplReady : .multisigXrplSetup),
                            icon: model.state?.configured == true ? "checkmark.shield" : "exclamationmark.shield", accessory: .none)
                        OathSettingsFooter { Text(strings.text(model.state?.configured == true ? .multisigXrplReadyDetail : .multisigXrplSetupDetail)) }
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
                            OathSettingsRow(title: strings.text(.totalBalance), icon: "banknote", value: xrp(state.balance), accessory: .none)
                            OathSettingsRow(title: strings.text(.multisigXrplReserve), icon: "lock", value: xrp(state.reserve), accessory: .none)
                            OathSettingsRow(title: strings.text(.transactionNetworkFee), icon: "network", value: xrp(model.quote?.plan.fee ?? 0), accessory: .none)
                            OathSettingsFooter { Text(strings.text(.multisigXrplFeeDetail)) }
                        }
                        if model.state?.configured == true {
                            OathSettingsSectionRule()
                            OathButton { showsTokenAuthorization = true } label: {
                                OathSettingsRow(title: strings.text(.multisigXrplTokenAdd), icon: "plus.circle")
                            }.buttonStyle(OathSettingsRowButtonStyle())
                        }
                        if model.pending { OathSettingsFooter { Text(strings.text(.multisigXrplPending)) } }
                        if let notice = model.notice { Text(strings.text(notice)).oathFont(.footnote).foregroundStyle(.red).padding(24) }
                    }
                    .frame(maxWidth: 600).frame(maxWidth: .infinity)
                }
                .oathBottomActions {
                    if model.state?.configured != true {
                        OathBottomAction(title: strings.text(.multisigXrplActivate), identifier: "multisig.xrpl.activate",
                            isEnabled: model.quote != nil && !model.pending && session.isUnlocked && scenePhase == .active,
                            isWorking: model.sending) {
                            model.activate(session: session, walletID: walletID, reason: strings.text(.multisigXrplActivate))
                        }
                    }
                }
            }
        }
        .background(Color(uiColor: OathSurfaceColors.canvas).ignoresSafeArea())
        .navigationTitle(strings.text(.multisigXrplSetup)).navigationBarTitleDisplayMode(.inline)
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
            NavigationStack { OathXrplTokenAuthorizationScreen(session:session,walletID:walletID) }
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
    private func xrp(_ sun: UInt64) -> String { NSDecimalNumber(decimal: Decimal(sun) / 1_000_000).stringValue + " XRP" }
}

/// Trust limits and MPT opt-ins are explicit, threshold-authorized actions.
private struct OathXrplTokenAuthorizationScreen: View {
    let session: OathWalletSession
    let walletID: String
    @State private var model = OathXrplMultisigSetupModel()
    @State private var mpt = false
    @State private var currency = ""
    @State private var issuer = ""
    @State private var limit = "1000"
    @Environment(\.oathLocalizer) private var strings
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
    private var ready: Bool { !currency.isEmpty && (mpt || (!issuer.isEmpty && !limit.isEmpty)) }
    var body: some View {
        Group {
            if model.passcode {
                OathSecretPasscodePage(session:session,busy:model.sending,notice:$model.notice,title:.multisigXrplTokenAdd,identifier:"multisig.xrpl.token.passcode") { digits in
                    model.activate(session:session,walletID:walletID,reason:strings.text(.multisigXrplTokenAdd),digits:digits)
                }
            } else {
                ScrollView {
                    VStack(alignment:.leading,spacing:20) {
                        Text(strings.text(.multisigXrplTokenDetail)).oathFont(.footnote).foregroundStyle(.secondary)
                        Picker(strings.text(.multisigXrplTokenType),selection:$mpt) {
                            Text(strings.text(.multisigXrplIssued)).tag(false)
                            Text(strings.invariant("MPT")).tag(true)
                        }.pickerStyle(.segmented)
                        TextField(strings.text(mpt ? .multisigXrplMptID:.multisigXrplCurrency),text:$currency).oathSettingsField()
                        if !mpt {
                            TextField(strings.text(.multisigXrplIssuer),text:$issuer).oathSettingsField()
                            TextField(strings.text(.multisigXrplLimit),text:$limit).oathSettingsField()
                        }
                        if let quote = model.quote {
                            Text(strings.text(.transactionNetworkFee)+": "+NSDecimalNumber(decimal:Decimal(quote.plan.fee)/1_000_000).stringValue+" XRP").oathFont(.body)
                            Text(strings.text(.multisigXrplTokenReview)).oathFont(.footnote).foregroundStyle(.secondary)
                        }
                        if model.pending { Text(strings.text(.multisigXrplPending)).oathFont(.footnote) }
                        if let notice = model.notice { Text(strings.text(notice)).oathFont(.footnote).foregroundStyle(.red) }
                    }.textInputAutocapitalization(.never).autocorrectionDisabled()
                        .disabled(model.sending || model.loading || model.pending)
                        .padding(24).frame(maxWidth:600).frame(maxWidth:.infinity)
                }
                .oathBottomActions {
                    OathBottomAction(title:strings.text(model.quote == nil ? .multisigXrplTokenReviewAction:.multisigXrplTokenAdd),identifier:"multisig.xrpl.token.confirm",
                        isEnabled:ready && !model.pending && session.isUnlocked && scenePhase == .active,isWorking:model.loading || model.sending) {
                        if model.quote != nil { model.activate(session:session,walletID:walletID,reason:strings.text(.multisigXrplTokenAdd)) }
                        else { prepare() }
                    }
                }
            }
        }
        .background(Color(uiColor:OathSurfaceColors.canvas).ignoresSafeArea())
        .navigationTitle(strings.text(.multisigXrplTokenAdd)).navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement:.cancellationAction) { OathCloseButton { dismiss() }.disabled(model.sending) } }
        .oathNativeLocalization()
        .onChange(of:currency) { _,_ in model.quote=nil }
        .onChange(of:issuer) { _,_ in model.quote=nil }
        .onChange(of:limit) { _,_ in model.quote=nil }
        .onChange(of:mpt) { _,_ in currency="";model.quote=nil }
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
        let reference = mpt ? currency.trimmingCharacters(in:.whitespacesAndNewlines).uppercased() : currency.trimmingCharacters(in:.whitespacesAndNewlines)+"."+issuer.trimmingCharacters(in:.whitespacesAndNewlines)
        // Invalid user-entered identifiers and limits are ordinary form validation.
        guard (try? XrplIdentity.reference(reference)) != nil, mpt || (try? XrplIdentity.issuedAmount(limit)) != nil else { model.notice = .multisigXrplTokenInvalid; return }
        model.loading=true;model.notice=nil
        Task {
            defer { model.loading=false }
            do {
                model.quote = try await OathXrplSendService.shared.tokenAuthorization(walletID:walletID,reference:reference,limit:limit,vault:session.vault)
                model.state = try await OathXrplSendService.shared.multisigSetup(walletID:walletID,vault:session.vault).1
            } catch {
                if error is CancellationError { return }
                if error as? XrplSendError == .tokenAlreadyEnabled { model.notice = .multisigXrplTokenEnabled; return }
                OathDiagnostics.record(error,component:"xrpl_send",operation:"token_authorization_review",context:["chain":"xrpl"])
                model.notice = .walletUnavailable
            }
        }
    }
}
