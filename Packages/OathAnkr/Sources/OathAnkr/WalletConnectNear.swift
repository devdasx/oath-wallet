import Foundation
import CryptoKit

public extension NearSendNetwork {
    var walletConnectChain:String { "near:" + rawValue }
    var walletConnectName:String { self == .mainnet ? "NEAR" : "NEAR Testnet" }
    init?(walletConnectChain:String) {
        guard let value = Self(rawValue:String(walletConnectChain.dropFirst(5))), value.walletConnectChain == walletConnectChain else { return nil }
        self = value
    }
}

public struct WalletConnectNearRequest: Codable, Sendable, Equatable {
    public static let signingMethods:Set<String> = Set(["near_signTransaction","near_signTransactions"]).union(WalletConnectNearAccess.methods)
    public static let methods = signingMethods.union(["near_getAccounts"])
    public let method:String, account:String
    public let network:NearSendNetwork
    public let transactions:[Data]
    public init(method:String,chain:String,account:String,params:Data) throws {
        guard ["near_getAccounts","near_signTransaction","near_signTransactions"].contains(method), let network = NearSendNetwork(walletConnectChain:chain) else { throw NearSendError.wrongNetwork }
        let value = try WalletConnectJSON.decode(params, byteLimit:600_000, collectionLimit:131_072, nodeLimit:150_000)
        guard let fields = value.fields else { throw NearSendError.malformed }
        self.method = method; self.network = network; self.account = try NearIdentity.address(account)
        if method == "near_getAccounts" {
            guard fields.isEmpty else { throw NearSendError.malformed }; transactions = []; return
        }
        let buffers:[NearJSON]
        if method == "near_signTransaction" {
            guard Set(fields.keys) == ["transaction"] else { throw NearSendError.malformed }; buffers = [value["transaction"]]
        } else {
            guard Set(fields.keys) == ["transactions"], let values = value["transactions"].array, (1...16).contains(values.count) else { throw NearSendError.malformed }; buffers = values
        }
        transactions = try buffers.map { buffer in
            guard Set(buffer.fields?.keys.map{$0} ?? []) == ["type","data"], buffer["type"].string == "Buffer",
                  let array = buffer["data"].array, (1...131_072).contains(array.count) else { throw NearSendError.malformed }
            return try Data(array.map { item in
                guard case .number(let text) = item, let byte = UInt8(text), String(byte) == text else { throw NearSendError.malformed }; return byte
            })
        }
        guard transactions.reduce(0,{$0+$1.count}) <= 131_072 else { throw NearSendError.malformed }
        var previous:UInt64?
        for bytes in transactions {
            let tx = try WalletConnectNearTransaction(bytes)
            guard tx.sender == self.account, previous.map({$0 < tx.nonce}) ?? true else { throw NearSendError.wrongOwner }
            previous = tx.nonce
        }
    }
    public static func accountResponse(account:String,publicKey:Data) throws -> NearJSON {
        guard publicKey.count == 32 else { throw NearSendError.wrongOwner }
        return .array([.object(["accountId":.string(try NearIdentity.address(account)),"publicKey":.string(NearSendCrypto.keyString(publicKey))])])
    }
    public func sign(privateKey:Data,review:WalletConnectNearReview,now:Date = .now) throws -> NearJSON {
        guard review.request == self, !transactions.isEmpty, now.timeIntervalSince(review.createdAt) >= 0,
              now.timeIntervalSince(review.createdAt) <= 120 else { throw NearSendError.expired }
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation:privateKey)
        let results = try transactions.map { bytes -> NearJSON in
            let tx = try WalletConnectNearTransaction(bytes)
            guard tx.sender == account, tx.publicKey == key.publicKey.rawRepresentation else { throw NearSendError.wrongOwner }
            let signature = try key.signature(for:Data(SHA256.hash(data:bytes)))
            return Self.buffer(bytes + Data([0]) + signature)
        }
        return method == "near_signTransaction" ? results[0] : .array(results)
    }
    public static func buffer(_ bytes:Data) -> NearJSON { .object(["type":.string("Buffer"),"data":.array(bytes.map{.number(String($0))})]) }
}

public struct WalletConnectNearTransaction: Codable, Sendable, Equatable {
    public let sender:String, receiver:String, blockHash:String
    public let publicKey:Data
    public let nonce:UInt64
    public let actions:[Action]
    public struct Action:Codable, Sendable, Equatable {
        public let kind:UInt8, description:String, deposit:String, gas:UInt64, byteCount:Int, methodCount:Int
        public let fullAccess:Bool
    }
    public init(_ bytes:Data) throws {
        guard bytes.count <= 131_072 else { throw NearSendError.malformed }
        var r = NearConnectReader(bytes:bytes)
        sender = try NearIdentity.address(r.text(64)); publicKey = try r.key(); nonce = try r.uint(8)
        receiver = try NearIdentity.address(r.text(64)); blockHash = SuiSendCrypto.base58(try r.take(32))
        let count = try r.length(100); guard count > 0, nonce > 0 else { throw NearSendError.malformed }
        var actions = [Action]()
        for _ in 0..<count {
            let kind = UInt8(try r.uint(1))
            var deposit = "0", gas:UInt64 = 0, size = 0, methods = 0, description = "", fullAccess = false
            switch kind {
            case 0: description = "Create account"
            case 1:
                let code = try r.blob(131_072); size = code.count
                description = "Deploy contract · SHA256 " + SHA256.hash(data:code).map{String(format:"%02x",$0)}.joined()
            case 2:
                let method = try r.text(256), args = try r.blob(65_536)
                gas = try r.uint(8); deposit = try r.amount(); size = method.utf8.count + args.count
                guard !method.isEmpty, gas > 0, gas <= 300_000_000_000_000 else { throw NearSendError.malformed }
                description = "Call " + method + "\nDeposit: " + deposit + " yoctoNEAR\nGas: " + String(gas) + "\nArguments (base64): " + args.base64EncodedString()
            case 3: deposit = try r.amount(); description = "Transfer " + deposit + " yoctoNEAR"
            case 4: deposit = try r.amount(); description = "Stake " + deposit + " yoctoNEAR\nValidator key: " + NearSendCrypto.keyString(try r.key())
            case 5:
                let key = try r.key(), nonce = try r.uint(8), permission = try r.uint(1)
                guard nonce == 0 else { throw NearSendError.malformed }
                description = "Add access key " + NearSendCrypto.keyString(key)
                if permission == 1 { fullAccess = true; description += "\nFULL ACCESS: this key can control the entire account." }
                else if permission == 0 {
                    let option = try r.uint(1); guard option <= 1 else { throw NearSendError.malformed }
                    let allowance = option == 1 ? try r.amount() : "Unlimited"
                    let contract = try NearIdentity.address(r.text(64)); methods = try r.length(128)
                    var names = [String]()
                    for _ in 0..<methods { let name = try r.text(256); guard !name.isEmpty else { throw NearSendError.malformed }; names.append(name); size += name.utf8.count }
                    description += "\nContract: " + contract + "\nMethods: " + (names.isEmpty ? "All methods" : names.joined(separator:", ")) + "\nGas allowance (yoctoNEAR): " + allowance
                } else { throw NearSendError.malformed }
            case 6: description = "Delete access key " + NearSendCrypto.keyString(try r.key())
            case 7: description = "DELETE ACCOUNT\nRemaining balance goes to " + (try NearIdentity.address(r.text(64)))
            default: throw NearSendError.unsupportedAccount
            }
            actions.append(.init(kind:kind,description:description,deposit:deposit,gas:gas,byteCount:size,methodCount:methods,fullAccess:fullAccess))
        }
        guard r.offset == bytes.count else { throw NearSendError.malformed }
        self.actions = actions
    }
}
private struct NearConnectReader {
    let bytes:Data
    var offset = 0
    mutating func take(_ n:Int) throws -> Data {
        guard n >= 0, n <= bytes.count-offset else { throw NearSendError.malformed }
        defer { offset += n }; return Data(bytes[offset..<offset+n])
    }
    mutating func uint(_ n:Int) throws -> UInt64 { try take(n).enumerated().reduce(UInt64(0)){$0 | UInt64($1.element) << ($1.offset*8)} }
    mutating func length(_ max:Int) throws -> Int { let n = try uint(4); guard n <= max else { throw NearSendError.malformed }; return Int(n) }
    mutating func blob(_ max:Int) throws -> Data { try take(length(max)) }
    mutating func text(_ max:Int) throws -> String {
        guard let text = String(data:try blob(max),encoding:.utf8), !text.unicodeScalars.contains(where:{$0.properties.isBidiControl || $0.value < 32}) else { throw NearSendError.malformed }; return text
    }
    mutating func key() throws -> Data { guard try uint(1) == 0 else { throw NearSendError.unsupportedAccount }; return try take(32) }
    mutating func amount() throws -> String {
        var result = "0"
        for byte in try take(16).reversed() { result = try NearSendAmount.add(NearSendAmount.multiply(result,256),String(byte)) }
        return result
    }
}
public struct WalletConnectNearReview:Codable,Sendable,Equatable {
    public let request:WalletConnectNearRequest
    public let fee:String
    public let transactions:[WalletConnectNearTransaction]
    public let createdAt:Date
}

public extension NearSendClient {
    func walletConnectAccounts(account:String,publicKey:Data) async throws -> NearJSON {
        let block = try await finalBlock(), hash = try NearIdentity.hash(block["hash"])
        let key = try await query(["request_type":.string("view_access_key"),"account_id":.string(try NearIdentity.address(account)),"public_key":.string(NearSendCrypto.keyString(publicKey))],block:hash)
        guard key["permission"].string == "FullAccess" else { throw NearSendError.unsupportedAccount }
        return try WalletConnectNearRequest.accountResponse(account:account,publicKey:publicKey)
    }
    func walletConnectReview(_ input:WalletConnectNearRequest,publicKey:Data) async throws -> WalletConnectNearReview {
        guard input.network == network, !input.transactions.isEmpty, publicKey.count == 32 else { throw NearSendError.wrongNetwork }
        let transactions = try input.transactions.map(WalletConnectNearTransaction.init)
        guard transactions.allSatisfy({$0.publicKey == publicKey && $0.sender == input.account}) else { throw NearSendError.wrongOwner }
        let header = try await finalBlock(), hash = try NearIdentity.hash(header["hash"]), height = try NearIdentity.height(header["height"])
        async let configWork = rpc("EXPERIMENTAL_protocol_config",.object(["block_id":.string(hash)]))
        async let priceWork = rpc("gas_price",.array([.string(hash)]))
        async let accountWork = account(input.account,block:hash)
        async let keyWork = query(["request_type":.string("view_access_key"),"account_id":.string(input.account),"public_key":.string(NearSendCrypto.keyString(publicKey))],block:hash)
        let (config,price,state,key) = try await (configWork,priceWork,accountWork,keyWork)
        guard config["chain_id"].string == network.rawValue, key["permission"].string == "FullAccess",
              let nonce = key["nonce"].integer, let first = transactions.first, first.nonce > nonce,
              let validity = config["transaction_validity_period"].integer, validity > 0 else { throw NearSendError.changed }
        guard height > 0, UInt64(height) <= UInt64.max / 1_000_000,
              transactions.allSatisfy({$0.nonce < UInt64(height)*1_000_000}) else { throw NearSendError.changed }
        // A block hash is the transaction's network/replay boundary. Resolve it on
        // the approved network instead of trusting the peer's chain label.
        for block in Set(transactions.map(\.blockHash)) {
            let found = try await rpc("block",.object(["block_id":.string(block)]))["header"]
            let blockHeight = try NearIdentity.height(found["height"])
            guard found["hash"].string == block, blockHeight <= height, UInt64(height-blockHeight) < validity else { throw NearSendError.expired }
        }
        let runtime = config["runtime_config"], costs = runtime["transaction_costs"], actionCosts = costs["action_creation_config"]
        let market = try NearIdentity.amount(price["gas_price"]), floor = runtime["min_gas_purchase_price"].isNull ? "0" : try NearIdentity.amount(runtime["min_gas_purchase_price"])
        let ceiling = try NearSendAmount.multiply(XrplSendAmount.less(market,floor) ? floor:market,2)
        func cost(_ node:NearJSON) throws -> UInt64 {
            guard let send = node["send_not_sir"].integer, let execution = node["execution"].integer, send <= 10_000_000_000_000, execution <= 10_000_000_000_000 else { throw NearSendError.malformed }; return send+execution
        }
        var fee = "0", deposits = "0"
        for tx in transactions {
            var prepaid = try cost(costs["action_receipt_creation_config"])
            for action in tx.actions {
                deposits = try NearSendAmount.add(deposits,action.deposit)
                switch action.kind {
                case 0: prepaid += try cost(actionCosts["create_account_cost"])
                case 1: prepaid += try cost(actionCosts["deploy_contract_cost"]) + UInt64(action.byteCount)*cost(actionCosts["deploy_contract_cost_per_byte"])
                case 2: prepaid += try action.gas + cost(actionCosts["function_call_cost"]) + UInt64(action.byteCount)*cost(actionCosts["function_call_cost_per_byte"])
                case 3:
                    prepaid += try cost(actionCosts["transfer_cost"])
                    if NearSendPlan.isImplicit(tx.receiver) { prepaid += try cost(actionCosts["create_account_cost"]) + cost(actionCosts["add_key_cost"]["full_access_cost"]) }
                case 4: prepaid += try cost(actionCosts["stake_cost"])
                case 5:
                    let add = actionCosts["add_key_cost"]
                    if action.fullAccess { prepaid += try cost(add["full_access_cost"]) }
                    else { prepaid += try cost(add["function_call_cost"]) + UInt64(action.byteCount)*cost(add["function_call_cost_per_byte"]) }
                case 6: prepaid += try cost(actionCosts["delete_key_cost"])
                case 7: prepaid += try cost(actionCosts["delete_account_cost"])
                default: throw NearSendError.unsupportedAccount
                }
                guard prepaid <= 300_000_000_000_000 else { throw NearSendError.feeTooHigh }
            }
            guard prepaid <= 300_000_000_000_000 else { throw NearSendError.feeTooHigh }
            fee = try NearSendAmount.add(fee,NearSendAmount.multiply(ceiling,prepaid))
            if NearSendPlan.isImplicit(tx.receiver), !runtime["account_creation_charge"].isNull {
                fee = try NearSendAmount.add(fee,NearIdentity.amount(runtime["account_creation_charge"]))
            }
        }
        let native = try NearIdentity.amount(state["amount"]), locked = try NearIdentity.amount(state["locked"])
        guard let storage = state["storage_usage"].integer else { throw NearSendError.malformed }
        let storageCost = try NearSendAmount.multiply(NearIdentity.amount(runtime["storage_amount_per_byte"]),storage)
        let reserve = XrplSendAmount.less(storageCost,locked) ? "0" : try NearSendAmount.subtract(storageCost,locked)
        guard try !XrplSendAmount.less(native,NearSendAmount.add(reserve,NearSendAmount.add(fee,deposits))) else { throw NearSendError.insufficientFunds }
        return .init(request:input,fee:fee,transactions:transactions,createdAt:.now)
    }
    func walletConnectPreflight(_ review:WalletConnectNearReview,publicKey:Data) async throws {
        guard Date.now.timeIntervalSince(review.createdAt) <= 120 else { throw NearSendError.expired }
        let current = try await walletConnectReview(review.request,publicKey:publicKey)
        guard !XrplSendAmount.less(review.fee,current.fee) else { throw NearSendError.changed }
    }
}
