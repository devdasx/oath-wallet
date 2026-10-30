import SwiftUI
import Observation
import OathAnkr
import OathDiagnostics

@MainActor @Observable final class OathTronMultisigSetupModel {
    var address = ""
    var state: TronMultisigState?
    var quote: OathTronQuote?
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
            let result = try await OathTronSendService.shared.multisigSetup(walletID: walletID, vault: session.vault)
            try Task.checkCancellation()
            guard session.isUnlocked else { return }
            address = result.0; state = result.1; quote = result.2; pending = result.3
        } catch {
            if error is CancellationError || Task.isCancelled { return }
            OathDiagnostics.record(error, component: "tron_send", operation: "multisig_setup_refresh", context: ["chain": "tron"])
            notice = (error as? TronSendError) == .unsupportedAccount ? .tronAccountUnsupported : .walletUnavailable
        }
    }
    func activate(session: OathWalletSession, walletID: String, reason: String, digits: [UInt8]? = nil) {
        guard session.isUnlocked, !sending, !loading, !pending, let quote, state?.configured == false else { return }
        sending = true; notice = nil
        // The app-lifetime submission service journals before broadcast. Dismissal
        // never cancels or replaces an already signed permission transaction.
        Task {
            var digits = digits
            defer { if digits != nil { _ = digits!.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) } } }
            do {
                _ = try await OathTronSendService.shared.submit(quote, vault: session.vault, digits: digits, reason: reason)
                self.quote = nil; passcode = false; pending = true; sending = false
                await refresh(session: session, walletID: walletID)
            } catch {
                sending = false
                OathDiagnostics.record(error, component: "tron_send", operation: "multisig_setup_submit", context: ["chain": "tron"])
                if error is OathBiometricCredentialError { passcode = true }
                else if error as? OathWalletError == .wrongPasscode { passcode = true; notice = .unlockIncorrect }
                else if case OathWalletError.throttled = error { passcode = true; notice = .unlockWait }
                else if !(error is CancellationError) { passcode = false; self.quote = nil; notice = .walletUnavailable }
            }
        }
    }
}

struct OathTronMultisigSetupScreen: View {
    let session: OathWalletSession
    let walletID: String
    @State private var model = OathTronMultisigSetupModel()
    @Environment(\.oathLocalizer) private var strings
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if model.passcode {
                OathSecretPasscodePage(session: session, busy: model.sending, notice: $model.notice,
                    title: .multisigTronActivate, identifier: "multisig.tron.passcode") { digits in
                    model.activate(session: session, walletID: walletID, reason: strings.text(.multisigTronActivate), digits: digits)
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        OathSettingsRow(title: strings.text(model.state?.configured == true ? .multisigTronReady : .multisigTronSetup),
                            icon: model.state?.configured == true ? "checkmark.shield" : "exclamationmark.shield", accessory: .none)
                        OathSettingsFooter { Text(strings.text(model.state?.configured == true ? .multisigTronReadyDetail : .multisigTronSetupDetail)) }
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
                            OathSettingsRow(title: strings.text(.totalBalance), icon: "banknote", value: trx(state.balance), accessory: .none)
                            OathSettingsRow(title: strings.text(.transactionNetworkFee), icon: "network", value: trx(model.quote?.plan.fee ?? state.permissionFee), accessory: .none)
                            OathSettingsFooter { Text(strings.text(.multisigTronFeeDetail)) }
                        }
                        if model.pending { OathSettingsFooter { Text(strings.text(.multisigTronPending)) } }
                        if let notice = model.notice { Text(strings.text(notice)).oathFont(.footnote).foregroundStyle(.red).padding(24) }
                    }
                    .frame(maxWidth: 600).frame(maxWidth: .infinity)
                }
                .oathBottomActions {
                    if model.state?.configured != true {
                        OathBottomAction(title: strings.text(.multisigTronActivate), identifier: "multisig.tron.activate",
                            isEnabled: model.quote != nil && !model.pending && session.isUnlocked && scenePhase == .active,
                            isWorking: model.sending) {
                            model.activate(session: session, walletID: walletID, reason: strings.text(.multisigTronActivate))
                        }
                    }
                }
            }
        }
        .background(Color(uiColor: OathSurfaceColors.canvas).ignoresSafeArea())
        .navigationTitle(strings.text(.multisigTronSetup)).navigationBarTitleDisplayMode(.inline)
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
    private func trx(_ sun: UInt64) -> String { NSDecimalNumber(decimal: Decimal(sun) / 1_000_000).stringValue + " TRX" }
}
