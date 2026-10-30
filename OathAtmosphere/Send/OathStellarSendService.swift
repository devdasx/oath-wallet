import Foundation
import OathAnkr
import OathDatabase
import OathDiagnostics

struct OathStellarQuote: Sendable, Equatable {
    let walletID: String, accountID: String, assetID: String
    let plan: StellarSendPlan
}

/// App-lifetime submission owner. Authentication is separate from preparation;
/// exact signed bytes are journaled before any broadcast and survive dismissal.
actor OathStellarSendService {
    static let shared = OathStellarSendService()
    private var client: StellarSendClient?
    private var flights = Set<String>()
    private func connection() throws -> StellarSendClient {
        if let client { return client }
        let value = try OathTokenRPCConfiguration.bundled().makeStellarSendClient()
        client = value; return value
    }
    func quote(walletID: String, accountID: String, assetID: String, reference: String,
               recipient: String, amount: String, decimals: Int, memo: StellarSendMemo, maximum: Bool, vault: OathWalletVault) async throws -> OathStellarQuote {
        let database = try await vault.database()
        guard let account = try await database.accounts(walletID:walletID).first(where:{$0.id == accountID && $0.networkID == "stellar"}) else { throw StellarSendError.wrongOwner }
        let policy = try await vault.stellarMultisigPolicy(walletID: walletID)
        let plan = try await connection().quote(sender:account.address,recipient:recipient,reference:reference,decimals:decimals,amount:amount,memo:memo,maximum:maximum,multisig:policy)
        return .init(walletID:walletID,accountID:accountID,assetID:assetID,plan:plan)
    }
    func multisigSetup(walletID: String, vault: OathWalletVault) async throws -> (String, StellarMultisigState, OathStellarQuote?, Bool) {
        try await OathDiagnostics.$chain.withValue("stellar") {
            try await OathDiagnostics.$operationID.withValue(UUID()) {
                do { return try await multisigSetupWithContext(walletID: walletID, vault: vault) }
                catch {
                    if error is CancellationError || Task.isCancelled { throw CancellationError() }
                    OathDiagnostics.record(error, component: "stellar_send", operation: "multisigSetup", context: ["chain": "stellar"])
                    throw error
                }
            }
        }
    }
    private func multisigSetupWithContext(walletID: String, vault: OathWalletVault) async throws -> (String, StellarMultisigState, OathStellarQuote?, Bool) {
        let db = try await vault.database()
        guard let policy = try await vault.stellarMultisigPolicy(walletID: walletID),
              let account = try await db.accounts(walletID:walletID).first(where: { $0.networkID == "stellar" }),
              let asset = try await db.asset(networkID:"stellar", reference:"native") else { throw StellarSendError.wrongOwner }
        if let pending = try await db.pendingStellarMultisigSetup(walletID:walletID) { try await check(send:pending,database:db) }
        let state = try await connection().multisigState(policy)
        let pending = try await db.pendingStellarMultisigSetup(walletID:walletID) != nil
        guard !state.configured, !pending, state.balance > state.reserve else { return (account.address, state, nil, pending) }
        let plan = try await connection().configurationQuote(policy:policy)
        return (account.address, state, .init(walletID:walletID,accountID:account.id,assetID:asset.id,plan:plan), false)
    }
    func tokenAuthorization(walletID: String, code: String, issuer: String, vault: OathWalletVault) async throws -> OathStellarQuote {
        try await OathDiagnostics.$chain.withValue("stellar") {
            try await OathDiagnostics.$operationID.withValue(UUID()) {
                do { return try await tokenAuthorizationWithContext(walletID: walletID, code: code, issuer: issuer, vault: vault) }
                catch {
                    if error is CancellationError || Task.isCancelled { throw CancellationError() }
                    OathDiagnostics.record(error, component: "stellar_send", operation: "tokenAuthorization", context: ["chain": "stellar"])
                    throw error
                }
            }
        }
    }
    private func tokenAuthorizationWithContext(walletID: String, code: String, issuer: String, vault: OathWalletVault) async throws -> OathStellarQuote {
        let db = try await vault.database()
        guard let policy = try await vault.stellarMultisigPolicy(walletID:walletID),
              let account = try await db.accounts(walletID:walletID).first(where: { $0.networkID == "stellar" }),
              let asset = try await db.asset(networkID:"stellar",reference:"native") else { throw StellarSendError.wrongOwner }
        let plan = try await connection().configurationQuote(policy:policy,assetCode:code,issuer:issuer)
        return .init(walletID:walletID,accountID:account.id,assetID:asset.id,plan:plan)
    }
    func submit(_ quote: OathStellarQuote, vault: OathWalletVault, digits: [UInt8]?, reason: String) async throws -> OathBitcoinSubmission {
        try await OathDiagnostics.$chain.withValue("stellar") {
            try await OathDiagnostics.$operationID.withValue(UUID()) {
                try await submitWithDiagnostics(quote,vault:vault,digits:digits,reason:reason)
            }
        }
    }
    private func submitWithDiagnostics(_ quote: OathStellarQuote, vault: OathWalletVault, digits: [UInt8]?, reason: String) async throws -> OathBitcoinSubmission {
        let id = UUID().uuidString
        flights.insert(id); defer { flights.remove(id) }
        let db = try await vault.database()
        var stage = "reserve"
        var acknowledgedSubmission: OathBitcoinSubmission?
        var rejectedSubmission = false
        do {
            try quote.plan.validate()
            let prepare: @Sendable () async throws -> Void = {
                try await OathSendPreparation.run(chain: "stellar", reserve: {
                    let now = Date.now.timeIntervalSince1970
                    try await db.saveDraft(.init(id:id,walletID:quote.walletID,accountID:quote.accountID,networkID:"stellar",assetID:quote.assetID,
                        idempotencyKey:id,recipient:quote.plan.recipient,amountAtomic:String(quote.plan.amount),state:"draft",createdAt:now,updatedAt:now))
                    try await db.queueStellarSend(sendID:id,plan:quote.plan)
                }, validate: {})
            }
            stage = "authenticate"
            let signed = try await vault.signStellarSend(sendID:id,quote:quote,digits:digits,reason:reason, prepare: prepare)
            try Task.checkCancellation()
            stage = "persist"
            try await db.journalStellarSignature(sendID:id,signed:signed)
            _ = try await db.transitionSend(id,from:"signed",to:"broadcast")
            stage = "broadcast"
            let receipt = try await connection().submit(signed,plan:quote.plan,reconcileFirst:false)
            if receipt.outcome == .accepted || receipt.outcome == .confirmed { acknowledgedSubmission = .init(txid: signed.hash, accepted: true) }
            rejectedSubmission = !(receipt.outcome != .failed && receipt.outcome != .expired)
            try await db.settleStellarSend(sendID:id,receipt:receipt)
            await OathPostSendBalanceRefresh.shared.submitted(walletID:quote.walletID,networkID:"stellar")
            guard receipt.outcome != .failed && receipt.outcome != .expired else { throw StellarSendError.execution }
            return .init(txid:signed.hash,accepted:receipt.outcome == .accepted || receipt.outcome == .confirmed)
        } catch {
            OathDiagnostics.record(error,component:"stellar_send",operation:stage,context:["chain":"stellar","stage":stage])
            if let acknowledgedSubmission { return acknowledgedSubmission }
            if rejectedSubmission { throw error }
            if let stored = await OathDiagnostics.attemptOptional("stellar_send_state",body:{ try await db.send(id) }) {
                if ["queued","draft"].contains(stored.state) {
                    _ = await OathDiagnostics.attempt("stellar_send_cancel",body:{ try await db.transitionSend(id,from:stored.state,to:"cancelled") })
                } else if ["signed","broadcast"].contains(stored.state), let payload = stored.signedPayload {
                    let signed = try JSONDecoder().decode(StellarSignedSend.self,from:payload)
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
        try await database.reconcileStellarSend(send.id, client: connection())
    }
}
