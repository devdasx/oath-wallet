import Foundation
import OathAnkr
import OathDatabase
import OathDiagnostics

struct OathTronQuote: Sendable, Equatable {
    let walletID: String, accountID: String, assetID: String
    let plan: TronSendPlan
}

/// App-lifetime submission owner. Authentication is separate from preparation;
/// exact signed bytes are journaled before any broadcast and survive dismissal.
actor OathTronSendService {
    static let shared = OathTronSendService()
    private var client: TronSendClient?
    private var flights = Set<String>()
    private func connection() throws -> TronSendClient {
        if let client { return client }
        let value = try OathTokenRPCConfiguration.bundled().makeTronSendClient()
        client = value; return value
    }
    func quote(walletID: String, accountID: String, assetID: String, reference: String,
               recipient: String, amount: String, decimals: Int, maximum: Bool, vault: OathWalletVault) async throws -> OathTronQuote {
        try await OathDiagnostics.$chain.withValue("tron") {
            try await OathDiagnostics.$operationID.withValue(UUID()) {
                do {
                    let database = try await vault.database()
                    guard let account = try await database.accounts(walletID:walletID).first(where:{$0.id == accountID && $0.networkID == "tron"}) else { throw TronSendError.wrongOwner }
                    let plan = try await connection().quote(sender:account.address,recipient:recipient,reference:reference,decimals:decimals,amount:amount,maximum:maximum)
                    return .init(walletID:walletID,accountID:accountID,assetID:assetID,plan:plan)
                } catch {
                    OathDiagnostics.record(error,component:"tron_send",operation:"quote",context:["chain":"tron"])
                    throw error
                }
            }
        }
    }

    func submit(_ quote: OathTronQuote, vault: OathWalletVault, digits: [UInt8]?, reason: String, permissionSendID: String? = nil, permissionAuthorization: UUID? = nil) async throws -> OathBitcoinSubmission {
        try await OathDiagnostics.$chain.withValue("tron") {
            try await OathDiagnostics.$operationID.withValue(UUID()) {
                try await submitWithDiagnostics(quote,vault:vault,digits:digits,reason:reason,permissionSendID:permissionSendID,permissionAuthorization:permissionAuthorization)
            }
        }
    }
    private func submitWithDiagnostics(_ quote: OathTronQuote, vault: OathWalletVault, digits: [UInt8]?, reason: String, permissionSendID: String?, permissionAuthorization: UUID?) async throws -> OathBitcoinSubmission {
        let id = permissionSendID ?? UUID().uuidString
        guard permissionSendID == nil || (permissionAuthorization != nil && quote.plan.removal != nil && UUID(uuidString:id) != nil) else { throw PermissionError.changed }
        guard flights.insert(id).inserted else { throw PermissionError.changed }; defer { flights.remove(id) }
        let db = try await vault.database()
        if permissionSendID != nil, try await db.send(id) != nil { throw PermissionError.changed }
        var stage = "reserve"
        var acknowledgedHash: String?
        do {
            try quote.plan.validate()
            let now = Date.now.timeIntervalSince1970
            try await db.saveDraft(.init(id:id,walletID:quote.walletID,accountID:quote.accountID,networkID:"tron",assetID:quote.assetID,
                idempotencyKey:id,recipient:quote.plan.recipient,amountAtomic:String(quote.plan.amount),state:"draft",createdAt:now,updatedAt:now))
            try await db.queueTronSend(sendID:id,plan:quote.plan)
            if quote.plan.removal != nil {try await connection().preflightPermission(quote.plan)}
            stage = "authenticate"
            let signed = try await vault.signTronSend(sendID:id,quote:quote,digits:digits,reason:reason,permissionAuthorization:permissionAuthorization)
            try Task.checkCancellation()
            if quote.plan.removal != nil {
                stage = "permission_recheck"
                try await connection().preflightPermission(quote.plan)
                try Task.checkCancellation()
            }
            stage = "persist"
            try await db.journalTronSignature(sendID:id,signed:signed)
            _ = try await db.transitionSend(id,from:"signed",to:"broadcast")
            stage = "broadcast"
            let receipt = try await connection().submit(signed,plan:quote.plan,reconcileFirst:false)
            if receipt.accepted { acknowledgedHash = signed.hash }
            try await db.settleTronSend(sendID:id,receipt:receipt)
            await OathPostSendBalanceRefresh.shared.submitted(walletID:quote.walletID,networkID:"tron")
            guard receipt.outcome != .failed && receipt.outcome != .expired else { throw TronSendError.execution }
            return .init(txid:signed.hash,accepted:receipt.accepted)
        } catch {
            OathDiagnostics.record(error,component:"tron_send",operation:stage,context:["chain":"tron","stage":stage])
            if let stored = await OathDiagnostics.attemptOptional("tron_send_state",body:{ try await db.send(id) }) {
                if ["queued","draft"].contains(stored.state) {
                    _ = await OathDiagnostics.attempt("tron_send_cancel",body:{ try await db.transitionSend(id,from:stored.state,to:"cancelled") })
                } else if ["signed","broadcast"].contains(stored.state), let payload = stored.signedPayload {
                    let signed = try JSONDecoder().decode(TronSignedSend.self,from:payload)
                    let observed = await OathDiagnostics.attemptOptional("tron_send_submission",body:{
                        try await db.tronSubmission(walletID:quote.walletID,hash:signed.hash)
                    })
                    return .init(txid:signed.hash,accepted:acknowledgedHash == signed.hash || observed?.accepted == true)
                }
            }
            throw error
        }
    }
    func check(send: SendRecord, database: OathDatabase) async throws {
        guard !flights.contains(send.id) else { return }
        try Task.checkCancellation()
        flights.insert(send.id); defer { flights.remove(send.id) }
        try await database.reconcileTronSend(send.id, client: connection())
    }
}
