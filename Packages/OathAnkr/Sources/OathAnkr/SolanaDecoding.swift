import Foundation

public enum SolanaDecoding {
    public static func inventory(owner: String, values: [SolanaJSON], now: Date = .now) throws -> SolanaInventory {
        guard values.count == 3, let balance = values[0]["value"].integer else { throw SolanaError.malformed }
        let slots = try values.map { v -> UInt64 in
            guard let slot = v["context"]["slot"].integer, slot <= UInt64(Int64.max) else { throw SolanaError.malformed }; return slot }
        var addresses = Set<String>(), accounts: [SolanaTokenAccount] = []
        for (i, program) in [SolanaIdentity.tokenProgram, SolanaIdentity.token2022Program].enumerated() {
            guard let list = values[i + 1]["value"].array, list.count <= 100_000 else { throw SolanaError.malformed }
            for token in list {
                let account = token["account"], info = account["data"]["parsed"]["info"]
                guard let address = token["pubkey"].string, SolanaIdentity.isAddress(address), addresses.insert(address).inserted,
                      account["owner"].string == program, account["data"]["parsed"]["type"].string == "account",
                      info["owner"].string == owner else { throw SolanaError.wrongOwner }
                guard let mint = info["mint"].string, SolanaIdentity.isAddress(mint),
                      let amount = info["tokenAmount"]["amount"].string, let units = UInt64(amount), String(units) == amount,
                      let decimals = info["tokenAmount"]["decimals"].integer, decimals <= 255,
                      let state = info["state"].string, ["initialized", "frozen"].contains(state) else { throw SolanaError.malformed }
                accounts.append(.init(address: address, mint: mint, program: program, amount: amount,
                                      decimals: Int(decimals), frozen: state == "frozen"))
            }
        }
        // A mint cannot legitimately claim conflicting decimal precision.
        var precision: [String: Int] = [:]
        for a in accounts {
            if let old = precision[a.mint], old != a.decimals { throw SolanaError.malformed }
            precision[a.mint] = a.decimals
        }
        return .init(owner: owner, lamports: String(balance), nativeSlot: slots[0], tokenSlot: slots[1], token2022Slot: slots[2],
                     accounts: accounts, fetchedAt: now, raw: try JSONEncoder().encode(values))
    }
    public static func signatures(_ value: SolanaJSON) throws -> [SolanaSignature] {
        guard let list = value.array, list.count <= 1000 else { throw SolanaError.malformed }
        var seen = Set<String>(), previous = UInt64.max
        return try list.map { item in
            guard let signature = item["signature"].string, SolanaIdentity.isSignature(signature), seen.insert(signature).inserted,
                  let slot = item["slot"].integer, slot <= previous, slot <= UInt64(Int64.max) else { throw SolanaError.malformed }
            previous = slot
            return .init(signature: signature, slot: slot, blockTime: item["blockTime"].integer.map(Double.init), failed: !item["err"].isNull)
        }
    }
    public static func transaction(_ value: SolanaJSON, signature: String, owner: String) throws -> SolanaTransaction {
        let meta = value["meta"], message = value["transaction"]["message"]
        guard !meta.isNull, value["transaction"]["signatures"].array?.first?.string == signature,
              let slot = value["slot"].integer, slot <= UInt64(Int64.max), let fee = meta["fee"].integer,
              let keysJSON = message["accountKeys"].array,
              let pre = meta["preBalances"].array, let post = meta["postBalances"].array,
              pre.count == post.count, pre.count == keysJSON.count else { throw SolanaError.malformed }
        // jsonParsed already expands address lookup tables into accountKeys.
        let keys = try keysJSON.map { key -> String in
            guard let address = key["pubkey"].string ?? key.string, SolanaIdentity.isAddress(address) else { throw SolanaError.malformed }
            return address
        }
        let failed = !meta["err"].isNull
        var changes: [SolanaAssetChange] = [], owned = Set<String>()
        if let i = keys.firstIndex(of: owner) {
            guard let before = pre[i].integer, let after = post[i].integer else { throw SolanaError.malformed }
            // Net SOL movement (including rent) with the fee recorded separately.
            let adjusted = i == 0 && before >= fee ? before - fee : before
            if !failed, adjusted != after { changes.append(change(mint: "native", decimals: 9, before: adjusted, after: after)) }
        }
        var amounts: [[String: UInt64]] = [[:], [:]], precisions: [String: Int] = [:]
        var tokenOwners: [String: String] = [:], tokenMints: [String: String] = [:]
        for (side, field) in ["preTokenBalances", "postTokenBalances"].enumerated() {
            guard let balances = meta[field].array else {
                // Very early transactions predate token balance recording;
                // keep the raw transaction and native history, never invent token amounts.
                if meta[field].isNull { continue }; throw SolanaError.malformed
            }
            for balance in balances {
                if let index = balance["accountIndex"].integer, index < keys.count,
                   let mint = balance["mint"].string, SolanaIdentity.isAddress(mint) {
                    tokenMints[keys[Int(index)]] = mint
                    if let holder = balance["owner"].string, SolanaIdentity.isAddress(holder) {
                        tokenOwners[keys[Int(index)]] = holder
                    }
                }
                guard balance["owner"].string == owner else { continue }
                guard let index = balance["accountIndex"].integer, index < keys.count,
                      let mint = balance["mint"].string, SolanaIdentity.isAddress(mint),
                      let amount = balance["uiTokenAmount"]["amount"].string, let units = UInt64(amount),
                      let decimals = balance["uiTokenAmount"]["decimals"].integer, decimals <= 255 else { throw SolanaError.malformed }
                if let old = precisions[mint], old != Int(decimals) { throw SolanaError.malformed }
                precisions[mint] = Int(decimals); owned.insert(keys[Int(index)])
                let sum = (amounts[side][mint] ?? 0).addingReportingOverflow(units)
                guard !sum.overflow else { throw SolanaError.malformed }; amounts[side][mint] = sum.partialValue
            }
        }
        if !failed {
            for mint in precisions.keys.sorted() {
                let before = amounts[0][mint] ?? 0, after = amounts[1][mint] ?? 0
                if before != after { changes.append(change(mint: mint, decimals: precisions[mint]!, before: before, after: after)) }
            }
        }
        // A token account can have belonged to someone else in its older
        // history. Preserve that transaction for cursor/deduplication purposes,
        // but never attribute its activity to the current wallet. Early records
        // without token owner metadata likewise remain raw, not guessed transfers.
        if changes.isEmpty, keys.contains(owner) || !owned.isEmpty {
            if failed {
                for mint in precisions.keys.sorted() {
                    changes.append(.init(mint: mint, decimals: precisions[mint]!, amount: "0", direction: "self"))
                }
            }
            if keys.contains(owner) || changes.isEmpty {
                changes.append(.init(mint: "native", decimals: 9, amount: "0", direction: "self"))
            }
        }
        // The SOL activity screen includes token/program interactions too:
        // a fee-only SOL movement is an interaction with fee recorded separately,
        // not an outgoing token transfer or a missing wallet transaction.
        if keys.contains(owner), !changes.contains(where: { $0.mint == "native" }) {
            changes.insert(.init(mint: "native", decimals: 9, amount: "0", direction: "self"), at: 0)
        }
        let instructions = (message["instructions"].array ?? []) +
            (meta["innerInstructions"].array ?? []).flatMap { $0["instructions"].array ?? [] }
        // Display a counterparty only for a single unambiguous transfer peer.
        // Swaps/multi-party instructions retain their complete raw payload.
        var peers: [String: Set<String>] = [:]
        var transferredMints = Set<String>()
        for instruction in instructions {
            let parsed = instruction["parsed"], info = parsed["info"]
            guard let type = parsed["type"].string,
                  ["transfer", "transferWithSeed", "transferChecked", "transferCheckedWithFee"].contains(type),
                  let source = info["source"].string, let destination = info["destination"].string,
                  SolanaIdentity.isAddress(source), SolanaIdentity.isAddress(destination) else { continue }
            let program = instruction["programId"].string
            let mint: String, from: String, to: String
            if program == "11111111111111111111111111111111" {
                mint = "native"; from = source; to = destination
            } else if program == SolanaIdentity.tokenProgram || program == SolanaIdentity.token2022Program {
                guard let identity = tokenMints[source] ?? tokenMints[destination] else { continue }
                mint = identity; from = tokenOwners[source] ?? source; to = tokenOwners[destination] ?? destination
            } else { continue }
            if mint != "native", from == owner || to == owner { transferredMints.insert(mint) }
            if from == owner, to != owner { peers[mint + ":outgoing", default: []].insert(to) }
            if to == owner, from != owner { peers[mint + ":incoming", default: []].insert(from) }
        }
        // A transfer between two owned token accounts has a zero net change,
        // but still belongs in that token's activity, as do zero-net round trips.
        for mint in transferredMints.sorted() where !changes.contains(where: { $0.mint == mint }) {
            if let decimals = precisions[mint] {
                changes.append(.init(mint: mint, decimals: decimals, amount: "0", direction: "self"))
            }
        }
        changes = changes.map { change in
            let addresses = peers[change.mint + ":" + change.direction] ?? []
            return .init(mint: change.mint, decimals: change.decimals, amount: change.amount,
                         direction: change.direction, counterparty: addresses.count == 1 ? addresses.first : nil)
        }
        return .init(signature: signature, slot: slot, timestamp: value["blockTime"].integer.map(Double.init), failed: failed,
            fee: String(fee), changes: changes, tokenAccounts: owned.sorted(), raw: try JSONEncoder().encode(value))
    }
    private static func change(mint: String, decimals: Int, before: UInt64, after: UInt64) -> SolanaAssetChange {
        .init(mint: mint, decimals: decimals, amount: String(after > before ? after - before : before - after),
              direction: after > before ? "incoming" : "outgoing")
    }
}
