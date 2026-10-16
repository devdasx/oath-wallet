import Foundation

public struct WalletConnectSolanaReview: Sendable, Equatable {
    public struct Change: Sendable, Equatable {
        public let reference: String, before: UInt64, after: UInt64, decimals: Int?
        public var increase: Bool { after > before }
        public var amount: UInt64 { increase ? after - before : before - after }
    }
    public let fee: UInt64, programs: [String], changes: [Change], slot: UInt64
    public let inspectedAccounts: Int, totalWritableAccounts: Int
    public var incomplete: Bool { inspectedAccounts < totalWritableAccounts }
}

extension SolanaSendClient {
    /// Same network-verified transport as native sends. No URL supplied by a
    /// peer is accepted and there is no fallback between Solana clusters.
    public func walletConnectReview(_ request: WalletConnectSolanaRequest) async throws -> [WalletConnectSolanaReview] {
        guard network == request.network else { throw SolanaSendError.wrongNetwork }
        var reviews = [WalletConnectSolanaReview]()
        for transaction in request.transactions { reviews.append(try await walletConnectReview(transaction, owner: request.account, minimumSlot: request.minContextSlot)) }
        return reviews
    }
    private func walletConnectReview(_ tx: WalletConnectSolanaTransaction, owner: String, minimumSlot: UInt64) async throws -> WalletConnectSolanaReview {
        let config: SolanaJSON = .object(["commitment": .string("confirmed"), "minContextSlot": .number(String(minimumSlot))])
        guard try await rpc("isBlockhashValid", [.string(tx.blockhash), config])["value"] == .bool(true) else { throw SolanaSendError.expired }
        var keys = tx.keys, loadedWritable = [String](), loadedReadonly = [String]()
        for lookup in tx.lookups {
            let result = try await rpc("getAccountInfo", [.string(lookup.address), .object(["encoding": .string("base64"), "commitment": .string("confirmed"), "minContextSlot": .number(String(minimumSlot))])])
            let value = result["value"]
            guard value["owner"].string == "AddressLookupTab1e1111111111111111111111111", let bytes = Self.walletConnectAccountBytes(value),
                  bytes.count >= 56, (bytes.count - 56) % 32 == 0, bytes.prefix(4) == Data([1,0,0,0]) else { throw SolanaSendError.malformed }
            for (indices, write) in [(lookup.writable, true), (lookup.readonly, false)] {
                for index in indices {
                    guard index < (bytes.count - 56) / 32 else { throw SolanaSendError.malformed }
                    let key = SolanaSendCrypto.encode(bytes.subdata(in: 56+index*32..<56+(index+1)*32))
                    if write { loadedWritable.append(key) } else { loadedReadonly.append(key) }
                }
            }
        }
        keys += loadedWritable + loadedReadonly
        guard Set(keys).count == keys.count else { throw SolanaSendError.malformed }
        let allWritable = tx.writable.sorted().map { keys[$0] } + loadedWritable
        // RPC simulation account return lists are limited. Always include the
        // signer first and disclose partial inspection instead of inventing totals.
        let addresses = Array(([owner] + allWritable.filter { $0 != owner }).prefix(64))
        let before = try await rpc("getMultipleAccounts", [.array(addresses.map(SolanaJSON.string)), .object(["encoding": .string("base64"), "commitment": .string("confirmed"), "minContextSlot": .number(String(minimumSlot))])])
        guard let slot = before["context"]["slot"].integer, slot >= minimumSlot, let accounts = before["value"].array, accounts.count == addresses.count else { throw SolanaSendError.malformed }
        let simulation = try await rpc("simulateTransaction", [.string(tx.bytes.base64EncodedString()), .object([
            "encoding": .string("base64"), "commitment": .string("confirmed"), "sigVerify": .bool(false),
            "replaceRecentBlockhash": .bool(false), "minContextSlot": .number(String(slot)),
            "accounts": .object(["encoding": .string("base64"), "addresses": .array(addresses.map(SolanaJSON.string))])])])
        guard case .object(let value) = simulation["value"], value["err"] == .null else { throw SolanaSendError.simulationFailed }
        guard let after = simulation["value"]["accounts"].array, after.count == addresses.count else { throw SolanaSendError.malformed }
        let feeResponse = try await rpc("getFeeForMessage", [.string(tx.message.base64EncodedString()), config])
        guard let fee = feeResponse["value"].integer, fee > 0, fee <= 10_000_000 else { throw SolanaSendError.feeTooHigh }
        var totals: [String: (UInt64, UInt64)] = [:]
        func add(_ value: UInt64, to existing: UInt64) throws -> UInt64 {
            let sum = value.addingReportingOverflow(existing); guard !sum.overflow else { throw SolanaSendError.malformed }; return sum.partialValue
        }
        for i in addresses.indices {
            if addresses[i] == owner {
                // A sponsored transaction may involve a signer whose native
                // account does not exist yet. Null is an observed zero here,
                // unlike a missing/malformed balance in a returned account.
                let start = accounts[i].isNull ? 0 : accounts[i]["lamports"].integer
                guard let start else { throw SolanaSendError.malformed }
                let end = after[i].isNull ? 0 : after[i]["lamports"].integer
                guard let end else { throw SolanaSendError.malformed }; totals["native"] = (start, end)
            }
            let pre = Self.walletConnectToken(accounts[i], owner: owner), post = Self.walletConnectToken(after[i], owner: owner)
            if let pre { var t = totals[pre.0, default: (0,0)]; t.0 = try add(pre.1, to: t.0); totals[pre.0] = t }
            if let post { var t = totals[post.0, default: (0,0)]; t.1 = try add(post.1, to: t.1); totals[post.0] = t }
        }
        var changes = [WalletConnectSolanaReview.Change]()
        for mint in totals.keys.sorted() {
            let value = totals[mint]!
            guard value.0 != value.1 else { continue }
            var decimals: Int? = mint == "native" ? 9 : nil
            if mint != "native" {
                let account = try await rpc("getAccountInfo", [.string(mint), .object(["encoding": .string("base64"), "commitment": .string("confirmed")])])["value"]
                if [SolanaIdentity.tokenProgram, SolanaIdentity.token2022Program].contains(account["owner"].string ?? ""),
                   let data = Self.walletConnectAccountBytes(account), data.count >= 82 { decimals = Int(data[44]) }
            }
            changes.append(.init(reference: mint, before: value.0, after: value.1, decimals: decimals))
        }
        return .init(fee: fee, programs: Array(Set(tx.instructions.map { keys[$0.program] })).sorted(), changes: changes,
                     slot: slot, inspectedAccounts: allWritable.filter { addresses.contains($0) }.count, totalWritableAccounts: allWritable.count)
    }
    private static func walletConnectAccountBytes(_ json: SolanaJSON) -> Data? {
        guard let parts = json["data"].array, parts.count == 2, parts[1].string == "base64", let value = parts[0].string else { return nil }
        return Data(base64Encoded: value)
    }
    private static func walletConnectToken(_ json: SolanaJSON, owner: String) -> (String, UInt64)? {
        guard [SolanaIdentity.tokenProgram, SolanaIdentity.token2022Program].contains(json["owner"].string ?? ""),
              let data = walletConnectAccountBytes(json), data.count >= 165,
              SolanaSendCrypto.encode(data.subdata(in: 32..<64)) == owner else { return nil }
        let amount = data[64..<72].enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << (8 * $1.offset) }
        return (SolanaSendCrypto.encode(data.prefix(32)), amount)
    }
    public func walletConnectSubmit(_ bytes: Data, request: WalletConnectSolanaRequest) async throws -> String {
        guard network == request.network, request.broadcasts, request.transactions.count == 1 else { throw SolanaSendError.wrongNetwork }
        let transaction = request.transactions[0]
        try transaction.verifySigned(bytes, requireAll: true)
        let expected = SolanaSendCrypto.encode(bytes.subdata(in: transaction.signatureOffset..<transaction.signatureOffset+64))
        let result = try await rpc("sendTransaction", [.string(bytes.base64EncodedString()), .object([
            "encoding": .string("base64"), "skipPreflight": .bool(false), "preflightCommitment": .string("confirmed"),
            "maxRetries": .number("3"), "minContextSlot": .number(String(request.minContextSlot))])])
        guard result.string == expected else { throw SolanaSendError.malformed }; return expected
    }
    public func walletConnectBlockhashValid(_ blockhash: String) async throws -> Bool {
        guard SolanaIdentity.isAddress(blockhash) else { throw SolanaSendError.malformed }
        let result = try await rpc("isBlockhashValid", [.string(blockhash), .object(["commitment": .string("confirmed")])])
        guard case .bool(let valid) = result["value"] else { throw SolanaSendError.malformed }; return valid
    }
    public func walletConnectStatus(_ signature: String) async throws -> SolanaSendReceipt.Outcome {
        guard SolanaIdentity.isSignature(signature) else { throw SolanaSendError.malformed }
        let result = try await rpc("getSignatureStatuses", [.array([.string(signature)]), .object(["searchTransactionHistory": .bool(true)])])
        guard let values = result["value"].array, values.count == 1 else { throw SolanaSendError.malformed }
        let value = values[0]; if value.isNull { return .unknown }
        guard case .object(let object) = value, let error = object["err"] else { throw SolanaSendError.malformed }
        if !error.isNull { return .failed }
        return ["confirmed", "finalized"].contains(value["confirmationStatus"].string ?? "") ? .confirmed : .accepted
    }
}
