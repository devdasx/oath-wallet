import Foundation

enum SolanaTransactionMapper {
    static func history(
        response: SolanaJSONValue,
        signatureInfo: SolanaSignatureInfo,
        ownerAddress: String
    ) -> [SolanaHistoryItem] {
        guard
            let root = response.object,
            let transaction = root["transaction"]?.object,
            let message = transaction["message"]?.object,
            let meta = root["meta"]?.object
        else {
            return []
        }

        let accountKeys = parsedAccountKeys(message["accountKeys"])
        var items = tokenItems(
            meta: meta,
            ownerAddress: ownerAddress,
            signatureInfo: signatureInfo
        )
        if let native = nativeItem(
            meta: meta,
            message: message,
            accountKeys: accountKeys,
            ownerAddress: ownerAddress,
            signatureInfo: signatureInfo
        ) {
            items.append(native)
        }
        return items
    }

    private static func nativeItem(
        meta: [String: SolanaJSONValue],
        message: [String: SolanaJSONValue],
        accountKeys: [String],
        ownerAddress: String,
        signatureInfo: SolanaSignatureInfo
    ) -> SolanaHistoryItem? {
        guard
            let ownerIndex = accountKeys.firstIndex(of: ownerAddress),
            let pre = meta["preBalances"]?.array?[safe: ownerIndex]?.decimal,
            let post = meta["postBalances"]?.array?[safe: ownerIndex]?.decimal
        else {
            return nil
        }
        let feeLamports = meta["fee"]?.decimal ?? 0
        var delta = post - pre
        if ownerIndex == 0, delta < 0 {
            delta += feeLamports
        }
        guard delta != 0 else { return nil }

        let endpoints = nativeTransferEndpoints(
            instructions: message["instructions"]?.array ?? []
        )
        return SolanaHistoryItem(
            signature: signatureInfo.signature,
            sourceAddress: ownerAddress,
            slot: signatureInfo.slot,
            timestamp: signatureInfo.blockTime,
            failed: signatureInfo.failed,
            from: endpoints.from,
            to: endpoints.to,
            mint: nil,
            symbol: "SOL",
            decimals: 9,
            amount: abs(delta) / SolanaConstants.lamportsPerSOL,
            atomicAmount: Self.decimalText(abs(delta)),
            fee: feeLamports / SolanaConstants.lamportsPerSOL
        )
    }

    private static func tokenItems(
        meta: [String: SolanaJSONValue],
        ownerAddress: String,
        signatureInfo: SolanaSignatureInfo
    ) -> [SolanaHistoryItem] {
        let pre = tokenBalances(
            from: meta["preTokenBalances"],
            ownerAddress: ownerAddress
        )
        let post = tokenBalances(
            from: meta["postTokenBalances"],
            ownerAddress: ownerAddress
        )
        let mints = Set(pre.keys).union(post.keys)
        let fee = (meta["fee"]?.decimal ?? 0)
            / SolanaConstants.lamportsPerSOL

        return mints.compactMap { mint in
            let before = pre[mint]
            let after = post[mint]
            let delta = (after?.amount ?? 0) - (before?.amount ?? 0)
            guard delta != 0 else { return nil }
            let decimals = after?.decimals ?? before?.decimals ?? 0
            let metadata = SolanaTokenCatalog.byMint[mint]
            return SolanaHistoryItem(
                signature: signatureInfo.signature,
                sourceAddress: ownerAddress,
                slot: signatureInfo.slot,
                timestamp: signatureInfo.blockTime,
                failed: signatureInfo.failed,
                from: delta < 0 ? ownerAddress : nil,
                to: delta > 0 ? ownerAddress : nil,
                mint: mint,
                symbol: metadata?.symbol ?? Self.shortMint(mint),
                decimals: decimals,
                amount: abs(delta) / power10(decimals),
                atomicAmount: decimalText(abs(delta)),
                fee: fee
            )
        }
    }

    private struct AtomicBalance {
        let amount: Decimal
        let decimals: Int
    }

    private static func tokenBalances(
        from value: SolanaJSONValue?,
        ownerAddress: String
    ) -> [String: AtomicBalance] {
        var result: [String: AtomicBalance] = [:]
        for entry in value?.array ?? [] {
            guard
                let object = entry.object,
                object["owner"]?.string == ownerAddress,
                let mint = object["mint"]?.string,
                let uiAmount = object["uiTokenAmount"]?.object,
                let raw = uiAmount["amount"]?.string,
                let amount = Decimal(string: raw, locale: Locale(identifier: "en_US_POSIX")),
                let decimals64 = uiAmount["decimals"]?.int64
            else {
                continue
            }
            let current = result[mint]?.amount ?? 0
            result[mint] = AtomicBalance(
                amount: current + amount,
                decimals: Int(decimals64)
            )
        }
        return result
    }

    private static func parsedAccountKeys(
        _ value: SolanaJSONValue?
    ) -> [String] {
        (value?.array ?? []).compactMap { entry in
            entry.string ?? entry.object?["pubkey"]?.string
        }
    }

    private static func nativeTransferEndpoints(
        instructions: [SolanaJSONValue]
    ) -> (from: String?, to: String?) {
        for instruction in instructions {
            guard
                let parsed = instruction.object?["parsed"]?.object,
                let type = parsed["type"]?.string,
                type == "transfer" || type == "transferWithSeed",
                let info = parsed["info"]?.object
            else {
                continue
            }
            return (
                info["source"]?.string ?? info["from"]?.string,
                info["destination"]?.string ?? info["to"]?.string
            )
        }
        return (nil, nil)
    }

    static func power10(_ decimals: Int) -> Decimal {
        guard decimals > 0 else { return 1 }
        return (0..<decimals).reduce(Decimal(1)) { value, _ in
            value * 10
        }
    }

    static func decimalText(_ value: Decimal) -> String {
        NSDecimalNumber(decimal: value).stringValue
    }

    static func shortMint(_ mint: String) -> String {
        guard mint.count > 8 else { return mint }
        return "\(mint.prefix(4))…\(mint.suffix(4))"
    }
}

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
