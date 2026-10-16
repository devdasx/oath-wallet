import Foundation
import Observation
import OathAnkr
import OathDiagnostics

@MainActor @Observable final class OathThorchainSendModel {
    private(set) var quote: OathThorchainQuote?
    private(set) var busy = false
    private(set) var needsRefresh = false
    private(set) var needsAmountChange = false
    private(set) var needsRecipientChange = false
    private(set) var passcode = false
    private(set) var submission: OathBitcoinSubmission?
    private(set) var gasPrice: Decimal?
    private(set) var failureMessage: OathStringKey?
    var notice: OathStringKey?
    @ObservationIgnored private var work: Task<Void,Never>?
    @ObservationIgnored private var generation = UUID()

    func prepare(model: OathSendModel, session: OathWalletSession) {
        guard !busy, submission == nil, session.isUnlocked, model.supportsThorchainSend,
              let holding = model.holding, let amount = model.reviewAtomic else { return }
        cancel(); busy = true; needsRefresh = false; needsAmountChange = false; quote = nil
        gasPrice = model.snapshot?.holdings.first { $0.networkID == "thorchain" && $0.reference == "native" }?.price
            .flatMap { Decimal(string:$0,locale:Locale(identifier:"en_US_POSIX")) }
        let token = generation, walletID = model.walletID, recipient = model.address
        let maximum = model.maximumAmount != nil
        work = Task(priority:.userInitiated) {
            do {
                let value = try await OathThorchainSendService.shared.quote(walletID:walletID,accountID:holding.accountID,assetID:holding.assetID,
                    reference:holding.reference,recipient:recipient,amount:amount,decimals:holding.decimals,maximum:maximum,memo:model.memo,vault:session.vault)
                guard generation == token, !Task.isCancelled, session.isUnlocked else { return }
                quote = value; busy = false
            } catch {
                OathDiagnostics.record(error,component:"thorchain_send",operation:"prepare",context:["chain":"thorchain","stage":"quote"])
                guard generation == token, !Task.isCancelled else { return }
                busy = false; needsRefresh = true
                failureMessage = Self.message(error)
                needsAmountChange = [.insufficientFunds, .amount].contains(error as? ThorchainSendError)
                needsRecipientChange = (error as? ThorchainSendError) == .moduleRecipient
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
                let result = try await OathThorchainSendService.shared.submit(quote,vault:session.vault,digits:digits,reason:reason)
                guard generation == token, !Task.isCancelled else { return }
                busy = false; passcode = false; submission = result
                if !result.accepted { await observeSubmission(result,session:session,token:token) }
            } catch {
                OathDiagnostics.record(error,component:"thorchain_send",operation:"submit",context:["chain":"thorchain"])
                guard generation == token, !Task.isCancelled else { return }
                busy = false
                if error is OathBiometricCredentialError { passcode = true }
                else if error as? OathWalletError == .wrongPasscode { passcode = true; notice = .unlockIncorrect }
                else if case OathWalletError.throttled = error { passcode = true; notice = .unlockWait }
                else if !(error is CancellationError) { passcode = false; needsRefresh = true; failureMessage = Self.message(error); self.quote = nil; OathHaptics.shared.play(.warning) }
            }
        }
    }
    /// Observe the durable journal, while the service owns network recovery.
    /// Dismissing this screen cancels only its observation, never signed work.
    private func observeSubmission(_ result:OathBitcoinSubmission,session:OathWalletSession,token:UUID) async {
        await OathDiagnostics.$chain.withValue("thorchain") {
            await OathDiagnostics.$operationID.withValue(UUID()) {
                do {
                    guard let walletID=quote?.walletID else { return }
                    let db=try await session.vault.database()
                    for _ in 0..<75 {
                        try await Task.sleep(for:.seconds(4))
                        guard generation==token,!Task.isCancelled,session.isUnlocked else { return }
                        guard let tx=try await db.thorchainSubmission(walletID:walletID,hash:result.txid) else { return }
                        if tx.state=="confirmed" { submission = .init(txid:result.txid,accepted:true);return }
                        if tx.state=="failed" {
                            submission=nil;quote=nil;needsRefresh=true;failureMessage = .thorchainSendFailed
                            OathHaptics.shared.play(.warning);return
                        }
                    }
                } catch {
                    if error is CancellationError || Task.isCancelled { return }
                    OathDiagnostics.record(error,component:"thorchain_send",operation:"observe_submission",context:["chain":"thorchain"])
                }
            }
        }
    }
    private static func message(_ error: Error) -> OathStringKey? {
        guard let e = error as? ThorchainSendError else { return nil }
        switch e {
        case .amount: return .sendAmountInvalid
        case .moduleRecipient: return .sendChangeAddress
        case .insufficientFunds: return .thorchainInsufficientFunds
        case .wrongOwner: return .thorchainAccountUnsupported
        case .metadataChanged: return .thorchainMetadataChanged
        case .feeTooHigh: return .thorchainFeeTooHigh
        case .halted: return .thorchainHalted
        case .execution: return .thorchainSendFailed
        default: return nil
        }
    }

    func cancel() {
        generation = UUID(); work?.cancel(); work = nil; busy = false; passcode = false; notice = nil
        quote = nil; submission = nil; failureMessage = nil; needsRefresh = false; needsAmountChange = false; needsRecipientChange = false
    }
}
