import Foundation
import OathAnkr
import OathDatabase
import OathDiagnostics

struct OathXrplQuote: Sendable, Equatable {
    let walletID: String, accountID: String, assetID: String
    let plan: XrplSendPlan
}

/// App-lifetime submission owner. Authentication is separate from preparation;
/// exact signed bytes are journaled before any broadcast and survive dismissal.
actor OathXrplSendService {
    static let shared = OathXrplSendService()
    private var client: XrplSendClient?
    private var flights = Set<String>()
    private func connection() throws -> XrplSendClient {
        if let client { return client }
        let value = try OathTokenRPCConfiguration.bundled().makeXrplSendClient()
        client = value; return value
    }
    func quote(walletID: String, accountID: String, assetID: String, reference: String,
               recipient: String, amount: String, destinationTag: UInt32?, maximum: Bool, closure: XrplSendPlan? = nil, vault: OathWalletVault) async throws -> OathXrplQuote {
        let database = try await vault.database()
        guard let account = try await database.accounts(walletID:walletID).first(where:{$0.id == accountID && $0.networkID == "xrpl"}) else { throw XrplSendError.wrongOwner }
        if let closure {
            guard try await vault.xrplMultisigPolicy(walletID:walletID) == nil else { throw XrplSendError.closureUnavailable }
            guard closure.closesAccount, maximum, reference == "native", closure.sender == account.address,
                  closure.recipient == recipient, closure.destinationTag == destinationTag, closure.amount == amount else { throw XrplSendError.changed }
            try await connection().revalidateAccountClosure(closure)
            return .init(walletID:walletID,accountID:accountID,assetID:assetID,plan:closure)
        }
        let policy = try await vault.xrplMultisigPolicy(walletID:walletID)
        let plan = try await connection().quote(sender:account.address,recipient:recipient,reference:reference,amount:amount,destinationTag:destinationTag,maximum:maximum,multisig:policy)
        return .init(walletID:walletID,accountID:accountID,assetID:assetID,plan:plan)
    }
    func multisigSetup(walletID: String, vault: OathWalletVault) async throws -> (String, XrplMultisigState, OathXrplQuote?, Bool) {
        try await OathDiagnostics.$chain.withValue("xrpl") {
            try await OathDiagnostics.$operationID.withValue(UUID()) {
                do {
                    let db = try await vault.database()
                    guard let policy = try await vault.xrplMultisigPolicy(walletID: walletID),
                          let account = try await db.accounts(walletID:walletID).first(where: {$0.networkID == "xrpl"}),
                          let asset = try await db.asset(networkID:"xrpl",reference:"native") else { throw XrplSendError.wrongOwner }
                    let client = try connection()
                    if let pending = try await db.pendingXrplMultisigSetup(walletID:walletID) { try await check(send:pending,database:db) }
                    let state = try await client.multisigState(policy)
                    let pending = try await db.pendingXrplMultisigSetup(walletID:walletID) != nil
                    guard !pending, !state.configured else { return (account.address,state,nil,pending) }
                    let plan = try await client.quoteMultisigSetup(policy)
                    return (account.address,state,plan.map { .init(walletID:walletID,accountID:account.id,assetID:asset.id,plan:$0) },false)
                } catch {
                    OathDiagnostics.record(error,component:"xrpl_send",operation:"multisig_setup",context:["chain":"xrpl"])
                    throw error
                }
            }
        }
    }
    func tokenAuthorization(walletID: String, reference: String, limit: String, vault: OathWalletVault) async throws -> OathXrplQuote {
        try await OathDiagnostics.$chain.withValue("xrpl") {
            try await OathDiagnostics.$operationID.withValue(UUID()) {
                do {
                    let db = try await vault.database()
                    guard let policy = try await vault.xrplMultisigPolicy(walletID:walletID),
                          let account = try await db.accounts(walletID:walletID).first(where: {$0.networkID == "xrpl"}),
                          let asset = try await db.asset(networkID:"xrpl",reference:"native") else { throw XrplSendError.wrongOwner }
                    let plan = try await connection().quoteTokenAuthorization(policy,reference:reference,limit:limit)
                    return .init(walletID:walletID,accountID:account.id,assetID:asset.id,plan:plan)
                } catch {
                    // An existing opt-in is an expected form outcome, not a failed transaction.
                    if (error as? XrplSendError) != .tokenAlreadyEnabled {
                        OathDiagnostics.record(error,component:"xrpl_send",operation:"token_authorization",context:["chain":"xrpl"])
                    }
                    throw error
                }
            }
        }
    }
    func closureOffer(walletID: String, accountID: String, recipient: String, destinationTag: UInt32?, vault: OathWalletVault) async throws -> XrplSendPlan {
        let db = try await vault.database()
        guard try await vault.xrplMultisigPolicy(walletID:walletID) == nil else { throw XrplSendError.closureUnavailable }
        guard let account = try await db.accounts(walletID:walletID).first(where:{$0.id == accountID && $0.networkID == "xrpl"}) else { throw XrplSendError.wrongOwner }
        return try await connection().quoteAccountClosure(sender:account.address,recipient:recipient,destinationTag:destinationTag)
    }
    func submit(_ quote: OathXrplQuote, vault: OathWalletVault, digits: [UInt8]?, reason: String) async throws -> OathBitcoinSubmission {
        try await OathDiagnostics.$chain.withValue("xrpl") {
            try await OathDiagnostics.$operationID.withValue(UUID()) {
                try await submitWithDiagnostics(quote,vault:vault,digits:digits,reason:reason)
            }
        }
    }
    private func submitWithDiagnostics(_ quote: OathXrplQuote, vault: OathWalletVault, digits: [UInt8]?, reason: String) async throws -> OathBitcoinSubmission {
        let id = UUID().uuidString
        flights.insert(id); defer { flights.remove(id) }
        let db = try await vault.database()
        var stage = "reserve"
        var acknowledgedSubmission: OathBitcoinSubmission?
        var rejectedSubmission = false
        do {
            try quote.plan.validate()
            let prepare: @Sendable () async throws -> Void = {
                try await OathSendPreparation.run(chain: "xrpl", reserve: {
                    let now = Date.now.timeIntervalSince1970
                    try await db.saveDraft(.init(id:id,walletID:quote.walletID,accountID:quote.accountID,networkID:"xrpl",assetID:quote.assetID,
                        idempotencyKey:id,recipient:quote.plan.recipient,amountAtomic:String(quote.plan.amount),state:"draft",createdAt:now,updatedAt:now))
                    try await db.queueXrplSend(sendID:id,plan:quote.plan)
                }, validate: {})
            }
            stage = "authenticate"
            let signed = try await vault.signXrplSend(sendID:id,quote:quote,digits:digits,reason:reason, prepare: prepare)
            try Task.checkCancellation()
            if quote.plan.closesAccount {
                // Recheck after authentication, before journaling a sendable signature.
                stage = "closure_recheck"
                try await connection().revalidateAccountClosure(quote.plan)
                try Task.checkCancellation()
            }
            stage = "persist"
            try await db.journalXrplSignature(sendID:id,signed:signed)
            _ = try await db.transitionSend(id,from:"signed",to:"broadcast")
            stage = "broadcast"
            let receipt = try await connection().submit(signed,plan:quote.plan,reconcileFirst:false)
            if receipt.outcome == .accepted || receipt.outcome == .confirmed { acknowledgedSubmission = .init(txid: signed.hash, accepted: true) }
            rejectedSubmission = !(receipt.outcome != .failed && receipt.outcome != .expired)
            try await db.settleXrplSend(sendID:id,receipt:receipt)
            await OathPostSendBalanceRefresh.shared.submitted(walletID:quote.walletID,networkID:"xrpl")
            guard receipt.outcome != .failed && receipt.outcome != .expired else { throw XrplSendError.execution("validatedFailure") }
            return .init(txid:signed.hash,accepted:receipt.outcome == .accepted || receipt.outcome == .confirmed)
        } catch {
            OathDiagnostics.record(error,component:"xrpl_send",operation:stage,context:["chain":"xrpl","stage":stage])
            if let acknowledgedSubmission { return acknowledgedSubmission }
            if rejectedSubmission { throw error }
            if let stored = await OathDiagnostics.attemptOptional("xrpl_send_state",body:{ try await db.send(id) }) {
                if ["queued","draft"].contains(stored.state) {
                    _ = await OathDiagnostics.attempt("xrpl_send_cancel",body:{ try await db.transitionSend(id,from:stored.state,to:"cancelled") })
                } else if ["signed","broadcast"].contains(stored.state), let payload = stored.signedPayload {
                    let signed = try JSONDecoder().decode(XrplSignedSend.self,from:payload)
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
        try await database.reconcileXrplSend(send.id, client: connection())
    }
}
