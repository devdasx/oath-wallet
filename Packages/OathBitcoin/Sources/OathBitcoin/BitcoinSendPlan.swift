import Foundation
internal import BitcoinDevKit

public enum BitcoinSendNetwork: String, Codable, Sendable {
    case mainnet, testnet, testnet4, chipnet, regtest
    var bdk: Network {
        switch self { case .mainnet: .bitcoin; case .testnet: .testnet; case .testnet4, .chipnet: .testnet4; case .regtest: .regtest }
    }
}

public enum BitcoinSendError: String, Error, Codable, Sendable {
    case invalidAmount, invalidRecipient, invalidInput, duplicateInput, insufficientFunds
    case feeUnavailable, feeTooHigh, tooLarge, changed, expired, signing, busy, submissionUnknown
    case invalidOptions, messageTooLarge
}

/// A funding output is anchored to its full, hash-checked previous transaction.
/// Address/path data is rederived from the vault again before signing.
public struct BitcoinSendCoin: Codable, Equatable, Sendable {
    public let accountID: String
    public let txid: String
    public let vout: Int
    public let value: Int64
    public let address: BitcoinDerivedAddress
    public let previousTransaction: Data
    public let compressed: Bool
    public var id: String { "\(txid):\(vout)" }
    public init(accountID: String, txid: String, vout: Int, value: Int64,
                address: BitcoinDerivedAddress, previousTransaction: Data, compressed: Bool = true) {
        self.accountID = accountID; self.txid = txid; self.vout = vout; self.value = value
        self.address = address; self.previousTransaction = previousTransaction; self.compressed = compressed
    }
    // Upper bounds include maximum DER signatures, not an average signature size.
    var inputWeight: Int64 {
        if let weight = address.multisigInputWeight { return weight }
        return switch address.type {
        case .legacy: (compressed ? 149 : 181) * 4
        case .nestedSegwit: 365
        case .nativeSegwit: 273
        case .taproot: 230
        }
    }
    func validate(chain: UTXONetwork = .bitcoin) throws {
        if let weight = address.multisigInputWeight {
            let witness = (chain == .bitcoin || chain == .litecoin) && (250...4000).contains(weight)
                && address.type == .nativeSegwit && address.script.hasPrefix("0020") && address.script.count == 68
            let legacyMultisig = [UTXONetwork.bitcoin, .bitcoincash, .dogecoin].contains(chain) && (600...7000).contains(weight) && address.type == .legacy
                && address.script.hasPrefix("a914") && address.script.hasSuffix("87") && address.script.count == 46
            guard witness || legacyMultisig else { throw BitcoinSendError.invalidInput }
        } else if address.script.hasPrefix("0020") { throw BitcoinSendError.invalidInput }
        guard value > 0, value <= chain.maximumOutput, vout >= 0, vout <= Int(UInt32.max),
              compressed || address.type == .legacy,
              try BitcoinTransactions.validates(previousTransaction, txid: txid, vout: vout,
                                                value: value, script: address.script, network: chain) else {
            throw BitcoinSendError.invalidInput
        }
        guard ([UTXONetwork.bitcoin, .litecoin].contains(chain) || ([UTXONetwork.bitcoincash, .dogecoin].contains(chain) && address.type == .legacy)),
              !(try BitcoinTransactions.hasTokens(previousTransaction, vout: vout, network: chain)),
              let script = Data(hex: address.script), BitcoinSendPlan.standardScript(script, chain: chain),
              (try? BitcoinSendPlan.recipientScript(address.address, chain: chain, network: .mainnet)) == script else {
            throw BitcoinSendError.invalidInput
        }
    }
}

public struct BitcoinSendPlan: Codable, Equatable, Sendable {
    public static let maximumMoney: Int64 = 2_100_000_000_000_000
    // Optional storage keeps existing Bitcoin journals decodable.
    private let chainValue: UTXONetwork?
    // Missing options identify pre-options journals; preserve their exact
    // sequence and outputs so recovery never changes an already signed intent.
    private let optionsValue: BitcoinSendOptions?
    public var options: BitcoinSendOptions { optionsValue ?? .init(replaceable: chain == .bitcoin || chain == .dogecoin) }
    public var inputSequence: UInt32 {
        if chain == .bitcoincash { return .max }
        // Preserve existing Litecoin behavior; its RBF UI is out of scope.
        if chain == .litecoin { return 0xfffffffd }
        return options.replaceable ? 0xfffffffd : 0xfffffffe
    }
    public var outputs: [BitcoinSendOutput] {
        var result = [BitcoinSendOutput(value: recipientAmount, script: recipientScript)]
        if changeAmount > 0, let script = Data(hex: change.script) { result.append(.init(value: changeAmount, script: script)) }
        if let script = options.dataScript { result.append(.init(value: 0, script: script)) }
        return result
    }
    public var chain: UTXONetwork { chainValue ?? .bitcoin }
    public let network: BitcoinSendNetwork
    public let coins: [BitcoinSendCoin]
    public let recipient: String
    public let recipientScript: Data
    public let requestedAmount: Int64
    public let recipientAmount: Int64
    public let change: BitcoinDerivedAddress
    public let changeAmount: Int64
    public let fee: Int64
    public let ratePerKVByte: Int64
    public let maximumVBytes: Int64
    public let walletBalance: Int64
    public let createdAt: Date
    public var deductedFromAmount: Int64 { requestedAmount - recipientAmount }
    public var total: Int64 { recipientAmount + fee }
    public var remainingBalance: Int64 { walletBalance - total }

    /// Spend remainder first. Deduct from the recipient only when no economic
    /// selection can preserve the requested amount. Never create a dust output.
    public static func make(coins: [BitcoinSendCoin], recipient: String, amount: Int64,
                            change: BitcoinDerivedAddress, ratePerKVByte: Int64,
                            network: BitcoinSendNetwork = .mainnet, chain: UTXONetwork = .bitcoin, options: BitcoinSendOptions = .init(), now: Date = .now) throws -> Self {
        try options.validate(chain: chain)
        let dataScripts = options.dataScript.map { [$0] } ?? []
        let maximumMoney = chain.maximumOutput
        guard amount > 0, amount <= maximumMoney else { throw BitcoinSendError.invalidAmount }
        guard chain.sendFeeRates.contains(ratePerKVByte) else { throw BitcoinSendError.feeUnavailable }
        guard !coins.isEmpty, coins.count <= 10_000 else { throw BitcoinSendError.insufficientFunds }
        guard Set(coins.map(\.id)).count == coins.count else { throw BitcoinSendError.duplicateInput }
        for coin in coins { try coin.validate(chain: chain) }
        let balance = try sum(coins.map(\.value), maximumMoney: chain.maximumMoney)
        guard amount <= balance else { throw BitcoinSendError.insufficientFunds }
        let script = try recipientScript(recipient, chain: chain, network: network)
        guard standardScript(script, chain: chain),
              let changeScript = Data(hex: change.script), standardScript(changeScript, chain: chain),
              (try? recipientScript(change.address, chain: chain, network: .mainnet)) == changeScript else {
            throw BitcoinSendError.invalidRecipient
        }
        guard amount >= dust(script, chain: chain) else { throw BitcoinSendError.invalidAmount }
        let economic = coins.filter { $0.value > feeFor(($0.inputWeight + 3) / 4, ratePerKVByte) }
            .sorted {
                let left = $0.value - feeFor(($0.inputWeight + 3) / 4, ratePerKVByte)
                let right = $1.value - feeFor(($1.inputWeight + 3) / 4, ratePerKVByte)
                return left == right ? $0.id < $1.id : left > right
            }
        var best: Self?
        var exceededSize = false
        func candidate(_ selected: [BitcoinSendCoin], mayDeduct: Bool = false) throws -> Self? {
            guard !selected.isEmpty, selected.count <= 1000 else { return nil }
            guard let input = try? sum(selected.map(\.value), maximumMoney: chain.maximumOutput) else { return nil }
            let oneSize = vbytes(selected, scripts: [script] + dataScripts)
            let twoSize = vbytes(selected, scripts: [script, changeScript] + dataScripts)
            guard oneSize <= 100_000 else { exceededSize = true; return nil }
            if twoSize > 100_000 { exceededSize = true }
            let changeFloor = chain == .dogecoin ? 1_000_000 : dust(changeScript, chain: chain)
            let oneFee = requiredFee(oneSize, ratePerKVByte, amounts: [amount], chain: chain)
            let twoFee = requiredFee(twoSize, ratePerKVByte, amounts: [amount, changeFloor], chain: chain)
            let output: Int64, changeValue: Int64, fee: Int64, size: Int64
            if twoSize <= 100_000, input >= amount + twoFee + changeFloor {
                output = amount; changeValue = input - amount - twoFee; fee = twoFee; size = twoSize
            } else if input >= amount + oneFee {
                output = amount; changeValue = 0; fee = input - amount; size = oneSize
                // Avoid burning substantial change just because its extra
                // output fee makes a two-output transaction uneconomic.
                guard fee - oneFee < changeFloor + twoFee - oneFee else { return nil }
            } else if mayDeduct, input > oneFee, input - oneFee >= dust(script, chain: chain) {
                let adjusted = min(amount, input - oneFee)
                let adjustedFee = requiredFee(oneSize, ratePerKVByte, amounts: [adjusted], chain: chain)
                guard input - adjustedFee >= dust(script, chain: chain) else { return nil }
                output = min(amount, input - adjustedFee); changeValue = 0; fee = input - output; size = oneSize
            } else { return nil }
            guard fee <= chain.maximumSendFee else { throw BitcoinSendError.feeTooHigh }
            return Self(chainValue: chain, optionsValue: options, network: network, coins: selected, recipient: recipient, recipientScript: script,
                        requestedAmount: amount, recipientAmount: output, change: change, changeAmount: changeValue,
                        fee: fee, ratePerKVByte: ratePerKVByte, maximumVBytes: size,
                        walletBalance: balance, createdAt: now)
        }
        func consider(_ selected: [BitcoinSendCoin]) throws {
            guard let plan = try candidate(selected) else { return }
            let cost = plan.fee + (plan.changeAmount > 0 ? feeFor([UTXONetwork.bitcoincash, .dogecoin].contains(chain) ? 149 : 69, ratePerKVByte) : 0)
            let priorCost = best.map { $0.fee + ($0.changeAmount > 0 ? feeFor([UTXONetwork.bitcoincash, .dogecoin].contains(chain) ? 149 : 69, ratePerKVByte) : 0) } ?? Int64.max
            if cost < priorCost || (cost == priorCost && plan.coins.count < (best?.coins.count ?? Int.max)) { best = plan }
        }
        // Bounded exact-match search, plus deterministic accumulations for large
        // wallets. CPU work is bounded independently of the wallet's value.
        for coin in economic { try consider([coin]) }
        var selected: [BitcoinSendCoin] = []
        for coin in economic.prefix(1000) {
            selected.append(coin)
            try consider(selected)
            if best != nil { break }
        }
        let subset = Array(economic.prefix(18))
        var nodes = 0
        func search(_ index: Int, _ selected: [BitcoinSendCoin], _ value: Int64) throws {
            guard nodes < 20_000 else { return }; nodes += 1
            if value >= amount { try consider(selected) }
            guard index < subset.count, selected.count < (best?.coins.count ?? 1001) else { return }
            try search(index + 1, selected + [subset[index]], value + subset[index].value)
            try search(index + 1, selected, value)
        }
        try search(0, [], 0)
        if let best { return best }
        // Insufficient remainder: use the economic pool and show the adjusted
        // recipient amount on review before the user authorizes this plan.
        guard economic.count <= 1000, let sweep = try candidate(economic, mayDeduct: true) else {
            throw exceededSize ? BitcoinSendError.tooLarge : BitcoinSendError.insufficientFunds
        }
        return sweep
    }

    public func validate(now: Date = .now, checkExpiry: Bool = true) throws {
        try options.validate(chain: chain)
        guard !checkExpiry || (0...120).contains(now.timeIntervalSince(createdAt)) else { throw BitcoinSendError.expired }
        guard !coins.isEmpty, coins.count <= 1000 else { throw BitcoinSendError.tooLarge }
        for coin in coins { try coin.validate(chain: chain) }
        guard walletBalance > 0, walletBalance <= chain.maximumMoney,
              recipientAmount <= chain.maximumOutput, changeAmount <= chain.maximumOutput, fee <= chain.maximumSendFee,
              change.index < BitcoinKeys.firstHardenedChild,
              chain.sendFeeRates.contains(ratePerKVByte), requestedAmount > 0,
              requestedAmount <= walletBalance, requestedAmount <= chain.maximumOutput, recipientAmount > 0, changeAmount >= 0, fee >= 0,
              let changeScript = Data(hex: change.script), Self.standardScript(changeScript, chain: chain), Self.standardScript(recipientScript, chain: chain),
              (try? Self.recipientScript(recipient, chain: chain, network: network)) == recipientScript,
              (try? Self.recipientScript(change.address, chain: chain, network: .mainnet)) == changeScript else {
            throw BitcoinSendError.changed
        }
        guard !coins.isEmpty, coins.count <= 1000, Set(coins.map(\.id)).count == coins.count,
              recipientAmount >= Self.dust(recipientScript, chain: chain), recipientAmount <= requestedAmount,
              changeAmount == 0 || changeAmount >= Self.dust(changeScript, chain: chain),
              try Self.sum(coins.map(\.value), maximumMoney: chain.maximumOutput) == recipientAmount + changeAmount + fee,
              maximumVBytes == Self.vbytes(coins, scripts: outputs.map(\.script)),
              maximumVBytes <= 100_000, fee >= Self.requiredFee(maximumVBytes, ratePerKVByte, amounts: changeAmount > 0 ? [recipientAmount, changeAmount] : [recipientAmount], chain: chain), fee <= chain.maximumSendFee,
              walletBalance >= recipientAmount + changeAmount + fee, walletBalance <= chain.maximumMoney else { throw BitcoinSendError.changed }
    }

    public func validateSigned(_ signed: BitcoinSignedSend) throws {
        try validate(checkExpiry: false)
        try checkSigned(signed)
    }

    // Signers already validate before accessing keys; avoid re-parsing every
    // funding transaction a second time after signing. Journals use the public
    // fully validating entry point above.
    func checkSigned(_ signed: BitcoinSignedSend) throws {
        let tx = try Transaction(transactionBytes: signed.raw)
        let actualInputs = tx.input(), actualOutputs = tx.output()
        guard tx.version() == 2, tx.lockTime() == 0,
              tx.computeTxid().description == signed.txid,
              signed.fee == fee, signed.virtualBytes == tx.vsize(), tx.vsize() <= UInt64(maximumVBytes),
              actualInputs.count == coins.count,
              zip(actualInputs, coins).allSatisfy({ input, coin in
                  input.previousOutput.txid.description == coin.txid && input.previousOutput.vout == UInt32(coin.vout) &&
                  input.sequence == inputSequence && (!input.scriptSig.toBytes().isEmpty || !input.witness.isEmpty) &&
                  ((chain != .dogecoin && chain != .bitcoincash) || input.witness.isEmpty)
              }), actualOutputs.count == outputs.count,
              zip(actualOutputs, outputs).allSatisfy({ $0.value.toSat() == UInt64($1.value) && $0.scriptPubkey.toBytes() == $1.script }) else {
            throw BitcoinSendError.changed
        }
    }

    public static func address(_ address: BitcoinDerivedAddress, on network: BitcoinSendNetwork, chain: UTXONetwork = .bitcoin) throws -> String {
        guard let bytes = Data(hex: address.script) else { throw BitcoinSendError.invalidRecipient }
        if chain == .bitcoincash { return try CashAddress.encode(script: bytes, prefix: network == .mainnet ? "bitcoincash" : network == .regtest ? "bchreg" : "bchtest") }
        if chain == .litecoin { return try LitecoinAddress.encode(script: bytes, network: network) }
        if chain == .dogecoin { return try DogecoinAddress.encode(script: bytes, network: network) }
        guard chain == .bitcoin else { throw BitcoinError.wrongNetwork }
        return try Address.fromScript(script: Script(rawOutputScript: bytes), network: network.bdk).description
    }
    /// Exact, checksum-verified network decoding shared by review and signing.
    public static func recipientScript(_ value: String, chain: UTXONetwork,
                                       network: BitcoinSendNetwork = .mainnet) throws -> Data {
        if chain == .bitcoincash {
            return try CashAddress.decode(value, prefix: network == .mainnet ? "bitcoincash" : network == .regtest ? "bchreg" : "bchtest")
        }
        if chain == .litecoin { return try LitecoinAddress.decode(value, network: network) }
        if chain == .dogecoin { return try DogecoinAddress.decode(value, network: network) }
        guard chain == .bitcoin, network != .chipnet, let address = try? Address(address: value, network: network.bdk),
              address.isValidForNetwork(network: network.bdk) else { throw BitcoinSendError.invalidRecipient }
        return address.scriptPubkey().toBytes()
    }
    static func sum(_ values: [Int64], maximumMoney: Int64 = Self.maximumMoney) throws -> Int64 {
        var total: Int64 = 0
        for value in values {
            guard value >= 0, value <= maximumMoney - total else { throw BitcoinSendError.invalidInput }
            total += value
        }
        return total
    }
    static func feeFor(_ bytes: Int64, _ rate: Int64) -> Int64 { (bytes * rate + 999) / 1000 }
    static func requiredFee(_ bytes: Int64, _ rate: Int64, amounts: [Int64], chain: UTXONetwork) -> Int64 {
        // Core's soft-dust policy adds 0.01 DOGE per output below 0.01 DOGE.
        // Small recipients remain possible; small change is folded into fees.
        feeFor(bytes, rate) + (chain == .dogecoin ? Int64(amounts.filter { $0 < 1_000_000 }.count) * 1_000_000 : 0)
    }
    static func vbytes(_ coins: [BitcoinSendCoin], scripts: [Data]) -> Int64 {
        let witness = coins.contains { $0.address.type != .legacy }
        let base = 8 + BitcoinWire.compact(UInt64(coins.count)).count + BitcoinWire.compact(UInt64(scripts.count)).count
        var weight = Int64(base + scripts.reduce(0) { $0 + 8 + BitcoinWire.compact(UInt64($1.count)).count + $1.count }) * 4
        weight += coins.reduce(0) { $0 + $1.inputWeight }
        if witness { weight += 2 + Int64(coins.filter { $0.address.type == .legacy }.count) }
        return (weight + 3) / 4
    }
    static func standardScript(_ script: Data, chain: UTXONetwork = .bitcoin) -> Bool {
        let b = Array(script)
        if chain == .dogecoin {
            return (b.count == 25 && b.prefix(3) == [0x76,0xa9,0x14] && b.suffix(2) == [0x88,0xac]) ||
                (b.count == 23 && b.prefix(2) == [0xa9,0x14] && b.last == 0x87)
        }
        if chain == .bitcoincash {
            return (b.count == 25 && b.prefix(3) == [0x76,0xa9,0x14] && b.suffix(2) == [0x88,0xac]) ||
                (b.count == 23 && b.prefix(2) == [0xa9,0x14] && b.last == 0x87) ||
                (b.count == 35 && b.prefix(2) == [0xaa,0x20] && b.last == 0x87)
        }
        guard [.bitcoin, .litecoin].contains(chain) else { return false }
        return (b.count == 25 && b.prefix(3) == [0x76,0xa9,0x14] && b.suffix(2) == [0x88,0xac]) ||
            (b.count == 23 && b.prefix(2) == [0xa9,0x14] && b.last == 0x87) ||
            (b.count == 22 && b.prefix(2) == [0,20]) ||
            (b.count == 34 && (b.prefix(2) == [0,32] || b.prefix(2) == [0x51,32]))
    }
    static func dust(_ script: Data, chain: UTXONetwork = .bitcoin) -> Int64 {
        // Dogecoin hard dust is 0.001 DOGE; soft dust is priced in requiredFee.
        if chain == .dogecoin { return 100_000 }
        // Default relay dust policy: Bitcoin/BCH 3 sat/vB, Litecoin 30. Includes
        // witness-program discount. Dust is output-specific, not wallet-wide.
        let witness = script.count == 22 || script.count == 34
        return Int64(8 + 1 + script.count + (witness ? 67 : 148)) * (chain == .litecoin ? 30 : 3)
    }
}

enum BitcoinWire {
    static func little<T: FixedWidthInteger>(_ value: T) -> Data {
        var value = value.littleEndian
        return withUnsafeBytes(of: &value) { Data($0) }
    }
    static func compact(_ value: UInt64) -> Data {
        if value < 253 { return Data([UInt8(value)]) }
        if value <= UInt16.max { return Data([253]) + little(UInt16(value)) }
        if value <= UInt32.max { return Data([254]) + little(UInt32(value)) }
        return Data([255]) + little(value)
    }
    static func vector(_ data: Data) -> Data { compact(UInt64(data.count)) + data }
    static func pair(_ key: UInt8, _ data: Data) -> Data { Data([1,key]) + vector(data) }
}
