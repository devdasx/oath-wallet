import Foundation
import Observation
import OathAnkr
import OathDiagnostics

@MainActor @Observable final class OathSuiSendModel {
    private(set) var quote: OathSuiQuote?
    private(set) var busy = false
    private(set) var needsRefresh = false
    private(set) var needsAmountChange = false
    private(set) var passcode = false
    private(set) var submission: OathBitcoinSubmission?
    private(set) var gasPrice: Decimal?
    private(set) var failureMessage: OathStringKey?
    var notice: OathStringKey?
    @ObservationIgnored private var work: Task<Void,Never>?
    @ObservationIgnored private var generation = UUID()

    func prepare(model: OathSendModel, session: OathWalletSession) {
        guard !busy, submission == nil, session.isUnlocked, model.supportsSuiSend,
              let holding = model.holding, let atomic = model.reviewAtomic, let amount = UInt64(atomic) else { return }
        cancel(); busy = true; needsRefresh = false; needsAmountChange = false; quote = nil
        gasPrice = model.snapshot?.holdings.first { $0.networkID == "sui" && $0.reference == "native" }?.price
            .flatMap { Decimal(string:$0,locale:Locale(identifier:"en_US_POSIX")) }
        let token = generation, walletID = model.walletID, recipient = model.address
        work = Task(priority:.userInitiated) {
            do {
                let value = try await OathSuiSendService.shared.quote(walletID:walletID,accountID:holding.accountID,assetID:holding.assetID,
                    reference:holding.reference,recipient:recipient,amount:amount,vault:session.vault)
                guard generation == token, !Task.isCancelled, session.isUnlocked else { return }
                quote = value; busy = false
            } catch {
                OathDiagnostics.record(error,component:"sui_send",operation:"prepare",context:["chain":"sui","stage":"quote"])
                guard generation == token, !Task.isCancelled else { return }
                busy = false; needsRefresh = true
                failureMessage = error is SendFeeFundingError ? .sendNativeFeeRequired : (error as? SuiSendError) == .feeTooHigh ? .solanaFeeTooHigh : (error as? SuiSendError) == .insufficientGas ? .suiGasRequired : nil
                needsAmountChange = (error as? SuiSendError) == .insufficientFunds
            }
        }
    }
    func send(session: OathWalletSession, digits: [UInt8]? = nil, reason: String) {
        guard let quote, !busy, submission == nil, session.isUnlocked else { return }
        busy = true; notice = nil
        let token = generation
        work = Task {
            var digits = digits
            defer { if digits != nil { _ = digits!.withUnsafeMutableBytes { $0.initializeMemory(as:UInt8.self,repeating:0) } } }
            do {
                let result = try await OathSuiSendService.shared.submit(quote,vault:session.vault,digits:digits,reason:reason)
                guard generation == token, !Task.isCancelled else { return }
                busy = false; passcode = false; submission = result

                if !result.accepted { OathHaptics.shared.play(.warning) }
            } catch {
                OathDiagnostics.record(error,component:"sui_send",operation:"submit",context:["chain":"sui"])
                guard generation == token, !Task.isCancelled else { return }
                busy = false
                if error is OathBiometricCredentialError { passcode = true }
                else if error as? OathWalletError == .wrongPasscode { passcode = true; notice = .unlockIncorrect }
                else if case OathWalletError.throttled = error { passcode = true; notice = .unlockWait }
                else if !(error is CancellationError) { passcode = false; needsRefresh = true; failureMessage = error is SendFeeFundingError ? .sendNativeFeeRequired : (error as? SuiSendError) == .feeTooHigh ? .solanaFeeTooHigh : (error as? SuiSendError) == .executionFailed ? .suiSendFailed : nil; self.quote = nil; OathHaptics.shared.play(.warning) }
            }
        }
    }


    func cancel() {
        generation = UUID(); work?.cancel(); work = nil; busy = false; passcode = false; notice = nil
        // The receipt owns this reviewed plan until the send flow is dismissed.
        guard submission == nil else { return }
        quote = nil; failureMessage = nil; needsRefresh = false; needsAmountChange = false
    }
}
