import Foundation
import OathAnkr
import OathDatabase
import OathDiagnostics

struct OathSuiQuote: Sendable, Equatable {
    let walletID: String, accountID: String, assetID: String
    let plan: SuiSendPlan
}

/// App-lifetime submission owner. Authentication is separate from preparation;
/// exact signed bytes are journaled before any broadcast and survive dismissal.
actor OathSuiSendService {
    static let shared = OathSuiSendService()
    private var client: SuiSendClient?
    private var flights = Set<String>()
    private func connection() throws -> SuiSendClient {
        if let client { return client }
        let value = try OathTokenRPCConfiguration.bundled().makeSuiSendClient()
        client = value; return value
    }
    func quote(walletID: String, accountID: String, assetID: String, reference: String,
               recipient: String, amount: UInt64, vault: OathWalletVault) async throws -> OathSuiQuote {
        let database = try await vault.database()
        guard let account = try await database.accounts(walletID:walletID).first(where:{$0.id == accountID && $0.networkID == "sui"}) else { throw SuiSendError.wrongOwner }
        let plan = try await connection().quote(sender:account.address,recipient:recipient,reference:reference,amount:amount)
        return .init(walletID:walletID,accountID:accountID,assetID:assetID,plan:plan)
    }
    func submit(_ quote: OathSuiQuote, vault: OathWalletVault, digits: [UInt8]?, reason: String) async throws -> OathBitcoinSubmission {
        try await OathDiagnostics.$chain.withValue("sui") {
            try await OathDiagnostics.$operationID.withValue(UUID()) {
                try await submitWithDiagnostics(quote,vault:vault,digits:digits,reason:reason)
            }
        }
    }
    private func submitWithDiagnostics(_ quote: OathSuiQuote, vault: OathWalletVault, digits: [UInt8]?, reason: String) async throws -> OathBitcoinSubmission {
        let id = UUID().uuidString
        flights.insert(id); defer { flights.remove(id) }
        let db = try await vault.database()
        var stage = "reserve"
        do {
            try quote.plan.validate()
            let now = Date.now.timeIntervalSince1970
            try await db.saveDraft(.init(id:id,walletID:quote.walletID,accountID:quote.accountID,networkID:"sui",assetID:quote.assetID,
                idempotencyKey:id,recipient:quote.plan.recipient,amountAtomic:String(quote.plan.amount),state:"draft",createdAt:now,updatedAt:now))
            try await db.queueSuiSend(sendID:id,plan:quote.plan)
            stage = "authenticate"
            let signed = try await vault.signSuiSend(sendID:id,quote:quote,digits:digits,reason:reason)
            try Task.checkCancellation()
            stage = "persist"
            try await db.journalSuiSignature(sendID:id,signed:signed)
            _ = try await db.transitionSend(id,from:"signed",to:"broadcast")
            stage = "broadcast"
            let receipt = try await connection().submit(signed,sender:quote.plan.sender)
            try await db.settleSuiSend(sendID:id,receipt:receipt)
            await OathPostSendBalanceRefresh.shared.submitted(walletID:quote.walletID,networkID:"sui")
            guard receipt.outcome != .failed else { throw SuiSendError.executionFailed }
            return .init(txid:signed.digest,accepted:receipt.outcome == .confirmed)
        } catch {
            OathDiagnostics.record(error,component:"sui_send",operation:stage,context:["chain":"sui","stage":stage])
            if let stored = await OathDiagnostics.attemptOptional("sui_send_state",body:{ try await db.send(id) }) {
                if ["queued","draft"].contains(stored.state) {
                    _ = await OathDiagnostics.attempt("sui_send_cancel",body:{ try await db.transitionSend(id,from:stored.state,to:"cancelled") })
                } else if ["signed","broadcast"].contains(stored.state), let payload = stored.signedPayload {
                    let signed = try JSONDecoder().decode(SuiSignedSend.self,from:payload)
                    return .init(txid:signed.digest,accepted:false)
                }
            }
            throw error
        }
    }
    func check(send: SendRecord, database: OathDatabase) async throws {
        guard !flights.contains(send.id) else { return }
        try Task.checkCancellation()
        flights.insert(send.id); defer { flights.remove(send.id) }
        try await database.reconcileSuiSend(send.id, client: connection())
    }
}
