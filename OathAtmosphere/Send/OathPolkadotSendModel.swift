import Foundation
import Observation
import OathAnkr
import OathDiagnostics

@MainActor @Observable final class OathPolkadotSendModel {
    private(set) var quote: OathPolkadotQuote?
    private(set) var busy = false
    private(set) var needsRefresh = false
    private(set) var needsAmountChange = false
    private(set) var passcode = false
    private(set) var submission: OathBitcoinSubmission?
    private(set) var gasPrice: Decimal?
    private(set) var accountGuidance: SendAccountGuidance?
    private(set) var failureMessage: OathStringKey?
    var notice: OathStringKey?
    @ObservationIgnored private var work: Task<Void,Never>?
    @ObservationIgnored private var generation = UUID()

    func prepare(model: OathSendModel, session: OathWalletSession) {
        guard !busy, submission == nil, session.isUnlocked, model.supportsPolkadotSend,
              let holding = model.holding, let amount = model.reviewAtomic else { return }
        cancel(); busy = true; needsRefresh = false; needsAmountChange = false; quote = nil
        gasPrice = model.snapshot?.holdings.first { $0.networkID == "polkadot" && $0.reference == "native" }?.price
            .flatMap { Decimal(string:$0,locale:Locale(identifier:"en_US_POSIX")) }
        let token = generation, walletID = model.walletID, recipient = model.address
        let maximum = model.maximumAmount != nil
        work = Task(priority:.userInitiated) {
            do {
                let value = try await OathPolkadotSendService.shared.quote(walletID:walletID,accountID:holding.accountID,assetID:holding.assetID,
                    reference:holding.reference,recipient:recipient,amount:amount,decimals:holding.decimals,maximum:maximum,vault:session.vault)
                guard generation == token, !Task.isCancelled, session.isUnlocked else { return }
                quote = value; busy = false
            } catch {
                OathDiagnostics.record(error,component:"polkadot_send",operation:"prepare",context:["chain":"polkadot","stage":"quote"])
                guard generation == token, !Task.isCancelled else { return }
                busy = false; needsRefresh = true
                accountGuidance = .failure(error, native: holding.reference == "native")
                failureMessage = Self.message(error)
                needsAmountChange = (error as? PolkadotSendError) == .insufficientFunds
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
                let result = try await OathPolkadotSendService.shared.submit(quote,vault:session.vault,digits:digits,reason:reason)
                guard generation == token, !Task.isCancelled else { return }
                busy = false; passcode = false; submission = result

            } catch {
                OathDiagnostics.record(error,component:"polkadot_send",operation:"submit",context:["chain":"polkadot"])
                guard generation == token, !Task.isCancelled else { return }
                busy = false
                if error is OathBiometricCredentialError { passcode = true }
                else if error as? OathWalletError == .wrongPasscode { passcode = true; notice = .unlockIncorrect }
                else if case OathWalletError.throttled = error { passcode = true; notice = .unlockWait }
                else if !(error is CancellationError) { passcode = false; needsRefresh = true; accountGuidance = .failure(error, native: quote.plan.reference == "native"); failureMessage = Self.message(error); self.quote = nil; OathHaptics.shared.play(.warning) }
            }
        }
    }

    private static func message(_ error: Error) -> OathStringKey? {
        if error is SendFeeFundingError { return .sendNativeFeeRequired }
        guard let e = error as? PolkadotSendError else { return nil }
        switch e {
        case .insufficientFunds: return .sendInsufficient
        case .locked, .minimumBalance, .recipientMinimum, .recipientNeedsNative: return .sendAdjustAmount
        case .execution: return .suiSendFailed
        default: return nil
        }
    }

    func cancel() {
        generation = UUID(); work?.cancel(); work = nil; busy = false; passcode = false; notice = nil
        // The receipt owns this reviewed plan until the send flow is dismissed.
        guard submission == nil else { return }
        quote = nil; accountGuidance = nil; failureMessage = nil; needsRefresh = false; needsAmountChange = false
    }
}
