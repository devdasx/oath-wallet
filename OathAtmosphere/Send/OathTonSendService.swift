import Foundation
import OathAnkr
import OathDatabase
import OathDiagnostics

struct OathTonQuote: Sendable, Equatable {
    let walletID: String, accountID: String, assetID: String
    let plan: TonSendPlan
}

/// App-lifetime submission owner. Authentication is separate from preparation;
/// exact signed bytes are journaled before any broadcast and survive dismissal.
actor OathTonSendService {
    static let shared = OathTonSendService()
    private var client: TonSendClient?
    private var flights = Set<String>()
    private func connection() throws -> TonSendClient {
        if let client { return client }
        let value = try OathTokenRPCConfiguration.bundled().makeTonSendClient()
        client = value; return value
    }
    func quote(walletID: String, accountID: String, assetID: String, reference: String,
               recipient: String, amount: String, decimals: Int, maximum: Bool, memo: String, vault: OathWalletVault) async throws -> OathTonQuote {
        try await OathDiagnostics.$chain.withValue("ton") {
            try await OathDiagnostics.$operationID.withValue(UUID()) {
                do {
                    let database = try await vault.database()
                    guard let account = try await database.accounts(walletID:walletID).first(where:{$0.id == accountID && $0.networkID == "ton"}) else { throw TonSendError.wrongOwner }
                    let publicKey = try await vault.tonPublicKey(walletID:walletID,accountID:accountID)
                    let plan = try await connection().quote(sender:account.address,recipient:recipient,reference:reference,publicKey:publicKey,decimals:decimals,amount:amount,maximum:maximum,memo:memo)
                    return .init(walletID:walletID,accountID:accountID,assetID:assetID,plan:plan)
                } catch {
                    OathDiagnostics.record(error,component:"ton_send",operation:"quote",context:["chain":"ton"])
                    throw error
                }
            }
        }
    }

    func submit(_ quote: OathTonQuote, vault: OathWalletVault, digits: [UInt8]?, reason: String) async throws -> OathBitcoinSubmission {
        try await OathDiagnostics.$chain.withValue("ton") {
            try await OathDiagnostics.$operationID.withValue(UUID()) {
                try await submitWithDiagnostics(quote,vault:vault,digits:digits,reason:reason)
            }
        }
    }
    private func submitWithDiagnostics(_ quote: OathTonQuote, vault: OathWalletVault, digits: [UInt8]?, reason: String) async throws -> OathBitcoinSubmission {
        let id = UUID().uuidString
        flights.insert(id); defer { flights.remove(id) }
        let db = try await vault.database()
        var stage = "reserve"
        do {
            try quote.plan.validate()
            let now = Date.now.timeIntervalSince1970
            try await db.saveDraft(.init(id:id,walletID:quote.walletID,accountID:quote.accountID,networkID:"ton",assetID:quote.assetID,
                idempotencyKey:id,recipient:quote.plan.recipient,amountAtomic:String(quote.plan.amount),state:"draft",createdAt:now,updatedAt:now))
            try await db.queueTonSend(sendID:id,plan:quote.plan)
            stage = "preflight"
            // Network revalidation and local authorization are independent.
            // Structured concurrency cancels validation if authentication fails.
            async let validated: Void = connection().preflight(quote.plan)
            stage = "authenticate"
            let signed = try await vault.signTonSend(sendID:id,quote:quote,digits:digits,reason:reason)
            stage = "preflight"
            try await validated
            try Task.checkCancellation()
            stage = "persist"
            try await db.journalTonSignature(sendID:id,signed:signed)
            _ = try await db.transitionSend(id,from:"signed",to:"broadcast")
            stage = "broadcast"
            let receipt = try await connection().submit(signed,plan:quote.plan)
            try await db.settleTonSend(sendID:id,receipt:receipt)
            await OathPostSendBalanceRefresh.shared.submitted(walletID:quote.walletID,networkID:"ton")
            guard receipt.outcome != .failed && receipt.outcome != .expired else { throw TonSendError.execution }
            return .init(txid:signed.hash,accepted:receipt.outcome == .confirmed || receipt.outcome == .accepted)
        } catch {
            OathDiagnostics.record(error,component:"ton_send",operation:stage,context:["chain":"ton","stage":stage])
            if let stored = await OathDiagnostics.attemptOptional("ton_send_state",body:{ try await db.send(id) }) {
                if ["queued","draft"].contains(stored.state) {
                    _ = await OathDiagnostics.attempt("ton_send_cancel",body:{ try await db.transitionSend(id,from:stored.state,to:"cancelled") })
                } else if ["signed","broadcast"].contains(stored.state), let payload = stored.signedPayload {
                    let signed = try JSONDecoder().decode(TonSignedSend.self,from:payload)
                    return .init(txid:signed.hash,accepted:false)
                }
            }
            throw error
        }
    }
    func check(send: SendRecord, database: OathDatabase) async throws {
        guard !flights.contains(send.id) else { return }
        try Task.checkCancellation()
        flights.insert(send.id); defer { flights.remove(send.id) }
        try await database.reconcileTonSend(send.id, client: connection())
    }
}
