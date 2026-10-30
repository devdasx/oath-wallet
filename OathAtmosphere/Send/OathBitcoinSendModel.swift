import OathDiagnostics
import Foundation
import Observation
import OathBitcoin

@MainActor @Observable final class OathBitcoinSendModel {
    private(set) var quote: OathBitcoinQuote?
    private(set) var busy = false
    private(set) var needsRefresh = false
    private(set) var needsAmountChange = false
    private(set) var needsMessageChange = false
    private(set) var passcode = false
    private(set) var submission: OathBitcoinSubmission?
    var notice: OathStringKey?
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()

    func prepare(model: OathSendModel, session: OathWalletSession, forceRefresh: Bool = false) {
        guard !busy, submission == nil, session.isUnlocked,
              model.supportsBitcoinSend, let atomic = model.reviewAtomic, let amount = Int64(atomic),
              let chain = model.chain, let network = UTXONetwork(rawValue: chain.rawValue) else { return }
        cancel(); busy = true; needsRefresh = false; needsAmountChange = false; needsMessageChange = false; quote = nil
        let token = generation, wallet = model.walletID, recipient = model.address
        let options = model.reviewOptions
        work = Task(priority: .userInitiated) {
            do {
                let service = try OathBitcoinSendService.service(for: network)
                let quote = try await service.quote(walletID: wallet, recipient: recipient, amount: amount, options: options, vault: session.vault, forceRefresh: forceRefresh)
                guard generation == token, !Task.isCancelled, session.isUnlocked else { return }
                self.quote = quote; busy = false
            } catch { OathDiagnostics.record(error, component: "send", operation: "prepare", context: ["chain": network.rawValue, "stage": "quote"]);
                guard generation == token, !Task.isCancelled else { return }
                busy = false; needsRefresh = true
                if let failure = error as? BitcoinSendError {
                    needsMessageChange = !options.message.isEmpty && [.tooLarge, .messageTooLarge].contains(failure)
                    needsAmountChange = [.invalidAmount, .insufficientFunds, .feeTooHigh, .tooLarge, .messageTooLarge, .invalidOptions].contains(failure)
                }
            }
        }
    }

    func send(session: OathWalletSession, digits: [UInt8]? = nil, reason: String) {
        guard let quote, !busy, submission == nil, session.isUnlocked else { return }
        busy = true; notice = nil
        let token = generation
        work = Task {
            var digits = digits
            defer { if digits != nil { _ = digits!.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) } } }
            do {
                let result = try await OathBitcoinSendService.service(for: quote.plan.chain).submit(quote, vault: session.vault, digits: digits, reason: reason)
                guard generation == token, !Task.isCancelled else { return }
                busy = false; passcode = false; submission = result

                // Success belongs to the visible receipt, synchronized with its
                // native checkmark animation. Avoid an earlier duplicate pulse.

            } catch {
                if !OathSendDiagnostics.isExpectedAuthenticationFallback(error) {
                    OathDiagnostics.record(error, component: "send", operation: "submit", context: ["chain": quote.plan.chain.rawValue])
                }
                guard generation == token, !Task.isCancelled else { return }
                busy = false
                if error is OathBiometricCredentialError { passcode = true }
                else if error as? OathWalletError == .wrongPasscode { passcode = true; notice = .unlockIncorrect }
                else if case OathWalletError.throttled = error { passcode = true; notice = .unlockWait }
                else if !(error is CancellationError) { passcode = false; needsRefresh = true; self.quote = nil; OathHaptics.shared.play(.warning) }
            }
        }
    }



    func cancel() {
        generation = UUID(); work?.cancel(); work = nil; busy = false; passcode = false; notice = nil
    }
}
