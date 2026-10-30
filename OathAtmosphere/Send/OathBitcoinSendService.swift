import OathDiagnostics
import Foundation
import OathBitcoin
import OathDatabase

struct OathBitcoinQuote: Sendable, Equatable {
    let walletID: String
    let accountID: String
    let plan: BitcoinSendPlan
}
struct OathBitcoinSubmission: Sendable {
    let txid: String
    let accepted: Bool
}

actor OathBitcoinSendService {
    static let shared = OathBitcoinSendService(network: .bitcoin)
    static let cash = OathBitcoinSendService(network: .bitcoincash)
    static let litecoin = OathBitcoinSendService(network: .litecoin)
    static let dogecoin = OathBitcoinSendService(network: .dogecoin)
    private static let fees = OathTokenRPCConfiguration.bundled().makeUTXOFeeProvider()
    static func service(for network: UTXONetwork) throws -> OathBitcoinSendService {
        switch network {
        case .bitcoin: shared
        case .bitcoincash: cash
        case .litecoin: litecoin
        case .dogecoin: dogecoin
        }
    }
    private let network: UTXONetwork
    private let broadcaster = OathTokenRPCConfiguration.bundled().makeUTXOBroadcastProvider()
    private init(network: UTXONetwork) { self.network = network }
    private var flights: Set<String> = []
    private var wallets: Set<String> = []

    private func feeRate() async throws -> Int64 {
        try await Self.fees.rate(for: network)
    }

    func quote(walletID: String, recipient: String, amount: Int64, options: BitcoinSendOptions = .init(), vault: OathWalletVault, forceRefresh: Bool = false) async throws -> OathBitcoinQuote {
        try await OathDiagnostics.$chain.withValue(network.rawValue) {
            try await OathDiagnostics.$operationID.withValue(UUID()) {
                try await quoteWithDiagnostics(walletID: walletID, recipient: recipient, amount: amount, options: options, vault: vault, forceRefresh: forceRefresh)
            }
        }
    }
    private func quoteWithDiagnostics(walletID: String, recipient: String, amount: Int64, options: BitcoinSendOptions = .init(), vault: OathWalletVault, forceRefresh: Bool) async throws -> OathBitcoinQuote {
        do {
            try options.validate(chain: network)
            // Independent of wallet/database preparation; launch at the first
            // suspension so provider latency overlaps all funding work.
            async let rate = feeRate()
            let db = try await vault.database()
            let accounts = try await db.accounts(walletID: walletID).filter { $0.networkID == network.rawValue }
            guard let first = accounts.first else { throw BitcoinSendError.invalidInput }
            try await withThrowingTaskGroup(of: Void.self) { group in
                for account in accounts { group.addTask { try await OathBitcoinSync.shared.prepareForSend(accountID: account.id, vault: vault, forceRefresh: forceRefresh) } }
                try await group.waitForAll()
            }
            try Task.checkCancellation()
            async let change = db.bitcoinChangeAddress(accountID: first.id)
            let outputs = try await db.bitcoinSpendableOutputs(walletID: walletID, network: network)
            let coins = try await outputs.asyncBitcoinCoins(database: db)
            let plan = try await BitcoinSendPlan.make(coins: coins, recipient: recipient, amount: amount,
                                                      change: change, ratePerKVByte: rate, chain: network, options: options)
            return .init(walletID: walletID, accountID: first.id, plan: plan)
        } catch {
            Task { await OathSendDiagnostics.shared.record(network: network.rawValue, stage: "quote", error: error) }
            throw error
        }
    }

    func submit(_ quote: OathBitcoinQuote, vault: OathWalletVault, digits: [UInt8]?, reason: String) async throws -> OathBitcoinSubmission {
        try await OathDiagnostics.$chain.withValue(network.rawValue) {
            try await OathDiagnostics.$operationID.withValue(UUID()) {
                try await submitWithDiagnostics(quote, vault: vault, digits: digits, reason: reason)
            }
        }
    }
    private func submitWithDiagnostics(_ quote: OathBitcoinQuote, vault: OathWalletVault, digits: [UInt8]?, reason: String) async throws -> OathBitcoinSubmission {
        guard !wallets.contains(quote.walletID) else { throw BitcoinSendError.busy }
        let id = UUID().uuidString
        wallets.insert(quote.walletID); flights.insert(id)
        defer { wallets.remove(quote.walletID); flights.remove(id) }
        let db = try await vault.database()
        var stage = "reserve"
        do {
            guard quote.plan.chain == network else { throw BitcoinError.wrongNetwork }
            try quote.plan.validate()
            let network = network
            let prepare: @Sendable () async throws -> Void = {
                try await OathSendPreparation.run(chain: quote.plan.chain.rawValue, reserve: {
                    let now = Date.now.timeIntervalSince1970
                    try await db.saveDraft(.init(id: id, walletID: quote.walletID, accountID: quote.accountID, networkID: network.rawValue, assetID: network.rawValue + ":native",
                                                idempotencyKey: id, recipient: quote.plan.recipient, amountAtomic: String(quote.plan.recipientAmount),
                                                state: "draft", createdAt: now, updatedAt: now))
                    try await db.saveBitcoinSendPlan(sendID: id, plan: quote.plan)
                    _ = try await db.queueSend(id, outputs: quote.plan.coins.map { .init(hash: $0.txid, index: $0.vout) })
                }, validate: {})
            }
            stage = "authenticate"
            let signed = try await vault.signBitcoinSend(sendID: id, quote: quote, digits: digits, reason: reason, prepare: prepare)
            stage = "persist"
            try await db.journalBitcoinSignature(sendID: id, signed: signed)
            // No network side effect occurs until the exact signed bytes have
            // been durably saved. After this point inputs are never released on
            // a timeout, cancellation, app dismissal, or transport error.
            _ = try await db.transitionSend(id, from: "signed", to: "broadcast")
            stage = "broadcast"
            let accepted = await submitPersisted(raw: signed.raw, txid: signed.txid)
            if accepted {
                _ = await OathDiagnostics.attempt("bitcoin_acknowledgement", body: { try await db.acknowledgeBitcoinSend(id, hash: signed.txid) })
                await OathPostSendBalanceRefresh.shared.submitted(walletID: quote.walletID, networkID: network.rawValue)
            }
            if !accepted { Task { await OathSendDiagnostics.shared.record(network: network.rawValue, stage: "broadcast", error: BitcoinSendError.submissionUnknown, inputCount: quote.plan.coins.count) } }
            return .init(txid: signed.txid, accepted: accepted)
        } catch {
            Task { await OathSendDiagnostics.shared.record(network: network.rawValue, stage: stage, error: error, inputCount: quote.plan.coins.count) }
            if let stored = await OathDiagnostics.attemptOptional("send", body: { try await db.send(id) }) {
                if stored.state == "queued" { _ = await OathDiagnostics.attempt("transitionSend", body: { try await db.transitionSend(id, from: "queued", to: "cancelled") }) }
                else if stored.state == "draft" { _ = await OathDiagnostics.attempt("transitionSend", body: { try await db.transitionSend(id, from: "draft", to: "cancelled") }) }
                else if let raw = stored.signedPayload, let txid = try? BitcoinTransactions.txid(raw, network: network) {
                            return .init(txid: txid, accepted: false)
                }
            }
            throw error
        }
    }

    private func submitPersisted(raw: Data, txid: String, reconcileFirst: Bool = false) async -> Bool {
        // No shared Electrum connection/lease: foreground sends and recovery use
        // bounded HTTPS attempts, then isolated servers only as a last resort.
        // Every attempt resubmits exactly the persisted bytes.
        await broadcaster.submit(raw, txid: txid, network: network, reconcileFirst: reconcileFirst)
    }

    func check(send: SendRecord, database db: OathDatabase) async throws {
        guard !flights.contains(send.id) else { return }
        try Task.checkCancellation()
        flights.insert(send.id); defer { flights.remove(send.id) }
        guard let current = try await db.send(send.id), ["signed", "broadcast"].contains(current.state) else { return }
        guard let raw = current.signedPayload, let plan = try await db.bitcoinSendPlan(sendID: send.id),
              plan.chain == network, plan.network == .mainnet else { throw BitcoinSendError.changed }
        let txid = try BitcoinTransactions.txid(raw, network: network)
        if current.state == "signed" { _ = try await db.transitionSend(send.id, from: "signed", to: "broadcast") }
        let peer = ElectrumPool(network: network)
        do {
            let receipt = try await BitcoinSendStatus.confirmation(raw: raw, plan: plan, client: peer)
            await peer.close()
            if let receipt { try await db.settleBitcoinSend(send.id, confirmation: receipt) }
            else if await submitPersisted(raw: raw, txid: txid, reconcileFirst: true) {
                try await db.acknowledgeBitcoinSend(send.id, hash: txid)
            }
        } catch {
            OathDiagnostics.record(error, component: "send", operation: "bitcoin_status", context: ["chain": network.rawValue])
            await peer.close()
            throw error
        }
    }
}

private extension Array where Element == BitcoinSpendableOutput {
    func asyncBitcoinCoins(database: OathDatabase) async throws -> [BitcoinSendCoin] {
        var states: [String: BitcoinAccountState] = [:]
        for id in Set(map { $0.output.accountID }) {
            guard let state = try await database.bitcoinState(accountID: id) else { throw BitcoinSendError.invalidInput }
            states[id] = state
        }
        return map { item in
            let branch = states[item.output.accountID]?.descriptor.branches.first { $0.id == item.derivation.branchID }
            // Non-HD uncompressed imports are represented by a 65-byte public
            // key in pkh(...). Legacy Electrum HD also uses uncompressed keys.
            let compressed = branch?.electrumLegacyPublicKey == nil && !(branch?.isHD == false && branch?.descriptor.contains("pkh(04") == true)
            return BitcoinSendCoin(accountID: item.output.accountID, txid: item.output.transactionHash, vout: item.output.outputIndex,
                                   value: item.output.value, address: item.derivation, previousTransaction: item.previousTransaction, compressed: compressed)
        }
    }
}
