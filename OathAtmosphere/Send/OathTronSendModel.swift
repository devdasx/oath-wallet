import Foundation
import Observation
import OathAnkr
import OathDiagnostics

@MainActor @Observable final class OathTronSendModel {
    private(set) var quote: OathTronQuote?
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
        guard !busy, submission == nil, session.isUnlocked, model.supportsTronSend,
              let holding = model.holding, let amount = model.reviewAtomic else { return }
        cancel(); busy = true; needsRefresh = false; needsAmountChange = false; quote = nil
        gasPrice = model.snapshot?.holdings.first { $0.networkID == "tron" && $0.reference == "native" }?.price
            .flatMap { Decimal(string:$0,locale:Locale(identifier:"en_US_POSIX")) }
        let token = generation, walletID = model.walletID, recipient = model.address
        let maximum = model.maximumAmount != nil
        work = Task(priority:.userInitiated) {
            do {
                let value = try await OathTronSendService.shared.quote(walletID:walletID,accountID:holding.accountID,assetID:holding.assetID,
                    reference:holding.reference,recipient:recipient,amount:amount,decimals:holding.decimals,maximum:maximum,vault:session.vault)
                guard generation == token, !Task.isCancelled, session.isUnlocked else { return }
                quote = value; busy = false
            } catch {
                OathDiagnostics.record(error,component:"tron_send",operation:"prepare",context:["chain":"tron","stage":"quote"])
                guard generation == token, !Task.isCancelled else { return }
                busy = false; needsRefresh = true
                accountGuidance = .failure(error, native: holding.reference == "native")
                failureMessage = Self.message(error)
                needsAmountChange = (error as? TronSendError) == .insufficientFunds
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
                let result = try await OathTronSendService.shared.submit(quote,vault:session.vault,digits:digits,reason:reason)
                guard generation == token, !Task.isCancelled else { return }
                busy = false; passcode = false; submission = result
                await observeSubmission(result,session:session,token:token)
            } catch {
                OathDiagnostics.record(error,component:"tron_send",operation:"submit",context:["chain":"tron"])
                guard generation == token, !Task.isCancelled else { return }
                busy = false
                if error is OathBiometricCredentialError { passcode = true }
                else if error as? OathWalletError == .wrongPasscode { passcode = true; notice = .unlockIncorrect }
                else if case OathWalletError.throttled = error { passcode = true; notice = .unlockWait }
                else if !(error is CancellationError) { passcode = false; needsRefresh = true; accountGuidance = .failure(error, native: quote.plan.reference == "native"); failureMessage = Self.message(error); self.quote = nil; OathHaptics.shared.play(.warning) }
            }
        }
    }
    /// Observe the durable journal, while the service owns network recovery.
    /// Dismissing this screen cancels only its observation, never signed work.
    private func observeSubmission(_ result:OathBitcoinSubmission,session:OathWalletSession,token:UUID) async {
        await OathDiagnostics.$chain.withValue("tron") {
            await OathDiagnostics.$operationID.withValue(UUID()) {
                do {
                    guard let walletID=quote?.walletID else { return }
                    let db=try await session.vault.database()
                    for _ in 0..<75 {
                        try await Task.sleep(for:.seconds(4))
                        guard generation==token,!Task.isCancelled,session.isUnlocked else { return }
                        guard let tx=try await db.tronSubmission(walletID:walletID,hash:result.txid) else { return }
                        if tx.accepted { submission = .init(txid:result.txid,accepted:true) }
                        if tx.state=="confirmed" { return }
                        if tx.state=="failed" {
                            submission=nil;quote=nil;accountGuidance=nil;needsRefresh=true;failureMessage = .tronSendFailed
                            OathHaptics.shared.play(.warning);return
                        }
                    }
                } catch {
                    if error is CancellationError || Task.isCancelled { return }
                    OathDiagnostics.record(error,component:"tron_send",operation:"observe_submission",context:["chain":"tron"])
                }
            }
        }
    }
    private static func message(_ error: Error) -> OathStringKey? {
        guard let e = error as? TronSendError else { return nil }
        switch e {
        case .unsupportedAccount: return .tronAccountUnsupported
        case .simulation: return .tronSimulationFailed
        case .feeTooHigh: return .tronFeeTooHigh
        case .execution: return .tronSendFailed
        case .insufficientFunds: return .tronInsufficientFunds
        default: return nil
        }
    }

    func cancel() {
        generation = UUID(); work?.cancel(); work = nil; busy = false; passcode = false; notice = nil
        quote = nil; submission = nil; accountGuidance = nil; failureMessage = nil; needsRefresh = false; needsAmountChange = false
    }
}
