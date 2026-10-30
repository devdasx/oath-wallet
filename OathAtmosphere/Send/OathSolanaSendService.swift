import Foundation
import OathAnkr
import OathDatabase
import OathDiagnostics

struct OathSolanaQuote: Sendable, Equatable {
    let walletID: String, accountID: String, assetID: String
    let plan: SolanaSendPlan
}

/// App-lifetime submission owner. Authentication is separate from preparation;
/// exact signed bytes are journaled before any broadcast and survive dismissal.
actor OathSolanaSendService {
    static let shared = OathSolanaSendService()
    private var client: SolanaSendClient?
    private var flights = Set<String>()
    private func connection() throws -> SolanaSendClient {
        if let client { return client }
        let value = try OathTokenRPCConfiguration.bundled().makeSolanaSendClient()
        client = value; return value
    }
    func quote(walletID: String, accountID: String, assetID: String, reference: String,
               recipient: String, amount: String, decimals: Int, maximum: Bool, memo: String, paymentReferences: [String] = [], vault: OathWalletVault) async throws -> OathSolanaQuote {
        try await OathDiagnostics.$chain.withValue("solana") {
            try await OathDiagnostics.$operationID.withValue(UUID()) {
                do {
                    let database = try await vault.database()
                    guard let account = try await database.account(accountID) else { throw SolanaSendError.wrongOwner }
                    guard account.walletID==walletID,account.networkID=="solana" else { throw SolanaSendError.wrongOwner }
                    let selected = try await database.solanaSigningAccount(accountID:accountID)
                    let plan: SolanaSendPlan
                    if let policy = try await vault.solanaMultisigPolicy(walletID: walletID) {
                        guard try policy.vault == selected.address else { throw SolanaSendError.wrongOwner }
                        plan = try await connection().quoteMultisig(policy, recipient:recipient, reference:reference, decimals:decimals, amount:amount, maximum:maximum, memo:memo, paymentReferences:paymentReferences)
                    } else {
                        plan = try await connection().quote(sender:selected.address,recipient:recipient,reference:reference,decimals:decimals,amount:amount,maximum:maximum,memo:memo,paymentReferences:paymentReferences)
                    }
                    return .init(walletID:walletID,accountID:accountID,assetID:assetID,plan:plan)
                } catch {
                    OathDiagnostics.record(error,component:"solana_send",operation:"quote",context:["chain":"solana"])
                    throw error
                }
            }
        }
    }

    func multisigSetup(walletID: String, vault: OathWalletVault) async throws -> (String, SolanaMultisigState, OathSolanaQuote?, Bool) {
        try await OathDiagnostics.$chain.withValue("solana") {
            try await OathDiagnostics.$operationID.withValue(UUID()) {
                do {
                    let db = try await vault.database()
                    guard let policy = try await vault.solanaMultisigPolicy(walletID: walletID),
                          let account = try await db.accounts(walletID: walletID).first(where: { $0.networkID == "solana" }),
                          let asset = try await db.asset(networkID: "solana", reference: "native") else { throw SolanaSendError.wrongOwner }
                    let client = try connection()
                    // The journal is authoritative across screen dismissal and restart.
                    let pending = try await db.pendingSolanaMultisigSetup(walletID: walletID)
                    if let pending { try await check(send: pending, database: db) }
                    let state = try await client.multisigState(policy)
                    let stillPending = try await db.pendingSolanaMultisigSetup(walletID: walletID) != nil
                    guard !state.configured, !stillPending, state.balance >= state.setupCost else {
                        return (state.payer, state, nil, stillPending)
                    }
                    let plan: SolanaSendPlan
                    do {
                        plan = try await client.quoteMultisigSetup(policy)
                    } catch SolanaSendError.multisigFunding {
                        // diagnostics: multisig-funding-incomplete
                        // The payer balance may change between the status read and quote.
                        // Insufficient funding is expected form state, not an app failure.
                        return (state.payer, state, nil, false)
                    }
                    return (plan.multisig?.payer ?? state.payer, state, .init(walletID: walletID, accountID: account.id, assetID: asset.id, plan: plan), false)
                } catch {
                    OathDiagnostics.record(error, component: "solana_send", operation: "multisig_setup", context: ["chain": "solana"])
                    throw error
                }
            }
        }
    }

    func submit(_ quote: OathSolanaQuote, vault: OathWalletVault, digits: [UInt8]?, reason: String, permissionSendID: String? = nil, permissionAuthorization: UUID? = nil) async throws -> OathBitcoinSubmission {
        try await OathDiagnostics.$chain.withValue("solana") {
            try await OathDiagnostics.$operationID.withValue(UUID()) {
                try await submitWithDiagnostics(quote,vault:vault,digits:digits,reason:reason,permissionSendID:permissionSendID,permissionAuthorization:permissionAuthorization)
            }
        }
    }
    private func submitWithDiagnostics(_ quote: OathSolanaQuote, vault: OathWalletVault, digits: [UInt8]?, reason: String, permissionSendID: String?, permissionAuthorization: UUID?) async throws -> OathBitcoinSubmission {
        let id = permissionSendID ?? UUID().uuidString
        guard permissionSendID == nil || (permissionAuthorization != nil && quote.plan.removal != nil && UUID(uuidString:id) != nil) else { throw PermissionError.changed }
        guard flights.insert(id).inserted else { throw PermissionError.changed }; defer { flights.remove(id) }
        let db = try await vault.database()
        if permissionSendID != nil, try await db.send(id) != nil { throw PermissionError.changed }
        var stage = "reserve"
        var acknowledgedSubmission: OathBitcoinSubmission?
        var rejectedSubmission = false
        do {
            try quote.plan.validate()
            let prepare: @Sendable () async throws -> Void = {
                try await OathSendPreparation.run(chain: "solana", reserve: {
                    let now = Date.now.timeIntervalSince1970
                    try await db.saveDraft(.init(id:id,walletID:quote.walletID,accountID:quote.accountID,networkID:"solana",assetID:quote.assetID,
                        idempotencyKey:id,recipient:quote.plan.recipient,amountAtomic:String(quote.plan.amount),state:"draft",createdAt:now,updatedAt:now))
                    try await db.queueSolanaSend(sendID:id,plan:quote.plan)
                }, validate: { try await self.connection().preflight(quote.plan) })
            }
            stage = "authenticate"
            let signed = try await vault.signSolanaSend(sendID:id,quote:quote,digits:digits,reason:reason,permissionAuthorization:permissionAuthorization, prepare: prepare)
            try Task.checkCancellation()
            if quote.plan.removal != nil {
                stage = "permission_recheck"
                try await connection().preflight(quote.plan)
                try Task.checkCancellation()
            }
            stage = "persist"
            try await db.journalSolanaSignature(sendID:id,signed:signed)
            _ = try await db.transitionSend(id,from:"signed",to:"broadcast")
            stage = "broadcast"
            let receipt = try await connection().submit(signed,plan:quote.plan,reconcileFirst:false)
            if receipt.outcome == .confirmed || receipt.outcome == .accepted { acknowledgedSubmission = .init(txid: signed.hash, accepted: true) }
            rejectedSubmission = !(receipt.outcome != .failed && receipt.outcome != .expired)
            try await db.settleSolanaSend(sendID:id,receipt:receipt)
            await OathPostSendBalanceRefresh.shared.submitted(walletID:quote.walletID,networkID:"solana")
            guard receipt.outcome != .failed && receipt.outcome != .expired else { throw SolanaSendError.execution }
            return .init(txid:signed.hash,accepted:receipt.outcome == .confirmed || receipt.outcome == .accepted)
        } catch {
            OathDiagnostics.record(error,component:"solana_send",operation:stage,context:["chain":"solana","stage":stage])
            if let acknowledgedSubmission { return acknowledgedSubmission }
            if rejectedSubmission { throw error }
            if let stored = await OathDiagnostics.attemptOptional("solana_send_state",body:{ try await db.send(id) }) {
                if ["queued","draft"].contains(stored.state) {
                    _ = await OathDiagnostics.attempt("solana_send_cancel",body:{ try await db.transitionSend(id,from:stored.state,to:"cancelled") })
                } else if ["signed","broadcast"].contains(stored.state), let payload = stored.signedPayload {
                    let signed = try JSONDecoder().decode(SolanaSignedSend.self,from:payload)
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
        try await database.reconcileSolanaSend(send.id, client: connection())
    }
}
