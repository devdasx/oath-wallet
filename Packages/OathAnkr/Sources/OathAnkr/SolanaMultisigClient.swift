import Foundation
import OathDiagnostics

public struct SolanaMultisigState: Sendable {
    public let payer: String
    public let configured: Bool
    public let balance: UInt64
    public let setupCost: UInt64
}
extension SolanaSendClient {
    /// Read all members in one RPC snapshot. Only ordinary system accounts can
    /// fund these transactions; a token/stake account's lamports are not spendable
    /// just because its address matches a member. Nil accounts are normal unfunded
    /// signers. Selection is frozen into the quote and never changed on replay.
    func multisigPayer(_ policy: SolanaMultisigPolicy, slot: UInt64) async throws -> (address: String, balance: UInt64) {
        try policy.validate()
        let response = try await rpc("getMultipleAccounts", [.array(policy.members.map(SolanaJSON.string)),
            .object(["encoding": .string("base64"), "commitment": .string("confirmed"), "minContextSlot": .number(String(slot))])])
        guard let accounts = try value(response, slot: slot).array, accounts.count == policy.members.count else { throw SolanaSendError.malformed }
        var best: (address: String, balance: UInt64)?
        for (member, account) in zip(policy.members, accounts) {
            if account.isNull {
                if best == nil { best = (member, 0) }
                continue
            }
            guard let balance = account["lamports"].integer, let owner = account["owner"].string,
                  case .bool(let executable) = account["executable"], let data = account["data"].array,
                  data.count == 2, data[1].string == "base64", let encoded = data[0].string else { throw SolanaSendError.malformed }
            // Non-system/data accounts require different spending/nonce machinery.
            // Ineligible members are expected selection state, not app failures.
            guard owner == SolanaSendCrypto.system, !executable, encoded.isEmpty else { continue }
            if best == nil || balance > best!.balance { best = (member, balance) }
        }
        guard let best else { throw SolanaSendError.wrongOwner }
        return best
    }

    public func multisigState(_ policy: SolanaMultisigPolicy) async throws -> SolanaMultisigState {
        async let index = multisigIndex(policy)
        async let payer = multisigPayer(policy,slot:0)
        async let config = multisigConfiguration(slot:0)
        async let rent = multisigRent(132 + 33*policy.members.count)
        let (i,b,c,r) = try await (index,payer,config,rent)
        return .init(payer:b.address,configured:i != nil,balance:b.balance,setupCost:c.fee+r+10_000)
    }

    /// Verifies the deployed program and its current creation configuration.
    /// Network genesis is checked by the shared RPC client on both clusters.
    func multisigConfiguration(slot: UInt64) async throws -> (treasury: String, fee: UInt64) {
        guard network != .testnet else { throw SolanaSendError.configuration }
        async let executable = account(SolanaMultisigPolicy.program, slot: slot)
        async let configuration = multisigAccount(SolanaMultisigPolicy.programConfig, slot: slot)
        let (program, data) = try await (executable, configuration)
        guard program["executable"] == .bool(true), program["owner"].string == "BPFLoaderUpgradeab1e11111111111111111111111", let data else { throw SolanaSendError.configuration }
        var r = SolanaMultisigReader(data)
        guard try r.take(8) == Data([196,210,90,231,144,149,140,63]) else { throw SolanaSendError.changed }
        _ = try r.key()
        let fee = try r.number(8), treasury = try r.key()
        guard fee <= 100_000_000, SolanaIdentity.isAddress(treasury) else { throw SolanaSendError.feeTooHigh }
        return (treasury, fee)
    }
    func multisigAccount(_ address: String, slot: UInt64) async throws -> Data? {
        let result = try value(await rpc("getAccountInfo", [.string(address), .object(["encoding":.string("base64"),"commitment":.string("confirmed"),"minContextSlot":.number(String(slot))])]), slot:slot)
        if result.isNull { return nil }
        guard result["owner"].string == SolanaMultisigPolicy.program, result["executable"] == .bool(false),
              let parts = result["data"].array, parts.count == 2, parts[1].string == "base64",
              let text = parts[0].string, let data = Data(base64Encoded:text), data.count <= 10_240 else { throw SolanaSendError.changed }
        return data
    }
    public func multisigIndex(_ policy: SolanaMultisigPolicy, minimumSlot: UInt64 = 0) async throws -> UInt64? {
        try policy.validate()
        _ = try await multisigConfiguration(slot:minimumSlot)
        guard let data = try await multisigAccount(policy.multisig, slot:minimumSlot) else { return nil }
        return try policy.transactionIndex(account:data)
    }
    func multisigRent(_ size: Int) async throws -> UInt64 {
        guard size > 0, size <= 10_240, let n = try await rpc("getMinimumBalanceForRentExemption",[.number(String(size)),config()]).integer,
              n > 0, n <= 100_000_000 else { throw SolanaSendError.feeTooHigh }
        return n
    }
    public func quoteMultisigSetup(_ policy: SolanaMultisigPolicy) async throws -> SolanaSendPlan {
        try policy.validate()
        let block = try await rpc("getLatestBlockhash",[config()])
        guard let slot = block["context"]["slot"].integer, let hash = block["value"]["blockhash"].string,
              let height = block["value"]["lastValidBlockHeight"].integer else { throw SolanaSendError.malformed }
        async let configuration = multisigConfiguration(slot:slot)
        async let existing = multisigAccount(policy.multisig, slot:slot)
        async let funds = multisigPayer(policy,slot:slot)
        async let rent = multisigRent(132 + 33 * policy.members.count)
        let (c, old, payer, storage) = try await (configuration, existing, funds, rent)
        guard old == nil else { throw SolanaSendError.changed }
        let p = SolanaSendPlan(network:network,sender:try policy.vault,recipient:try policy.vault,requestedAmount:0,amount:0,assetBalance:0,nativeBalance:0,blockhash:hash,lastValidBlockHeight:height,slot:slot,transactionFee:10_000,multisig:.init(policy:policy,index:0,payerBalance:payer.balance,storageRent:storage+c.fee,setupTreasury:c.treasury,feePayer:payer.address))
        try p.validate(); try await validateMultisigFees(p); try await simulateMultisigFirst(p)
        return p
    }
    public func quoteMultisig(_ policy: SolanaMultisigPolicy, recipient: String, reference: String, decimals: Int, amount: String, maximum: Bool = false, memo: String = "", paymentReferences: [String] = []) async throws -> SolanaSendPlan {
        try policy.validate()
        let sender = try policy.vault
        guard SolanaIdentity.isAddress(recipient), recipient != sender,
              reference == "native" || SolanaIdentity.isAddress(reference), (0...255).contains(decimals),
              let requested = UInt64(amount), requested > 0, memo.utf8.count <= 128 else { throw SolanaSendError.amount }
        let block = try await rpc("getLatestBlockhash",[config()])
        guard let slot = block["context"]["slot"].integer, let hash = block["value"]["blockhash"].string,
              let height = block["value"]["lastValidBlockHeight"].integer else { throw SolanaSendError.malformed }
        async let indexWork = multisigIndex(policy,minimumSlot:slot)
        async let nativeWork = balance(sender,slot:slot)
        async let payerWork = multisigPayer(policy,slot:slot)
        async let tokenWork: Tokens? = reference == "native" ? nil : tokens(sender:sender,recipient:recipient,mint:reference,decimals:decimals,requested:requested,maximum:maximum,slot:slot,memo:memo)
        async let reserveWork: UInt64 = reference == "native" ? newRecipientReserve(recipient,slot:slot) : 0
        let (oldIndex,native,payer,token,reserve) = try await (indexWork,nativeWork,payerWork,tokenWork,reserveWork)
        guard let oldIndex, oldIndex < UInt64.max-1 else { throw SolanaSendError.changed }
        let asset = token?.balance ?? native, value = maximum ? asset : requested
        guard value > 0, value <= asset else { throw SolanaSendError.insufficientFunds }
        if reference == "native", value < reserve { throw SolanaSendError.recipientMinimum(reserve) }
        let fee = UInt64(policy.required+1)*5_000
        func plan(_ storage: UInt64) -> SolanaSendPlan {
            .init(network:network,sender:sender,recipient:recipient,reference:reference,program:token?.program ?? "",decimals:decimals,requestedAmount:value,amount:value,assetBalance:asset,nativeBalance:native,blockhash:hash,lastValidBlockHeight:height,slot:slot,transactionFee:fee,rent:token?.rent ?? 0,sources:token?.sources ?? [],tokenFees:token?.fees ?? [],memo:memo,recipientReserve:reserve,multisig:.init(policy:policy,index:oldIndex+1,payerBalance:payer.balance,storageRent:storage,feePayer:payer.address),paymentReferences:paymentReferences)
        }
        let inner = try SolanaMultisigCrypto.inner(plan(0))
        // Account allocation uses ordinary Borsh vectors (u32 lengths), unlike
        // the compact instruction message submitted to the Squads program.
        let transactionSize = 87 + 3 + 4 + 32*inner.keys.count + 4 + inner.instructions.reduce(0) { $0 + 1 + 4 + $1.keys.count + 4 + $1.data.count } + 4
        async let transactionRent = multisigRent(transactionSize)
        async let proposalRent = multisigRent(70 + 96*policy.members.count)
        let storage = try await transactionRent + proposalRent
        let p = plan(storage)
        try p.validate(); try await validateMultisigFees(p); try await simulateMultisigFirst(p)
        return p
    }
    func validateMultisigFees(_ p: SolanaSendPlan) async throws {
        let messages = try SolanaMultisigCrypto.messages(p)
        var total: UInt64 = 0
        for message in messages {
            guard let fee = try value(await rpc("getFeeForMessage",[.string(message.base64EncodedString()),config(p.slot)]),slot:p.slot).integer,
                  fee > 0, fee <= 10_000_000 else { throw SolanaSendError.expired }
            total += fee
        }
        guard total == p.transactionFee else { throw SolanaSendError.changed }
    }
    func simulateMultisigFirst(_ p: SolanaSendPlan) async throws {
        guard let first = try SolanaMultisigCrypto.stages(p).first else { throw SolanaSendError.malformed }
        let bytes = SolanaSendCrypto.short(first.signerCount) + Data(repeating:0,count:first.signerCount*64) + (try first.message(p.blockhash))
        let result = try value(await rpc("simulateTransaction",[.string(bytes.base64EncodedString()),.object(["encoding":.string("base64"),"sigVerify":.bool(false),"replaceRecentBlockhash":.bool(false),"commitment":.string("confirmed"),"minContextSlot":.number(String(p.slot))])]),slot:p.slot)
        guard case .object(let fields) = result, fields["err"] != nil else { throw SolanaSendError.malformed }
        guard result["err"].isNull else {
            OathDiagnostics.record(Self.simulationError(result["err"]),component:"solana_multisig",operation:"simulate",context:["chain":"solana","stage":"quote"])
            throw SolanaSendError.simulationFailed
        }
    }
    func preflightMultisig(_ p: SolanaSendPlan) async throws {
        guard let context = p.multisig else { throw SolanaSendError.changed }
        let current = try await multisigIndex(context.policy,minimumSlot:p.slot)
        if context.setupTreasury != nil { guard current == nil else { throw SolanaSendError.changed } }
        else { guard current == context.index-1 else { throw SolanaSendError.changed } }
        try await simulateMultisigFirst(p)
    }
    /// Replays only the already journaled bytes. The preparation carries no votes;
    /// all approvals and the transfer execute atomically in the final transaction.
    func submitMultisig(_ signed: SolanaSignedSend, plan: SolanaSendPlan) async throws -> SolanaSendReceipt {
        for stage in signed.preparations ?? [] {
            let found = try await rpc("getSignatureStatuses",[.array([.string(stage.hash)]),.object(["searchTransactionHistory":.bool(true)])])
            guard let values = found["value"].array, values.count == 1 else { throw SolanaSendError.malformed }
            if values[0].isNull {
                try await sendMultisigStage(stage,slot:plan.slot)
            }
            // Bounded wait. Returning unknown keeps the durable authorization
            // pending; the next background pass can replay the same bytes.
            var confirmed = false
            for _ in 0..<8 {
                let result = try await rpc("getTransaction",[.string(stage.hash),.object(["encoding":.string("base64"),"commitment":.string("confirmed"),"maxSupportedTransactionVersion":SolanaTransactionRead.maximumVersion])])
                if !result.isNull {
                    guard let parts = result["transaction"].array, parts.count == 2, parts[1].string == "base64",
                          let encoded = parts[0].string, Data(base64Encoded:encoded) == stage.bytes,
                          case .object(let meta) = result["meta"], meta["err"] != nil else { throw SolanaSendError.changed }
                    guard result["meta"]["err"].isNull else {
                        OathDiagnostics.record(Self.simulationError(result["meta"]["err"]),component:"solana_multisig",operation:"submit_preparation",context:["chain":"solana","stage":"preparation"])
                        throw SolanaSendError.execution
                    }
                    confirmed = true; break
                }
                try await Task.sleep(for:.seconds(1))
            }
            guard confirmed else { return .init(hash:signed.hash,outcome:.unknown) }
        }
        try await sendMultisigStage(.init(bytes:signed.bytes,hash:signed.hash),slot:plan.slot)
        return .init(hash:signed.hash,outcome:.accepted)
    }
    func sendMultisigStage(_ stage: SolanaSignedStage, slot: UInt64) async throws {
        let result = try await rpc("sendTransaction",[.string(stage.bytes.base64EncodedString()),.object(["encoding":.string("base64"),"skipPreflight":.bool(false),"preflightCommitment":.string("confirmed"),"maxRetries":.number("3"),"minContextSlot":.number(String(slot))])])
        guard result.string == stage.hash else { throw SolanaSendError.changed }
    }
}
