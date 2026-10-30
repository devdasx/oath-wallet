import Foundation
import OathDiagnostics

/// Deliberately narrow display decoder. Limit orders, aggregator calls,
/// THORNames, trade assets and unknown extensions remain protocol deposits with
/// their exact memo visible. This never rewrites the dApp's signing document.
public struct ThorchainSwapMemo: Sendable, Equatable {
    public let rawValue: String
    public let asset: String
    public let destination: String
    public let minimum: String
    public let interval: UInt64?
    public let quantity: UInt64?
    public let affiliate: String?
    public let affiliateBPS: UInt64
    public var symbol: String { ThorchainSwapAsset(asset)?.symbol ?? asset }
    public var networkID: String { ThorchainSwapAsset(asset)?.networkID ?? "" }
    public init?(_ memo: String, poolAssets: [String] = []) {
        guard memo.utf8.count <= 250, memo.utf8.allSatisfy({ (33...126).contains($0) }) else { return nil }
        let p = memo.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard (3...6).contains(p.count) else { return nil }
        // Native shortcuts are fixed; token abbreviations need a unique match
        // in the supplied pool catalogue, including the chain and contract suffix.
        let asset = ["r": "THOR.RUNE", "rune": "THOR.RUNE", "b": "BTC.BTC", "e": "ETH.ETH", "s": "BSC.BNB", "a": "AVAX.AVAX", "f": "BASE.ETH", "p": "POL.POL",
                     "l": "LTC.LTC", "c": "BCH.BCH", "d": "DOGE.DOGE", "tr": "TRON.TRX", "x": "XRP.XRP"][p[1]] ?? p[1]
        guard ["SWAP", "s", "="].contains(p[0]),
              let resolved = ThorchainSwapAsset.resolve(asset, poolAssets: poolAssets),
              !p[2].isEmpty, p[2].count <= 128, !p[2].contains("/"),
              p[2].utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }) else { return nil }
        let limitText = p.count > 3 ? p[3] : ""
        let limit = limitText.isEmpty ? [""] : limitText.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard (1...3).contains(limit.count), let minimum = Self.amount(limit[0]) else { return nil }
        func number(_ index: Int) -> UInt64? {
            guard limit.count > index, !limit[index].isEmpty, let n = UInt64(limit[index]), String(n) == limit[index], n <= 43_200 else { return nil }
            return n
        }
        let interval = number(1), quantity = number(2)
        guard limit.count < 2 || interval != nil, limit.count < 3 || quantity != nil else { return nil }
        let affiliate = p.count > 4 && !p[4].isEmpty ? p[4] : nil
        guard affiliate == nil || (affiliate!.count <= 64 && affiliate!.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 })) else { return nil }
        let fee = p.count > 5 && !p[5].isEmpty ? p[5] : "0"
        guard let bps = UInt64(fee), String(bps) == fee, bps <= 1000, affiliate != nil || bps == 0 else { return nil }
        self.rawValue = memo; self.asset = resolved.id; self.destination = p[2]; self.minimum = minimum
        self.interval = interval; self.quantity = quantity; self.affiliate = affiliate; self.affiliateBPS = bps
    }
    private static func amount(_ value: String) -> String? {
        if value.isEmpty { return "0" }
        let parts = value.split(separator: "e", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), let first = parts.first, !first.isEmpty,
              first.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        var expanded = String(first)
        if parts.count == 2 {
            guard let exponent = Int(parts[1]), (0...38).contains(exponent), String(exponent) == parts[1] else { return nil }
            expanded += String(repeating: "0", count: exponent)
        }
        guard expanded.count <= 78 else { return nil }
        expanded = String(expanded.drop(while: { $0 == "0" }))
        return expanded.isEmpty ? "0" : expanded
    }
}

public struct ThorchainSwapQuote: Sendable, Equatable {
    public let memo: ThorchainSwapMemo
    public let input: String
    public let expectedOutput: String
    public let outboundFee: String
    public let liquidityFee: String
    public let affiliateFee: String
    public let expires: Date
    public let priceImpactBPS: UInt64?
    public let totalSeconds: UInt64?
    public let inputPriceUSD: String?
    public let outputPriceUSD: String?
    public var totalFee: String { [outboundFee, liquidityFee, affiliateFee].reduce("0", AptosIdentity.add) }
    public init(memo: ThorchainSwapMemo, input: String, expectedOutput: String, outboundFee: String,
                liquidityFee: String, affiliateFee: String, expires: Date, priceImpactBPS: UInt64? = nil,
                totalSeconds: UInt64? = nil, inputPriceUSD: String? = nil, outputPriceUSD: String? = nil) {
        self.memo = memo; self.input = input; self.expectedOutput = expectedOutput; self.outboundFee = outboundFee
        self.liquidityFee = liquidityFee; self.affiliateFee = affiliateFee; self.expires = expires
        self.priceImpactBPS = priceImpactBPS; self.totalSeconds = totalSeconds
        self.inputPriceUSD = inputPriceUSD; self.outputPriceUSD = outputPriceUSD
    }
    public static func decode(_ json: SolanaJSON, memo: ThorchainSwapMemo, input: String, now: Date = .now, poolAssets: [String] = [], inputPriceUSD: String? = nil, outputPriceUSD: String? = nil) throws -> Self {
        guard json["error"].isNull, json["code"].isNull,
              let echoed = json["memo"].string.flatMap({ ThorchainSwapMemo($0, poolAssets: poolAssets) }),
              echoed.asset == memo.asset, echoed.destination == memo.destination,
              echoed.affiliate == memo.affiliate, echoed.affiliateBPS == memo.affiliateBPS,
              (echoed.interval ?? 0) == (memo.interval ?? 0), (echoed.quantity ?? 0) == (memo.quantity ?? 0),
              json["fees"]["asset"].string?.uppercased() == memo.asset,
              let timestamp = json["expiry"].integer,
              Double(timestamp) > now.timeIntervalSince1970, Double(timestamp) <= now.timeIntervalSince1970 + 900 else { throw ThorchainSendError.malformed }
        let expected = try ThorchainIdentity.amount(json["expected_amount_out"])
        guard expected != "0", !ThorchainSendAmount.less(expected, memo.minimum) else { throw ThorchainSendError.changed }
        func optionalUInt(_ value: SolanaJSON, maximum: UInt64) throws -> UInt64? {
            guard !value.isNull else { return nil }
            guard let raw = value.text, let number = UInt64(raw), String(number) == raw, number <= maximum else { throw ThorchainSendError.malformed }
            return number
        }
        let impact = json["fees"]["slippage_bps"].isNull ? json["slippage_bps"] : json["fees"]["slippage_bps"]
        return try .init(memo: memo, input: input, expectedOutput: expected,
            outboundFee: ThorchainIdentity.amount(json["fees"]["outbound"]),
            liquidityFee: ThorchainIdentity.amount(json["fees"]["liquidity"]),
            affiliateFee: ThorchainIdentity.amount(json["fees"]["affiliate"]), expires: Date(timeIntervalSince1970: Double(timestamp)),
            priceImpactBPS: optionalUInt(impact, maximum: 10_000), totalSeconds: optionalUInt(json["total_swap_seconds"], maximum: 31_536_000),
            inputPriceUSD: inputPriceUSD, outputPriceUSD: outputPriceUSD)
    }
}

extension ThorchainClient {
    /// Read-only quote for the exact deposit amount and destination. The signed
    /// minimum remains the memo's minimum, never the provider's suggested memo.
    public func walletConnectSwapQuote(_ request: ThorchainWalletConnectRequest) async throws -> ThorchainSwapQuote? {
        guard request.network == .mainnet, request.recipient == nil, request.coins.count == 1,
              request.coins[0].reference == "native", ["SWAP:", "s:", "=:"].contains(where: request.memo.hasPrefix) else { return nil }
        let input = request.coins[0].amount
        do {
            let pools = try await read(Self.node, path: "thorchain/pools")
            guard let assets = pools.array?.compactMap({ $0["asset"].string }) else { throw ThorchainSendError.malformed }
            guard let memo = ThorchainSwapMemo(request.memo, poolAssets: assets) else { return nil }
            async let stats = OathDiagnostics.attempt("thorchain_swap_prices") { try await read(Self.midgard, path: "v2/stats") }
            return try await swapQuote(from: "THOR.RUNE", amount: input, memo: memo, pools: pools, stats: stats)
        } catch {
            OathDiagnostics.record(error, component: "walletconnect", operation: "thorchain_swap_quote", context: ["chain": "thorchain"])
            throw error
        }
    }

    public func resolvedSwapMemo(_ rawValue: String) async throws -> ThorchainSwapMemo? {
        if let exact = ThorchainSwapMemo(rawValue) { return exact }
        guard ["SWAP:", "s:", "=:"].contains(where: rawValue.hasPrefix) else { return nil }
        let pools = try await read(Self.node, path: "thorchain/pools")
        guard let assets = pools.array?.compactMap({ $0["asset"].string }) else { throw ThorchainSendError.malformed }
        return ThorchainSwapMemo(rawValue, poolAssets: assets)
    }
}

/// THORNode's public quote quota is shared per IP. Bound both queued work and
/// request spacing; cancellation never starts a background retry loop.
actor ThorchainSwapQuotePacer {
    static let shared = ThorchainSwapQuotePacer()
    private var next: ContinuousClock.Instant = .now
    private var waiting = 0
    func wait() async throws {
        try Task.checkCancellation()
        guard waiting < 4 else { throw ThorchainSendError.busy }
        waiting += 1
        defer { waiting -= 1 }
        let start = max(next, .now)
        next = start.advanced(by: .milliseconds(1100))
        try await Task.sleep(until: start, clock: .continuous)
    }
}
