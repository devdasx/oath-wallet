import Foundation

public enum SuiSendError: Error, Sendable, Equatable {
    case malformed, wrongNetwork, wrongOwner, insufficientFunds, insufficientGas, tooManyCoins
    case simulationFailed, executionFailed, signing, changed, expired, busy, transport, http(Int), graphql
}
public enum SuiSendNetwork: String, Codable, Sendable {
    case mainnet, testnet
    public var chainIdentifier: String {
        self == .mainnet ? SuiIdentity.mainnet : "69WiPg3DAQiwdxfncX6wYQ2siKwAe6L9BZthQea3JNMD"
    }
    public var endpoint: URL { URL(string: "https://graphql.\(rawValue).sui.io/graphql")! }
}
public struct SuiSendCoin: Codable, Sendable, Equatable {
    public let id: String, digest: String
    public let version: UInt64, balance: UInt64
    public init(id: String, digest: String, version: UInt64, balance: UInt64) {
        self.id = id; self.digest = digest; self.version = version; self.balance = balance
    }
}
public struct SuiSendFunds: Sendable {
    public let coins: [SuiSendCoin]
    public let addressBalance: UInt64
    public init(coins: [SuiSendCoin], addressBalance: UInt64) { self.coins = coins; self.addressBalance = addressBalance }
    public var total: UInt64 { get throws { try Self.sum(coins.map(\.balance) + [addressBalance]) } }
    static func sum(_ values: [UInt64]) throws -> UInt64 {
        try values.reduce(0) { a,b in let (n,overflow) = a.addingReportingOverflow(b); guard !overflow else { throw SuiSendError.malformed }; return n }
    }
}
/// A narrowly-scoped transfer intent. All BCS bytes are built locally from this
/// checked plan; an RPC can never supply arbitrary transaction bytes to sign.
public struct SuiSendPlan: Codable, Sendable, Equatable {
    public let network: SuiSendNetwork
    public let sender: String, recipient: String, reference: String
    public let requestedAmount: UInt64, amount: UInt64, assetBalance: UInt64, nativeBalance: UInt64
    public let gasCoins: [SuiSendCoin], assetCoins: [SuiSendCoin]
    public let withdrawal: UInt64, gasPrice: UInt64, gasBudget: UInt64, estimatedFee: UInt64
    public let epoch: UInt64, nonce: UInt32
    public let createdAt: Date
    public var deductedFromAmount: UInt64 { requestedAmount - amount }
    public var remaining: UInt64 { assetBalance - amount - (reference == "native" ? estimatedFee : 0) }
    public static let maximumGasBudget: UInt64 = 50_000_000

    public static func make(network: SuiSendNetwork, sender: String, recipient: String, reference: String,
                            amount requested: UInt64, native: SuiSendFunds, asset: SuiSendFunds,
                            gasPrice: UInt64, gasBudget: UInt64, estimatedFee: UInt64 = 0,
                            epoch: UInt64, nonce: UInt32 = .random(in: .min ... .max), now: Date = .now) throws -> Self {
        let sender = try SuiIdentity.address(sender), recipient = try SuiIdentity.address(recipient)
        let reference = try SuiIdentity.reference(reference)
        let nativeTotal = try native.total, assetTotal = try (reference == "native" ? native : asset).total
        guard requested > 0, requested <= assetTotal else { throw SuiSendError.insufficientFunds }
        guard gasBudget > 0, gasBudget <= maximumGasBudget, gasPrice > 0, estimatedFee <= gasBudget,
              nativeTotal >= gasBudget else { throw SuiSendError.insufficientGas }
        let amount = reference == "native" ? min(requested, nativeTotal-gasBudget) : requested
        guard amount > 0 else { throw SuiSendError.insufficientGas }
        // Address gas avoids locking coin objects when possible. Otherwise Sui
        // smashes the payment coins before executing the programmable commands.
        let gasCoins = native.addressBalance >= gasBudget ? [] : native.coins
        let gasTotal = try SuiSendFunds.sum(gasCoins.map(\.balance))
        guard gasCoins.isEmpty || gasTotal >= gasBudget else { throw SuiSendError.insufficientGas }
        let sources = reference == "native" ? (gasCoins.isEmpty ? native.coins : []) : asset.coins
        let coinTotal = reference == "native" && !gasCoins.isEmpty ? gasTotal-gasBudget : try SuiSendFunds.sum(sources.map(\.balance))
        let withdrawal = amount > coinTotal ? amount-coinTotal : 0
        let availableAddress = reference == "native" ? native.addressBalance - (gasCoins.isEmpty ? gasBudget : 0) : asset.addressBalance
        guard withdrawal <= availableAddress else { throw SuiSendError.insufficientFunds }
        let plan = Self(network: network, sender: sender, recipient: recipient, reference: reference,
                        requestedAmount: requested, amount: amount, assetBalance: assetTotal, nativeBalance: nativeTotal,
                        gasCoins: gasCoins, assetCoins: sources, withdrawal: withdrawal, gasPrice: gasPrice,
                        gasBudget: gasBudget, estimatedFee: estimatedFee, epoch: epoch, nonce: nonce, createdAt: now)
        try plan.validate(now: now); return plan
    }
    public func validate(now: Date = .now, checkAge: Bool = true) throws {
        guard !checkAge || (now.timeIntervalSince(createdAt) >= -5 && now.timeIntervalSince(createdAt) <= 120) else { throw SuiSendError.expired }
        guard sender == (try SuiIdentity.address(sender)), recipient == (try SuiIdentity.address(recipient)),
              reference == (try SuiIdentity.reference(reference)), amount > 0, amount <= requestedAmount,
              requestedAmount <= assetBalance, estimatedFee <= gasBudget, gasBudget > 0,
              gasBudget <= Self.maximumGasBudget, nativeBalance >= gasBudget,
              gasPrice > 0, epoch < UInt64.max,
              reference == "native" ? (assetBalance == nativeBalance && amount <= nativeBalance-gasBudget) : amount == requestedAmount else { throw SuiSendError.malformed }
        guard assetCoins.count+gasCoins.count <= 128 else { throw SuiSendError.tooManyCoins }
        let coins = assetCoins+gasCoins
        guard Set(coins.map(\.id)).count == coins.count else { throw SuiSendError.malformed }
        for coin in coins {
            guard try SuiIdentity.address(coin.id) == coin.id, coin.version > 0,
                  try SuiSendCrypto.unbase58(coin.digest).count == 32 else { throw SuiSendError.malformed }
        }
        let gasTotal = try SuiSendFunds.sum(gasCoins.map(\.balance))
        guard gasCoins.isEmpty || gasTotal >= gasBudget else { throw SuiSendError.insufficientGas }
        let sourceTotal = try SuiSendFunds.sum(assetCoins.map(\.balance) + [withdrawal] +
            (reference == "native" && !gasCoins.isEmpty ? [gasTotal-gasBudget] : []))
        guard sourceTotal >= amount else { throw SuiSendError.insufficientFunds }
    }

    public func transactionBytes() throws -> Data {
        try validate(checkAge: false)
        var inputs = [Data](), commands = [Data](), sources = [Data]()
        func pure(_ bytes: Data) -> Data { let index = inputs.count; inputs.append(Data([0])+SuiBCS.vector(bytes)); return SuiBCS.input(index) }
        let recipientArg = pure(try SuiBCS.address(recipient))
        let amountArg = pure(SuiBCS.u64(amount))
        if reference == "native", !gasCoins.isEmpty { sources.append(Data([0])) }
        for coin in assetCoins {
            sources.append(SuiBCS.input(inputs.count)); inputs.append(Data([1,0]) + (try SuiBCS.coin(coin)))
        }
        if withdrawal > 0 {
            let arg = SuiBCS.input(inputs.count)
            inputs.append(Data([2,0]) + SuiBCS.u64(withdrawal) + Data([0]) + (try SuiBCS.type(try SuiIdentity.coinType(reference))) + Data([0]))
            sources.append(SuiBCS.result(commands.count))
            commands.append(Data([0]) + (try SuiBCS.address("0x2")) + SuiBCS.string("coin") + SuiBCS.string("redeem_funds") +
                SuiBCS.list([try SuiBCS.type(try SuiIdentity.coinType(reference))]) + SuiBCS.list([arg]))
        }
        guard let source = sources.first else { throw SuiSendError.insufficientFunds }
        if sources.count > 1 { commands.append(Data([3]) + source + SuiBCS.list(Array(sources.dropFirst()))) }
        let split = commands.count
        commands.append(Data([2]) + source + SuiBCS.list([amountArg]))
        commands.append(Data([1]) + SuiBCS.list([Data([3]) + SuiBCS.u16(split) + SuiBCS.u16(0)]) + recipientArg)
        // A redeemed coin is a new resource, so return its change explicitly.
        // Existing owned coins and the gas coin return to their owner implicitly.
        if assetCoins.isEmpty && (reference != "native" || gasCoins.isEmpty) && withdrawal > 0 {
            let owner = pure(try SuiBCS.address(sender))
            commands.append(Data([1]) + SuiBCS.list([source]) + owner)
        }
        let gas = try SuiBCS.list(gasCoins.map(SuiBCS.coin)) + SuiBCS.address(sender) + SuiBCS.u64(gasPrice) + SuiBCS.u64(gasBudget)
        // Chain-bound, randomized, finite replay protection also covers sends
        // using only address balances (which have no versioned object input).
        let expiration = Data([2,1]) + SuiBCS.u64(epoch) + Data([1]) + SuiBCS.u64(epoch+1) + Data([0,0]) +
            SuiBCS.vector(try SuiSendCrypto.unbase58(network.chainIdentifier)) + SuiBCS.u32(nonce)
        return Data([0,0]) + SuiBCS.list(inputs) + SuiBCS.list(commands) + (try SuiBCS.address(sender)) + gas + expiration
    }
}

enum SuiBCS {
    static func u16(_ v: Int) -> Data { Data([UInt8(truncatingIfNeeded:v),UInt8(truncatingIfNeeded:v >> 8)]) }
    static func u32(_ v: UInt32) -> Data { Data((0..<4).map { UInt8(truncatingIfNeeded: v >> ($0*8)) }) }
    static func u64(_ v: UInt64) -> Data { Data((0..<8).map { UInt8(truncatingIfNeeded: v >> ($0*8)) }) }
    static func length(_ count: Int) -> Data { var n = count, out = Data(); repeat { let low = UInt8(n & 127); n >>= 7; out.append(low | (n == 0 ? 0:128)) } while n > 0; return out }
    static func vector(_ bytes: Data) -> Data { length(bytes.count) + bytes }
    static func list(_ values: [Data]) -> Data { length(values.count) + values.reduce(Data(),+) }
    static func string(_ value: String) -> Data { vector(Data(value.utf8)) }
    static func input(_ index: Int) -> Data { Data([1]) + u16(index) }
    static func result(_ index: Int) -> Data { Data([2]) + u16(index) }
    static func address(_ value: String) throws -> Data {
        let hex = Array(try SuiIdentity.address(value).dropFirst(2)); return Data(stride(from:0,to:64,by:2).map { UInt8(String(hex[$0...$0+1]),radix:16)! })
    }
    static func coin(_ coin: SuiSendCoin) throws -> Data { try address(coin.id) + u64(coin.version) + vector(SuiSendCrypto.unbase58(coin.digest)) }
    static func type(_ value: String) throws -> Data {
        let primitives = ["bool":0,"u8":1,"u64":2,"u128":3,"address":4,"signer":5,"u16":8,"u32":9,"u256":10]
        if let index = primitives[value] { return Data([UInt8(index)]) }
        if value.hasPrefix("vector<"), value.hasSuffix(">") { return Data([6]) + (try type(String(value.dropFirst(7).dropLast()))) }
        let prefix = value.split(separator:"<",maxSplits:1).first.map(String.init) ?? ""
        let parts = prefix.components(separatedBy:"::")
        guard parts.count == 3 else { throw SuiSendError.malformed }
        var params = [Data]()
        if let start = value.firstIndex(of:"<") {
            let inner = value[value.index(after:start)..<value.index(before:value.endIndex)]
            var depth = 0, current = ""
            for c in inner {
                if c == "," && depth == 0 { params.append(try type(current)); current = ""; continue }
                current.append(c); if c == "<" { depth += 1 }; if c == ">" { depth -= 1 }
            }
            params.append(try type(current))
        }
        return Data([7]) + (try address(parts[0])) + string(parts[1]) + string(parts[2]) + list(params)
    }
}
