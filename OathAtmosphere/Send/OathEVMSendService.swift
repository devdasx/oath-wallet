import Foundation
import OathAnkr
import OathDatabase
import OathDiagnostics

struct OathEVMQuote: Sendable, Equatable {
    let walletID: String, accountID: String, assetID: String
    let plan: EVMSendPlan
}

/// App-lifetime submission owner. Authentication is separate from preparation;
/// exact signed bytes are journaled before any broadcast and survive dismissal.
actor OathEVMSendService {
    static let shared = OathEVMSendService()
    private var clients: [EVMSendNetwork: EVMSendClient] = [:]
    private var flights = Set<String>()
    init(clients: [EVMSendNetwork: EVMSendClient] = [:]) { self.clients = clients }
    func connection(_ network:EVMSendNetwork) throws -> EVMSendClient {
        if let client=clients[network] { return client }
        let value=try OathTokenRPCConfiguration.bundled().makeEVMSendClient(network:network)
        clients[network]=value;return value
    }
    func walletConnectQuote(_ request: WalletConnectEVMRequest, requestID: String, walletID: String,
                            accountID: String, vault: OathWalletVault) async throws -> OathEVMQuote {
        guard let network = EVMSendNetwork.allCases.first(where: { $0.chainID == request.chainID && !$0.isTestnet }),
              Self.validRequestID(requestID) else { throw EVMSendError.wrongNetwork }
        let db = try await vault.database()
        guard let account = try await db.accounts(walletID: walletID).first(where: { $0.id == accountID }),
              account.networkID == network.rawValue, try EVMSendIdentity.address(account.address) == request.sender else { throw EVMSendError.wrongOwner }
        if let send = try await db.send(requestID), send.signedPayload != nil {
            guard send.walletID == walletID, send.accountID == accountID,
                  let plan = try await db.evmSendPlan(sendID: requestID),
                  request.matches(plan) || request.matchesCommittedApproval(plan) else { throw EVMSendError.changed }
            return .init(walletID: walletID, accountID: accountID, assetID: send.assetID, plan: plan)
        }
        let plan = try await connection(network).quote(sender: request.sender, recipient: request.recipient,
            reference: "native", decimals: 18, amount: request.value, request: request)
        guard request.matches(plan) else { throw EVMSendError.changed }
        return .init(walletID: walletID, accountID: accountID, assetID: network.rawValue + ":native", plan: plan)
    }
    func walletConnectApprovalToken(_ request: WalletConnectEVMRequest) async throws -> WalletConnectApprovalToken? {
        guard let network = EVMSendNetwork.allCases.first(where: { $0.chainID == request.chainID && !$0.isTestnet }) else { throw EVMSendError.wrongNetwork }
        return try await connection(network).walletConnectApprovalToken(request)
    }
    private static func validRequestID(_ id: String) -> Bool {
        id.hasPrefix("wc:") && id.count == 67 && id.dropFirst(3).allSatisfy { $0.isASCII && $0.isHexDigit }
    }
    func quote(network:EVMSendNetwork,walletID: String, accountID: String, assetID: String, reference: String,
               recipient: String, amount: String, decimals: Int, maximum: Bool, vault: OathWalletVault) async throws -> OathEVMQuote {
        try await OathDiagnostics.$chain.withValue(network.rawValue) {
            try await OathDiagnostics.$operationID.withValue(UUID()) {
                do {
                    let database = try await vault.database()
                    guard let account = try await database.accounts(walletID:walletID).first(where:{$0.id == accountID && $0.networkID == network.rawValue}) else { throw EVMSendError.wrongOwner }
                    let plan = try await connection(network).quote(sender:account.address,recipient:recipient,reference:reference,decimals:decimals,amount:amount,maximum:maximum)
                    return .init(walletID:walletID,accountID:accountID,assetID:assetID,plan:plan)
                } catch {
                    OathDiagnostics.record(error,component:"evm_send",operation:"quote",context:["chain":network.rawValue])
                    throw error
                }
            }
        }
    }

    func submit(_ quote: OathEVMQuote, vault: OathWalletVault, digits: [UInt8]?, reason: String,
                walletConnectRequestID: String? = nil,
                permissionSendID: String? = nil, permissionAuthorization: UUID? = nil,
                authorization: (@Sendable () async throws -> Void)? = nil) async throws -> OathBitcoinSubmission {
        try await OathDiagnostics.$chain.withValue(quote.plan.network.rawValue) {
            try await OathDiagnostics.$operationID.withValue(UUID()) {
                try await submitWithDiagnostics(quote,vault:vault,digits:digits,reason:reason,requestID:walletConnectRequestID,authorization:authorization,permissionSendID:permissionSendID,permissionAuthorization:permissionAuthorization)
            }
        }
    }
    private func submitWithDiagnostics(_ quote: OathEVMQuote, vault: OathWalletVault, digits: [UInt8]?, reason: String,
                                       requestID: String?, authorization: (@Sendable () async throws -> Void)?,
                                       permissionSendID: String?, permissionAuthorization: UUID?) async throws -> OathBitcoinSubmission {
        let id = permissionSendID ?? requestID ?? UUID().uuidString
        guard permissionSendID == nil || (requestID == nil && permissionAuthorization != nil && quote.plan.removal != nil && UUID(uuidString:id) != nil) else { throw PermissionError.changed }
        guard requestID == nil || Self.validRequestID(id) else { throw EVMSendError.changed }
        guard flights.insert(id).inserted else { throw EVMSendError.busy }
        defer { flights.remove(id) }
        let db = try await vault.database()
        if permissionSendID != nil, try await db.send(id) != nil { throw PermissionError.changed }
        var stage = "reserve"
        var canRecoverSigned = false
        var committedSignature: EVMSignedSend?
        do {
            try await authorization?()
            if requestID != nil {
                guard authorization != nil, quote.plan.call != nil else { throw EVMSendError.changed }
                if let stored = try await db.send(id), let bytes = stored.signedPayload {
                    guard stored.walletID==quote.walletID,stored.accountID==quote.accountID,
                          let plan=try await db.evmSendPlan(sendID:id),plan.network==quote.plan.network,
                          plan.sender==quote.plan.sender,plan.recipient==quote.plan.recipient,
                          plan == quote.plan else { throw EVMSendError.changed }
                    let signed=try JSONDecoder().decode(EVMSignedSend.self,from:bytes)
                    try EVMSendCrypto.verify(signed,plan:plan)
                    // Confirmation is reconciled by the existing durable worker.
                    // Reopening a request never signs a new nonce or new bytes.
                    return .init(txid:signed.hash,accepted:stored.state=="confirmed")
                }
                try await db.resetUnsentWalletConnectEVM(id,walletID:quote.walletID,accountID:quote.accountID)
            }
            try quote.plan.validate()
            let now = Date.now.timeIntervalSince1970
            try await db.saveDraft(.init(id:id,walletID:quote.walletID,accountID:quote.accountID,networkID:quote.plan.network.rawValue,assetID:quote.assetID,
                idempotencyKey:id,recipient:quote.plan.recipient,amountAtomic:String(quote.plan.amount),state:"draft",createdAt:now,updatedAt:now))
            canRecoverSigned = true
            try await db.queueEVMSend(sendID:id,plan:quote.plan)
            stage = "preflight"
            // Network revalidation and local authorization are independent.
            // Structured concurrency cancels validation if authentication fails.
            async let validated: Void = connection(quote.plan.network).preflight(quote.plan)
            stage = "authenticate"
            let signed = try await vault.signEVMSend(sendID:id,quote:quote,digits:digits,reason:reason,permissionAuthorization:permissionAuthorization)
            stage = "preflight"
            try await validated
            try Task.checkCancellation()
            if quote.plan.removal != nil {
                stage = "permission_recheck"
                try await connection(quote.plan.network).preflight(quote.plan)
                try Task.checkCancellation()
            }
            try await authorization?()
            try Task.checkCancellation()
            stage = "persist"
            try await db.journalEVMSignature(sendID:id,signed:signed)
            committedSignature = signed
            _ = try await db.transitionSend(id,from:"signed",to:"broadcast")
            stage = "broadcast"
            let receipt = try await connection(quote.plan.network).submit(signed,plan:quote.plan,reconcileFirst:false)
            try await db.settleEVMSend(sendID:id,receipt:receipt)
            await OathPostSendBalanceRefresh.shared.submitted(walletID:quote.walletID,networkID:quote.plan.network.rawValue)
            guard receipt.outcome != .failed && receipt.outcome != .cancelled && receipt.outcome != .replaced else { throw EVMSendError.execution }
            return .init(txid:signed.hash,accepted:receipt.outcome == .confirmed || receipt.outcome == .accepted)
        } catch {
            OathDiagnostics.record(error,component:"evm_send",operation:stage,context:["chain":quote.plan.network.rawValue,"stage":stage])
            // Once bytes are committed, cancellation only stops this attempt.
            // The durable worker still owns them; never report an unsigned
            // rejection just because the presenting view/task disappeared.
            if let committedSignature { return .init(txid: committedSignature.hash, accepted: false) }
            let recovery = canRecoverSigned ? await Task {
                await OathDiagnostics.attemptOptional("evm_send_state",body:{ try await db.send(id) })
            }.value : nil
            if let stored = recovery {
                if ["queued","draft"].contains(stored.state) {
                    _ = await OathDiagnostics.attempt("evm_send_cancel",body:{ try await db.transitionSend(id,from:stored.state,to:"cancelled") })
                } else if canRecoverSigned, ["signed","broadcast"].contains(stored.state), let payload = stored.signedPayload {
                    let signed = try JSONDecoder().decode(EVMSignedSend.self,from:payload)
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
        guard let network=EVMSendNetwork(rawValue:send.networkID),!network.isTestnet else { throw EVMSendError.wrongNetwork }
        try await database.reconcileEVMSend(send.id, client: connection(network))
    }
}
