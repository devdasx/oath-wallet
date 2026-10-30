import Foundation
import Observation
import OathAnkr
import OathDiagnostics

@MainActor @Observable final class OathXrplSendModel {
    private(set) var quote: OathXrplQuote?
    private(set) var busy = false
    private(set) var needsRefresh = false
    private(set) var needsAmountChange = false
    private(set) var needsRecipientChange = false
    private(set) var passcode = false
    private(set) var submission: OathBitcoinSubmission?
    private(set) var gasPrice: Decimal?
    private(set) var accountGuidance: SendAccountGuidance?
    private(set) var failureMessage: OathStringKey?
    var notice: OathStringKey?
    @ObservationIgnored private var work: Task<Void,Never>?
    @ObservationIgnored private var generation = UUID()

    func prepare(model: OathSendModel, session: OathWalletSession) {
        guard !busy, submission == nil, session.isUnlocked, model.supportsXrplSend,
              let holding = model.holding, let amount = model.reviewAtomic else { return }
        cancel(); busy = true; needsRefresh = false; needsAmountChange = false; quote = nil
        gasPrice = model.snapshot?.holdings.first { $0.networkID == "xrpl" && $0.reference == "native" }?.price
            .flatMap { Decimal(string:$0,locale:Locale(identifier:"en_US_POSIX")) }
        let token = generation, walletID = model.walletID, recipient = model.address
        let tag = UInt32(model.memo), maximum = model.maximumAmount != nil, closure = model.xrplAccountClosure
        work = Task(priority:.userInitiated) {
            do {
                let value = try await XrplSendPreparation.run {
                    try await OathXrplSendService.shared.quote(walletID:walletID,accountID:holding.accountID,assetID:holding.assetID,
                        reference:holding.reference,recipient:recipient,amount:amount,destinationTag:tag,maximum:maximum,closure:closure,vault:session.vault)
                }
                guard generation == token, !Task.isCancelled, session.isUnlocked else { return }
                quote = value; busy = false
            } catch {
                // diagnostics: xrpl-preparation-feedback. XrplSendPreparation
                // reports original unexpected errors; preserve this recovery UI.
                guard generation == token, !Task.isCancelled else { return }
                busy = false; needsRefresh = true
                accountGuidance = .failure(error, native: holding.reference == "native")
                failureMessage = Self.message(error)
                needsAmountChange = closure != nil || [.insufficientFunds, .amount].contains(error as? XrplSendError)
                needsRecipientChange = (error as? XrplSendError) == .sameRecipient
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
                let result = try await OathXrplSendService.shared.submit(quote,vault:session.vault,digits:digits,reason:reason)
                guard generation == token, !Task.isCancelled else { return }
                busy = false; passcode = false; submission = result

                if !result.accepted { OathHaptics.shared.play(.warning) }
            } catch {
                OathDiagnostics.record(error,component:"xrpl_send",operation:"submit",context:["chain":"xrpl"])
                guard generation == token, !Task.isCancelled else { return }
                busy = false
                if error is OathBiometricCredentialError { passcode = true }
                else if error as? OathWalletError == .wrongPasscode { passcode = true; notice = .unlockIncorrect }
                else if case OathWalletError.throttled = error { passcode = true; notice = .unlockWait }
                else if !(error is CancellationError) { passcode = false; needsRefresh = true; needsAmountChange = quote.plan.closesAccount; accountGuidance = .failure(error, native: quote.plan.reference == "native"); failureMessage = Self.message(error); self.quote = nil; OathHaptics.shared.play(.warning) }
            }
        }
    }
    private static func message(_ error: Error) -> OathStringKey? {
        if error is SendFeeFundingError { return .sendNativeFeeRequired }
        guard let e = error as? XrplSendError else { return nil }
        switch e {
        case .closureUnavailable, .closureTooSoon, .closureObligations: return .xrplCloseUnavailable
        case .amount: return .sendAmountInvalid
        case .sameRecipient: return .sendChangeAddress
        case .reserve: return .xrplReserveRequired
        case .destinationTag: return .xrplTagRequired
        case .recipientUnfunded: return .xrplRecipientUnfunded
        case .unsupportedAccount: return .xrplAccountUnsupported
        case .simulation: return .xrplPaymentRestricted
        case .execution: return .xrplSendFailed
        default: return nil
        }
    }


    func cancel() {
        generation = UUID(); work?.cancel(); work = nil; busy = false; passcode = false; notice = nil
        // The receipt owns this reviewed plan until the send flow is dismissed.
        guard submission == nil else { return }
        quote = nil; accountGuidance = nil; failureMessage = nil; needsRefresh = false; needsAmountChange = false; needsRecipientChange = false
    }
}
