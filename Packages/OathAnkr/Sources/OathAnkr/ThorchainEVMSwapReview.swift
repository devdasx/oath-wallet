import Foundation
import OathDiagnostics

public struct ThorchainSwapAsset: Sendable, Equatable {
    public let id: String
    public let networkID: String
    public let reference: String
    public let symbol: String
    public static let evmChains: [UInt64: String] = [1: "ETH", 56: "BSC", 43114: "AVAX", 8453: "BASE", 137: "POL"]
    /// Abbreviations are scoped to the complete current pool catalogue. Never
    /// infer a contract from a ticker alone or choose between competing pools.
    static func resolve(_ value: String, poolAssets: [String]) -> Self? {
        if let exact = Self(value) { return exact }
        let parts = value.uppercased().split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard (1...2).contains(parts.count) else { return nil }
        let suffix = parts.count == 2 ? parts[1] : ""
        guard suffix.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) }) else { return nil }
        let matches = Set(poolAssets.map { $0.uppercased() }).compactMap(Self.init).filter {
            $0.reference != "native" && $0.id.components(separatedBy: "-").first == parts[0] &&
            $0.reference.uppercased().hasSuffix(suffix)
        }
        return matches.count == 1 ? matches[0] : nil
    }
    public init?(_ value: String) {
        let value = value.uppercased()
        let native = ["THOR.RUNE": "thorchain", "BTC.BTC": "bitcoin", "ETH.ETH": "ethereum", "BSC.BNB": "bnb",
            "AVAX.AVAX": "avalanche", "BASE.ETH": "base", "POL.POL": "polygon", "LTC.LTC": "litecoin", "BCH.BCH": "bitcoincash",
            "DOGE.DOGE": "dogecoin", "TRON.TRX": "tron", "XRP.XRP": "xrpl", "SOL.SOL": "solana"]
        if let network = native[value] {
            id = value; networkID = network; reference = "native"; symbol = String(value.split(separator: ".")[1]); return
        }
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, let network = ["ETH": "ethereum", "BSC": "bnb", "AVAX": "avalanche", "BASE": "base", "POL": "polygon"][String(parts[0])],
              let dash = parts[1].firstIndex(of: "-") else { return nil }
        let ticker = String(parts[1][..<dash]), contract = String(parts[1][parts[1].index(after: dash)...]).lowercased()
        guard !ticker.isEmpty, ticker.count <= 32, ticker.utf8.allSatisfy({ (65...90).contains($0) || (48...57).contains($0) }),
              contract.count == 42, contract.hasPrefix("0x"), contract.dropFirst(2).allSatisfy({ $0.isASCII && $0.isHexDigit }),
              contract != EVMPermissionRemoval.zero else { return nil }
        id = value; networkID = network; reference = contract; symbol = ticker
    }
}

/// Decode a complete router deposit or native vault transfer. The raw memo is
/// resolved against current pools before this intent becomes a swap review.
/// Neither a selector nor a peer name establishes the destination's identity.
public struct ThorchainEVMDeposit: Sendable, Equatable {
    public let chainID: UInt64
    public let sender: String
    public let router: String?
    public let vault: String
    public let reference: String
    public let amount: String
    public let memoText: String
    public let expiry: UInt64?
    public init?(_ request: WalletConnectEVMRequest) {
        let bytes = Array(request.call.bytes)
        guard ThorchainSwapAsset.evmChains[request.chainID] != nil else { return nil }
        if let text = String(bytes: bytes, encoding: .utf8), Self.isSwapMemo(text),
           request.value != "0", request.recipient != EVMPermissionRemoval.zero {
            chainID = request.chainID; sender = request.sender; router = nil
            vault = request.recipient; reference = "native"; amount = request.value
            memoText = text; expiry = nil
            return
        }
        guard request.call.hex.hasPrefix("0x44bc937b"), (196...452).contains(bytes.count) else { return nil }
        func word(_ index: Int) -> Data { Data(bytes[(4 + index * 32)..<(36 + index * 32)]) }
        func number(_ index: Int) -> String? { try? AnkrQuantity.decimal("0x" + TronSendCrypto.hex(word(index))) }
        func address(_ index: Int) -> String? {
            let data = word(index)
            guard data.prefix(12).allSatisfy({ $0 == 0 }) else { return nil }
            return "0x" + TronSendCrypto.hex(data.suffix(20))
        }
        guard let vault = address(0), vault != EVMPermissionRemoval.zero, let asset = address(1),
              let amount = number(2), number(3) == "160", let expiry = number(4).flatMap(UInt64.init),
              let length = number(5).flatMap(Int.init), (1...250).contains(length),
              bytes.count == 196 + ((length + 31) / 32) * 32,
              bytes[(196 + length)...].allSatisfy({ $0 == 0 }),
              let text = String(bytes: bytes[196..<(196 + length)], encoding: .utf8),
              Self.isSwapMemo(text) else { return nil }
        let native = asset == EVMPermissionRemoval.zero
        // The router transfers msg.value for native deposits, not the ABI amount.
        // ERC-20 deposits must not conceal an additional native-coin payment.
        guard native ? request.value != "0" : (request.value == "0" && amount != "0") else { return nil }
        self.chainID = request.chainID; self.sender = request.sender; self.router = request.recipient
        self.vault = vault; self.reference = native ? "native" : asset
        self.amount = native ? request.value : amount; self.memoText = text; self.expiry = expiry
    }
    private static func isSwapMemo(_ text: String) -> Bool {
        text.utf8.count <= 250 && text.utf8.allSatisfy { (33...126).contains($0) } &&
            ["SWAP:", "s:", "=:"].contains(where: text.hasPrefix)
    }
    public func resolvedMemo(poolAssets: [String] = []) -> ThorchainSwapMemo? {
        ThorchainSwapMemo(memoText, poolAssets: poolAssets)
    }
    public func protocolAmount(decimals: Int) throws -> String {
        guard (0...36).contains(decimals) else { throw EVMSendError.metadataChanged }
        if decimals <= 8 { return try EVMSendAmount.multiply(amount, "1" + String(repeating: "0", count: 8 - decimals)) }
        // THORChain accounts in 1e8 units, truncating sub-unit dust.
        let result = String(amount.dropLast(min(decimals - 8, amount.count)))
        guard !result.isEmpty, result != "0" else { throw EVMSendError.malformed }
        return result
    }
}

public struct ThorchainEVMSwapReview: Sendable, Equatable {
    public let deposit: ThorchainEVMDeposit
    public let inputAsset: ThorchainSwapAsset
    public let decimals: Int
    public let quote: ThorchainSwapQuote
    public init(deposit: ThorchainEVMDeposit, inputAsset: ThorchainSwapAsset, decimals: Int, quote: ThorchainSwapQuote) {
        self.deposit = deposit; self.inputAsset = inputAsset; self.decimals = decimals; self.quote = quote
    }
}

extension EVMSendClient {
    public func thorchainDepositDecimals(_ deposit: ThorchainEVMDeposit) async throws -> Int {
        guard network.chainID == deposit.chainID else { throw EVMSendError.wrongNetwork }
        return try await decimals(deposit.reference, tag: .string("latest"))
    }
}

extension ThorchainClient {
    public func walletConnectEVMSwapReview(_ deposit: ThorchainEVMDeposit, decimals: Int) async throws -> ThorchainEVMSwapReview? {
        do {
            if let expiry = deposit.expiry, Double(expiry) <= Date.now.timeIntervalSince1970 { throw EVMSendError.expired }
            async let inboundsWork = read(Self.node, path: "thorchain/inbound_addresses")
            async let poolsWork = read(Self.node, path: "thorchain/pools")
            async let vaultsWork = read(Self.node, path: "thorchain/vaults/asgard")
            async let statsWork = OathDiagnostics.attempt("thorchain_swap_prices") { try await read(Self.midgard, path: "v2/stats") }
            let (inbounds, pools, vaults, stats) = try await (inboundsWork, poolsWork, vaultsWork, statsWork)
            guard let input = try Self.swapInput(deposit, inbounds: inbounds, pools: pools, vaults: vaults) else { return nil }
            guard let assets = pools.array?.compactMap({ $0["asset"].string }) else { throw ThorchainSendError.malformed }
            // Unsupported memo extensions and ambiguous token abbreviations keep
            // the generic transaction review; never guess what will be received.
            guard let memo = deposit.resolvedMemo(poolAssets: assets) else { return nil }
            let amount = try deposit.protocolAmount(decimals: decimals)
            let quote = try await swapQuote(from: input.id, amount: amount, memo: memo, pools: pools, stats: stats)
            return .init(deposit: deposit, inputAsset: input, decimals: decimals, quote: quote)
        } catch {
            OathDiagnostics.record(error, component: "walletconnect", operation: "thorchain_evm_swap_review",
                context: ["chain": ThorchainSwapAsset.evmChains[deposit.chainID]?.lowercased() ?? "evm"])
            throw error
        }
    }

    static func swapInput(_ deposit: ThorchainEVMDeposit, inbounds: SolanaJSON, pools: SolanaJSON, vaults: SolanaJSON = .array([])) throws -> ThorchainSwapAsset? {
        guard let chain = ThorchainSwapAsset.evmChains[deposit.chainID], let rows = inbounds.array,
              let pools = pools.array else { throw ThorchainSendError.malformed }
        let matches = rows.filter {
            $0["chain"].string == chain && (deposit.router == nil || $0["router"].string?.lowercased() == deposit.router)
        }
        guard matches.count <= 1 else { throw ThorchainSendError.malformed }
        guard let inbound = matches.first else { return nil }
        // Different fresh quotes can select different active Asgard vaults.
        // Match the signed vault, not just the newest quote's selected vault.
        let activeVault = vaults.array?.contains { vault in
            vault["status"].string == "ActiveVault" &&
            (deposit.router == nil || vault["routers"].array?.contains { $0["chain"].string == chain && $0["router"].string?.lowercased() == deposit.router } == true) &&
            vault["addresses"].array?.contains { $0["chain"].string == chain && $0["address"].string?.lowercased() == deposit.vault } == true
        } == true
        let recognizedVault = inbound["address"].string?.lowercased() == deposit.vault || activeVault
        // Ordinary transfers with a swap-looking note are not THORChain deposits.
        if deposit.router == nil && !recognizedVault { return nil }
        guard recognizedVault,
              inbound["halted"] == .bool(false), inbound["global_trading_paused"] == .bool(false),
              inbound["chain_trading_paused"] == .bool(false) else { throw EVMSendError.changed }
        let assets = pools.filter { Self.swapPoolAvailable($0) }
            .compactMap { $0["asset"].string.flatMap(ThorchainSwapAsset.init) }
            .filter { $0.id.hasPrefix(chain + ".") && $0.reference == deposit.reference }
        guard assets.count == 1 else { throw ThorchainSendError.malformed }
        return assets[0]
    }

    func swapQuote(from asset: String, amount: String, memo: ThorchainSwapMemo, pools: SolanaJSON, stats: SolanaJSON?) async throws -> ThorchainSwapQuote {
        guard memo.asset == "THOR.RUNE" || pools.array?.contains(where: {
            $0["asset"].string?.uppercased() == memo.asset && Self.swapPoolAvailable($0)
        }) == true else { throw ThorchainSendError.malformed }
        var query: [URLQueryItem] = [.init(name: "from_asset", value: asset), .init(name: "to_asset", value: memo.asset),
            .init(name: "amount", value: amount), .init(name: "destination", value: memo.destination)]
        if let interval = memo.interval { query.append(.init(name: "streaming_interval", value: String(interval))) }
        if let quantity = memo.quantity { query.append(.init(name: "streaming_quantity", value: String(quantity))) }
        if let affiliate = memo.affiliate {
            query.append(.init(name: "affiliate", value: affiliate)); query.append(.init(name: "affiliate_bps", value: String(memo.affiliateBPS)))
        }
        try await ThorchainSwapQuotePacer.shared.wait()
        let json = try await read(Self.node, path: "thorchain/quote/swap", query: query)
        return try .decode(json, memo: memo, input: amount, poolAssets: pools.array?.compactMap { $0["asset"].string } ?? [], inputPriceUSD: Self.swapPrice(asset, pools: pools, stats: stats),
            outputPriceUSD: Self.swapPrice(memo.asset, pools: pools, stats: stats))
    }

    static func swapPrice(_ asset: String, pools: SolanaJSON, stats: SolanaJSON?) -> String? {
        if asset == "THOR.RUNE" { return stats.flatMap { TonMarkets.positive($0["runePriceUSD"]) } }
        guard let pool = pools.array?.first(where: { $0["asset"].string?.uppercased() == asset }),
              let value = TonMarkets.positive(pool["asset_tor_price"]), let amount = Decimal(string: value) else { return nil }
        return NSDecimalNumber(decimal: amount / 100_000_000).stringValue
    }

    private static func swapPoolAvailable(_ pool: SolanaJSON) -> Bool {
        pool["status"].string == "Available" && (pool["trading_halted"].isNull || pool["trading_halted"] == .bool(false))
    }
}
