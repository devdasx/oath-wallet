import Foundation
import OathAnkr
import OathDatabase
import OathDiagnostics

struct OathPolkadotQuote: Sendable, Equatable {
    let walletID: String, accountID: String, assetID: String
    let plan: PolkadotSendPlan
}

/// App-lifetime submission owner. Authentication is separate from preparation;
/// exact signed bytes are journaled before any broadcast and survive dismissal.
actor OathPolkadotSendService {
    static let shared = OathPolkadotSendService()
    private var client: PolkadotSendClient?
    private var flights = Set<String>()
    private func connection() throws -> PolkadotSendClient {
        if let client { return client }
        let value = try PolkadotSendClient()
        client = value; return value
    }
    func quote(walletID: String, accountID: String, assetID: String, reference: String,
               recipient: String, amount: String, decimals: Int, maximum: Bool, vault: OathWalletVault) async throws -> OathPolkadotQuote {
        try await OathDiagnostics.$chain.withValue("polkadot") {
            try await OathDiagnostics.$operationID.withValue(UUID()) {
                do {
                    let database = try await vault.database()
                    guard let account = try await database.accounts(walletID:walletID).first(where:{$0.id == accountID && $0.networkID == "polkadot"}) else { throw PolkadotSendError.wrongOwner }
                    let knownToken = try await database.polkadotInventory(accountID:accountID)?.holdings.first { $0.token.reference == reference }?.token
                    let plan = try await connection().quote(sender:account.address,recipient:recipient,reference:reference,decimals:decimals,amount:amount,maximum:maximum,knownToken:knownToken)
                    return .init(walletID:walletID,accountID:accountID,assetID:assetID,plan:plan)
                } catch {
                    OathDiagnostics.record(error,component:"polkadot_send",operation:"quote",context:["chain":"polkadot","stage":"quote"])
                    throw error
                }
            }
        }
    }

    func submit(_ quote: OathPolkadotQuote, vault: OathWalletVault, digits: [UInt8]?, reason: String) async throws -> OathBitcoinSubmission {
        try await OathDiagnostics.$chain.withValue("polkadot") {
            try await OathDiagnostics.$operationID.withValue(UUID()) {
                try await submitWithDiagnostics(quote,vault:vault,digits:digits,reason:reason)
            }
        }
    }
    private func submitWithDiagnostics(_ quote: OathPolkadotQuote, vault: OathWalletVault, digits: [UInt8]?, reason: String) async throws -> OathBitcoinSubmission {
        let id = UUID().uuidString
        flights.insert(id); defer { flights.remove(id) }
        let db = try await vault.database()
        var stage = "reserve"
        var acknowledgedSubmission: OathBitcoinSubmission?
        var rejectedSubmission = false
        do {
            try quote.plan.validate()
            let prepare: @Sendable () async throws -> Void = {
                try await OathSendPreparation.run(chain: "polkadot", reserve: {
                    let now = Date.now.timeIntervalSince1970
                    try await db.saveDraft(.init(id:id,walletID:quote.walletID,accountID:quote.accountID,networkID:"polkadot",assetID:quote.assetID,
                        idempotencyKey:id,recipient:quote.plan.recipient,amountAtomic:String(quote.plan.amount),state:"draft",createdAt:now,updatedAt:now))
                    try await db.queuePolkadotSend(sendID:id,plan:quote.plan)
                }, validate: { try await self.connection().preflight(quote.plan) })
            }
            stage = "authenticate"
            let signed = try await vault.signPolkadotSend(sendID:id,quote:quote,digits:digits,reason:reason, prepare: prepare)
            try Task.checkCancellation()
            stage = "persist"
            try await db.journalPolkadotSignature(sendID:id,signed:signed)
            _ = try await db.transitionSend(id,from:"signed",to:"broadcast")
            stage = "broadcast"
            let receipt = try await connection().submit(signed,plan:quote.plan,reconcileFirst:false)
            if receipt.outcome == .accepted || receipt.outcome == .confirmed { acknowledgedSubmission = .init(txid: signed.hash, accepted: true) }
            rejectedSubmission = receipt.outcome == .failed || receipt.outcome == .expired
            try await db.settlePolkadotSend(sendID:id,receipt:receipt)
            await OathPostSendBalanceRefresh.shared.submitted(walletID:quote.walletID,networkID:"polkadot")
            guard receipt.outcome != .failed && receipt.outcome != .expired else { throw PolkadotSendError.execution }
            return .init(txid:signed.hash,accepted:receipt.outcome == .accepted || receipt.outcome == .confirmed)
        } catch {
            OathDiagnostics.record(error,component:"polkadot_send",operation:stage,context:["chain":"polkadot","stage":stage])
            if let acknowledgedSubmission { return acknowledgedSubmission }
            if rejectedSubmission { throw error }
            if let stored = await OathDiagnostics.attemptOptional("polkadot_send_state",body:{ try await db.send(id) }) {
                if ["queued","draft"].contains(stored.state) {
                    _ = await OathDiagnostics.attempt("polkadot_send_cancel",body:{ try await db.transitionSend(id,from:stored.state,to:"cancelled") })
                } else if ["signed","broadcast"].contains(stored.state), let payload = stored.signedPayload {
                    let signed = try JSONDecoder().decode(PolkadotSignedSend.self,from:payload)
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
        try await OathDiagnostics.$chain.withValue("polkadot") {
            try await OathDiagnostics.$operationID.withValue(UUID()) {
                do {
                    try await database.reconcilePolkadotSend(send.id, client: connection())
                } catch {
                    OathDiagnostics.record(error,component:"polkadot_send",operation:"status",context:["chain":"polkadot","stage":"status"])
                    throw error
                }
            }
        }
    }
}
