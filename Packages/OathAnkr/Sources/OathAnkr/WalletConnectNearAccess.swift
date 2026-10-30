import Foundation
import CryptoKit

public struct WalletConnectNearAccess:Codable,Sendable,Equatable {
    public static let methods:Set<String> = ["near_signIn","near_signOut"]
    public static let allowance = "250000000000000000000000"
    public let method:String, account:String
    public let network:NearSendNetwork
    public let publicKeys:[Data]
    public let receiver:String?
    public let methodNames:[String]
    public var fingerprint:String { SHA256.hash(data:canonical).map{String(format:"%02x",$0)}.joined() }
    private var canonical:Data {
        var data = NearSendCrypto.text(method)+NearSendCrypto.text(network.walletConnectChain)+NearSendCrypto.text(account)
        data += NearSendCrypto.le(UInt32(publicKeys.count))
        for key in publicKeys { data += key }
        data += NearSendCrypto.text(receiver ?? "")
        data += NearSendCrypto.le(UInt32(methodNames.count))
        for name in methodNames { data += NearSendCrypto.text(name) }
        return data
    }
    public init(method:String,chain:String,account:String,params:Data) throws {
        guard Self.methods.contains(method), let network = NearSendNetwork(walletConnectChain:chain) else { throw NearSendError.wrongNetwork }
        self.method = method; self.network = network; self.account = try NearIdentity.address(account)
        let value = try WalletConnectJSON.decode(params)
        guard let fields = value.fields, Set(fields.keys) == (method == "near_signIn" ? ["accounts","permission"] : ["accounts"]),
              let accounts = value["accounts"].array, (1...8).contains(accounts.count) else { throw NearSendError.malformed }
        publicKeys = try accounts.map { item in
            guard Set(item.fields?.keys.map{$0} ?? []) == ["accountId","publicKey"], item["accountId"].string == account,
                  let text = item["publicKey"].string, text.hasPrefix("ed25519:") else { throw NearSendError.wrongOwner }
            let key = try SuiSendCrypto.unbase58(String(text.dropFirst(8)))
            guard key.count == 32, NearSendCrypto.keyString(key) == text else { throw NearSendError.malformed }; return key
        }
        guard Set(publicKeys).count == publicKeys.count else { throw NearSendError.malformed }
        if method == "near_signIn" {
            let permission = value["permission"]
            guard Set(permission.fields?.keys.map{$0} ?? []) == ["receiverId","methodNames"], let names = permission["methodNames"].array, names.count <= 64 else { throw NearSendError.malformed }
            receiver = try NearIdentity.address(permission["receiverId"].string ?? "")
            methodNames = try names.map { value in
                guard let name = value.string, !name.isEmpty, name.utf8.count <= 128,
                      !name.unicodeScalars.contains(where:{$0.properties.isBidiControl || $0.value < 32}) else { throw NearSendError.malformed }; return name
            }
            guard Set(methodNames).count == methodNames.count else { throw NearSendError.malformed }
        } else { receiver = nil; methodNames = [] }
    }
    public func actions() throws -> [Data] {
        try publicKeys.map { key in
            if method == "near_signOut" { return Data([6,0])+key }
            guard let receiver else { throw NearSendError.malformed }
            var action = Data([5,0])+key+NearSendCrypto.le(UInt64(0))+Data([0,1])
            action += try NearSendCrypto.u128(Self.allowance)
            action += NearSendCrypto.text(receiver)+NearSendCrypto.le(UInt32(methodNames.count))
            for name in methodNames { action += NearSendCrypto.text(name) }
            return action
        }
    }
    public func validate(_ review:WalletConnectNearReview) throws {
        guard review.request.network == network, review.request.account == account, review.request.method == "near_signTransaction",
              review.request.transactions.count == 1 else { throw NearSendError.changed }
        let bytes = review.request.transactions[0], tx = try WalletConnectNearTransaction(bytes), actions = try actions()
        let expected = NearSendCrypto.text(account)+Data([0])+tx.publicKey+NearSendCrypto.le(tx.nonce)+NearSendCrypto.text(account) + (try SuiSendCrypto.unbase58(tx.blockHash)) + NearSendCrypto.le(UInt32(actions.count))+actions.reduce(Data(),+)
        guard bytes == expected, !publicKeys.contains(tx.publicKey) else { throw NearSendError.changed }
    }
    public static func signed(_ response:NearJSON,review:WalletConnectNearReview) throws -> NearSignedSend {
        guard response["type"].string == "Buffer", let values = response["data"].array else { throw NearSendError.malformed }
        let bytes = try Data(values.map { item in guard let n = item.integer, n <= 255 else { throw NearSendError.malformed }; return UInt8(n) })
        guard let raw = review.request.transactions.first, bytes.count == raw.count+65 else { throw NearSendError.malformed }
        let tx = try WalletConnectNearTransaction(raw)
        let signed = NearSignedSend(bytes:bytes,publicKey:tx.publicKey,signature:Data(bytes.suffix(64)),hash:SuiSendCrypto.base58(Data(SHA256.hash(data:raw))))
        try verify(signed,review:review); return signed
    }
    public static func verify(_ signed:NearSignedSend,review:WalletConnectNearReview) throws {
        guard review.request.transactions.count == 1, let raw = review.request.transactions.first else { throw NearSendError.changed }
        let tx = try WalletConnectNearTransaction(raw), digest = Data(SHA256.hash(data:raw))
        guard signed.bytes == raw+Data([0])+signed.signature, signed.publicKey == tx.publicKey,
              signed.hash == SuiSendCrypto.base58(digest), signed.multisigParts == nil,
              try Curve25519.Signing.PublicKey(rawRepresentation:tx.publicKey).isValidSignature(signed.signature,for:digest) else { throw NearSendError.signing }
    }
}
public struct WalletConnectNearGrant:Codable,Sendable,Equatable {
    public let publicKey:Data, receiver:String, methodNames:[String]
    public init(publicKey:Data,receiver:String,methodNames:[String]) { self.publicKey = publicKey; self.receiver = receiver; self.methodNames = methodNames }
}
public extension NearSendClient {
    func walletConnectAccessReview(_ access:WalletConnectNearAccess,publicKey:Data,grants:[WalletConnectNearGrant]) async throws -> WalletConnectNearReview {
        guard access.network == network, !access.publicKeys.contains(publicKey) else { throw NearSendError.wrongOwner }
        let header = try await finalBlock(), hash = try NearIdentity.hash(header["hash"])
        async let keyWork = query(["request_type":.string("view_access_key"),"account_id":.string(access.account),"public_key":.string(NearSendCrypto.keyString(publicKey))],block:hash)
        async let keysWork = query(["request_type":.string("view_access_key_list"),"account_id":.string(access.account)],block:hash)
        let (key,keys) = try await (keyWork,keysWork)
        guard key["permission"].string == "FullAccess", let nonce = key["nonce"].integer, nonce < UInt64.max,
              let existing = keys["keys"].array else { throw NearSendError.unsupportedAccount }
        for candidate in access.publicKeys {
            let found = existing.first { $0["public_key"].string == NearSendCrypto.keyString(candidate) }
            if access.method == "near_signIn" { guard found == nil else { throw NearSendError.changed } }
            else {
                guard let grant = grants.first(where:{$0.publicKey == candidate}), let found else { throw NearSendError.wrongOwner }
                let permission = found["access_key"]["permission"]["FunctionCall"]
                guard permission["receiver_id"].string == grant.receiver,
                      permission["method_names"].array?.compactMap(\.string) == grant.methodNames else { throw NearSendError.wrongOwner }
            }
        }
        let actions = try access.actions()
        let raw = NearSendCrypto.text(access.account)+Data([0])+publicKey+NearSendCrypto.le(nonce+1)+NearSendCrypto.text(access.account) + (try SuiSendCrypto.unbase58(hash)) + NearSendCrypto.le(UInt32(actions.count))+actions.reduce(Data(),+)
        let request = try WalletConnectNearRequest(method:"near_signTransaction",chain:network.walletConnectChain,account:access.account,params:JSONEncoder().encode(NearJSON.object(["transaction":WalletConnectNearRequest.buffer(raw)])))
        let review = try await walletConnectReview(request,publicKey:publicKey)
        try access.validate(review); return review
    }
    func walletConnectAccessSubmit(_ signed:NearSignedSend,review:WalletConnectNearReview) async throws -> NearSendReceipt.Outcome {
        guard review.request.network == network else { throw NearSendError.wrongNetwork }
        try WalletConnectNearAccess.verify(signed,review:review)
        var result = try await rpc("tx",.object(["tx_hash":.string(signed.hash),"sender_account_id":.string(review.request.account),"wait_until":.string("NONE")]),unknownAllowed:true)
        if result.isNull {
            let tx = try WalletConnectNearTransaction(review.request.transactions[0])
            async let currentWork = finalBlock()
            async let originWork = rpc("block",.object(["block_id":.string(tx.blockHash)]))
            async let configWork = rpc("EXPERIMENTAL_protocol_config",.object(["finality":.string("final")]))
            let (current,origin,config) = try await (currentWork,originWork,configWork)
            let now = try NearIdentity.height(current["height"]), start = try NearIdentity.height(origin["header"]["height"])
            guard let validity = config["transaction_validity_period"].integer, now >= start else { throw NearSendError.malformed }
            if UInt64(now-start) >= validity { return .expired }
            result = try await rpc("send_tx",.object(["signed_tx_base64":.string(signed.bytes.base64EncodedString()),"wait_until":.string("INCLUDED")]),unknownAllowed:true)
        }
        if result.isNull { return .unknown }
        if let hash = result["transaction"]["hash"].string, hash != signed.hash { throw NearSendError.changed }
        guard let status = result["final_execution_status"].string else { throw NearSendError.malformed }
        if ["NONE","INCLUDED","EXECUTED_OPTIMISTIC","INCLUDED_FINAL","EXECUTED"].contains(status) { return .accepted }
        guard status == "FINAL", result["transaction"]["hash"].string == signed.hash else { throw NearSendError.malformed }
        if !result["status"]["Failure"].isNull { return .failed }
        if !result["status"]["SuccessValue"].isNull { return .confirmed }
        throw NearSendError.malformed
    }
}
