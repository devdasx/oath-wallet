import Foundation
import CryptoKit

extension TonSendNetwork {
    public init?(walletConnectChain: String) {
        switch walletConnectChain { case "ton:-239": self = .mainnet; case "ton:-3": self = .testnet; default: return nil }
    }
    public var walletConnectChain: String { self == .mainnet ? "ton:-239" : "ton:-3" }
    public var walletConnectName: String { self == .mainnet ? "TON" : "TON Testnet" }
    public func walletConnectAddress(_ raw: String) throws -> String {
        guard var bytes = TonIdentity.base64(try TonIdentity.friendly(address(raw), bounceable: false)) else { throw TonSendError.malformed }
        if self == .testnet { bytes[0] |= 0x80; bytes = Data(bytes.prefix(34)); bytes += TonIdentity.crc16(bytes) }
        return bytes.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
    }
}

public struct WalletConnectTonRequest: Codable, Sendable, Equatable {
    public static let methods: Set<String> = ["ton_sendMessage", "ton_signData"]
    public static let blockchains: Set<String> = ["ton:-239", "ton:-3"]
    public struct Message: Codable, Sendable, Equatable {
        public let address: String, amount: UInt64, bounce: Bool
        public let payload: Data?, stateInit: Data?
    }
    public let network: TonSendNetwork, account: String, method: String, domain: String
    public let params: TonJSON
    public let expiration: UInt32?
    public let messages: [Message]
    public var broadcasts: Bool { method == "ton_sendMessage" }
    public var fingerprint: String {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return TronSendCrypto.hex(Data(SHA256.hash(data: (try? encoder.encode(self)) ?? Data())))
    }
    public var amount: UInt64 { messages.reduce(0) { $0 + $1.amount } }
    public init(method: String, chain: String, account: String, domain: String, params: Data, now: Date = .now) throws {
        guard Self.methods.contains(method), let network = TonSendNetwork(walletConnectChain: chain),
              !domain.isEmpty, domain.utf8.count <= 253, domain == domain.lowercased(),
              domain.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 46 }) else { throw TonSendError.wrongNetwork }
        let json = try WalletConnectJSON.decode(params)
        guard case .object(let fields) = json else { throw TonSendError.malformed }
        self.network = network; self.account = try network.address(account); self.method = method; self.domain = domain; self.params = json
        if let from = fields["from"] { guard let text = from.string, try network.address(text) == self.account else { throw TonSendError.wrongOwner } }
        if let chain = fields["network"] { guard chain.string == network.walletConnectChain.split(separator: ":").last.map(String.init) else { throw TonSendError.wrongNetwork } }
        if method == "ton_sendMessage" {
            guard Set(fields.keys).isSubset(of: ["from", "network", "valid_until", "validUntil", "messages"]),
                  fields["valid_until"] == nil || fields["validUntil"] == nil,
                  let values = fields["messages"]?.array, (1...4).contains(values.count) else { throw TonSendError.malformed }
            if let supplied = fields["valid_until"] ?? fields["validUntil"] {
                guard let expiration = supplied.text.flatMap(UInt32.init) else { throw TonSendError.malformed }
                self.expiration = expiration
            } else { self.expiration = nil }
            var total: UInt64 = 0
            self.messages = try values.map { value in
                guard case .object(let fields) = value, Set(fields.keys).isSubset(of: ["address", "amount", "payload", "stateInit"]),
                      let address = fields["address"]?.string, let text = fields["amount"]?.string,
                      !text.isEmpty, text.utf8.allSatisfy({ (48...57).contains($0) }), let amount = UInt64(text) else { throw TonSendError.malformed }
                let addition = total.addingReportingOverflow(amount); guard !addition.overflow else { throw TonSendError.amount }; total = addition.partialValue
                func cell(_ key: String) throws -> Data? {
                    guard let supplied = fields[key] else { return nil }
                    guard let text = supplied.string, text.utf8.count <= 32_768, let bytes = TonIdentity.base64(text) else { throw TonSendError.malformed }
                    _ = try TonCell.parse(bytes); return bytes
                }
                let raw = try network.address(address), stateInit = try cell("stateInit")
                if let stateInit { guard raw.split(separator: ":").last == Substring(TronSendCrypto.hex(try TonCell.parse(stateInit).hash)) else { throw TonSendError.changed } }
                let bounce = address.contains(":") || TonIdentity.base64(address).map { $0[0] & 0x7f == 0x11 } == true
                return .init(address: raw, amount: amount, bounce: bounce, payload: try cell("payload"), stateInit: stateInit)
            }
        } else {
            expiration = nil; messages = []
            let type = fields["type"]?.string
            let allowed: Set<String> = type == "text" ? ["type", "text", "from", "network"] : type == "binary" ? ["type", "bytes", "from", "network"] : ["type", "schema", "cell", "from", "network"]
            guard Set(fields.keys).isSubset(of: allowed) else { throw TonSendError.malformed }
            switch type {
            case "text": guard let text = fields["text"]?.string, text.utf8.count <= 16_384 else { throw TonSendError.malformed }
            case "binary": guard let text = fields["bytes"]?.string, let bytes = TonIdentity.base64(text), bytes.count <= 16_384 else { throw TonSendError.malformed }
            case "cell":
                guard let schema = fields["schema"]?.string, !schema.isEmpty, schema.utf8.count <= 4_096,
                      let text = fields["cell"]?.string, let bytes = TonIdentity.base64(text), bytes.count <= 16_384 else { throw TonSendError.malformed }
                _ = try TonCell.parse(bytes)
            default: throw TonSendError.malformed
            }
        }
        try validateTime(now)
    }
    public func validateTime(_ now: Date = .now) throws {
        if let expiration { guard Double(expiration) > now.timeIntervalSince1970 + 5 else { throw TonSendError.expired } }
    }
}

public struct WalletConnectTonPlan: Codable, Sendable, Equatable {
    public let request: WalletConnectTonRequest, publicKey: Data
    public let sequence: UInt32, expiration: UInt32, deploy: Bool
    public let fee: UInt64, feeReserve: UInt64
    public let createdAt: Date
    public init(request: WalletConnectTonRequest, publicKey: Data, sequence: UInt32, expiration: UInt32, deploy: Bool, fee: UInt64, feeReserve: UInt64, createdAt: Date = .now) {
        self.request=request; self.publicKey=publicKey; self.sequence=sequence; self.expiration=expiration; self.deploy=deploy; self.fee=fee; self.feeReserve=feeReserve; self.createdAt=createdAt
    }
    public func validate(now: Date = .now, checkAge: Bool = true) throws {
        // Decode again to validate persisted plans at the signing/recovery boundary.
        let rebuilt = try WalletConnectTonRequest(method: request.method, chain: request.network.walletConnectChain, account: request.account, domain: request.domain, params: JSONEncoder().encode(request.params), now: checkAge ? now : createdAt)
        guard rebuilt == request, request.broadcasts, sequence < UInt32.max, !deploy || sequence == 0,
              try TonSendCrypto.address(publicKey: publicKey) == request.account,
              expiration <= (request.expiration ?? UInt32.max), createdAt.timeIntervalSince1970.isFinite,
              Double(expiration) > createdAt.timeIntervalSince1970 + 5, Double(expiration) <= createdAt.timeIntervalSince1970 + 600,
              fee > 0, feeReserve > 0, feeReserve <= 500_000_000 else { throw TonSendError.malformed }
        if checkAge { guard (-5...90).contains(now.timeIntervalSince(createdAt)), Double(expiration) > now.timeIntervalSince1970 + 5 else { throw TonSendError.expired } }
    }
}

public enum WalletConnectTonCrypto {
    public static func stateInit(publicKey: Data) throws -> String { try TonSendCrypto.stateInit(publicKey).boc().base64EncodedString() }
    static func internalMessage(_ m: WalletConnectTonRequest.Message) throws -> TonCell {
        var b=TonBuilder(); try b.uint(m.bounce ? 0x18:0x10,6); try b.address(m.address); try b.coins(m.amount)
        try b.uint(0,1); try b.coins(0); try b.coins(0); try b.uint(0,64); try b.uint(0,32)
        if let initData=m.stateInit { try b.uint(3,2); try b.ref(TonCell.parse(initData)) } else { try b.uint(0,1) }
        let body = try m.payload.map(TonCell.parse) ?? TonCell()
        if b.bits.count + 1 + body.bits.count <= 1023 && b.refs.count + body.refs.count <= 4 {
            try b.uint(0,1); try b.inline(body)
        } else { try b.uint(1,1); try b.ref(body) }
        return try b.cell()
    }
    static func signingCell(_ p: WalletConnectTonPlan) throws -> TonCell {
        var b=TonBuilder(); try b.uint(TonSendPlan.walletID,32); try b.uint(UInt64(p.expiration),32); try b.uint(UInt64(p.sequence),32); try b.uint(0,8)
        for m in p.request.messages { try b.uint(3,8); try b.ref(internalMessage(m)) }; return try b.cell()
    }
    static func body(_ p: WalletConnectTonPlan, signature: Data) throws -> TonCell {
        guard signature.count == 64 else { throw TonSendError.signing }
        var b=TonBuilder(); try b.bytes(signature); try b.inline(signingCell(p)); return try b.cell()
    }
    static func external(_ p: WalletConnectTonPlan, body: TonCell, normalized: Bool = false) throws -> TonCell {
        var b=TonBuilder(); try b.uint(2,2); try b.uint(0,2); try b.address(p.request.account); try b.coins(0)
        if p.deploy && !normalized { try b.uint(3,2); try b.ref(TonSendCrypto.stateInit(p.publicKey)) } else { try b.uint(0,1) }
        try b.uint(1,1); try b.ref(body); return try b.cell()
    }
    public static func unsigned(_ p: WalletConnectTonPlan) throws -> Data { try external(p, body: body(p,signature: Data(repeating:0,count:64))).boc() }
    public static func sign(_ p: WalletConnectTonPlan, privateKey: Data, now: Date = .now) throws -> TonSignedSend {
        try p.validate(now:now); let key=try Curve25519.Signing.PrivateKey(rawRepresentation:privateKey)
        guard key.publicKey.rawRepresentation == p.publicKey else { throw TonSendError.wrongOwner }
        let signature=try key.signature(for:signingCell(p).hash), body=try body(p,signature:signature)
        return .init(bytes:try external(p,body:body).boc(),signature:signature,hash:TronSendCrypto.hex(try external(p,body:body,normalized:true).hash),bodyHash:TronSendCrypto.hex(body.hash))
    }
    public static func verify(_ signed: TonSignedSend, plan: WalletConnectTonPlan) throws {
        try plan.validate(checkAge:false)
        guard try Curve25519.Signing.PublicKey(rawRepresentation:plan.publicKey).isValidSignature(signed.signature,for:signingCell(plan).hash) else { throw TonSendError.signing }
        let body=try body(plan,signature:signed.signature)
        guard signed.bytes == (try external(plan,body:body).boc()), signed.hash == (try TronSendCrypto.hex(external(plan,body:body,normalized:true).hash)), signed.bodyHash == TronSendCrypto.hex(body.hash) else { throw TonSendError.signing }
    }
    public static func signData(_ r: WalletConnectTonRequest, privateKey: Data, timestamp: UInt64) throws -> TonJSON {
        let rebuilt = try WalletConnectTonRequest(method: r.method, chain: r.network.walletConnectChain, account: r.account, domain: r.domain, params: JSONEncoder().encode(r.params))
        guard rebuilt == r, !r.broadcasts, try TonSendCrypto.address(publicKey:TonSendCrypto.publicKey(privateKey:privateKey)) == r.account else { throw TonSendError.wrongOwner }
        let digest = try signDataDigest(r, timestamp: timestamp)
        let signature=try Curve25519.Signing.PrivateKey(rawRepresentation:privateKey).signature(for:digest)
        return .object(["signature":.string(signature.base64EncodedString()),"address":.string(r.account),"timestamp":.number(String(timestamp)),"domain":.string(r.domain),"payload":r.params])
    }
    static func signDataDigest(_ r: WalletConnectTonRequest, timestamp: UInt64) throws -> Data {
        let digest: Data
        if r.params["type"].string == "cell" {
            let schema=r.params["schema"].string!, cell=try TonCell.parse(TonIdentity.base64(r.params["cell"].string!)!)
            var crc: UInt32=0xffffffff
            for byte in schema.utf8 { crc ^= UInt32(byte); for _ in 0..<8 { crc = crc >> 1 ^ (crc & 1 == 1 ? 0xedb88320 : 0) } }; crc = ~crc
            var b=TonBuilder(); try b.uint(0x75569022,32); try b.uint(UInt64(crc),32); try b.uint(timestamp,64); try b.address(r.account)
            let dns=r.domain.split(separator:".").reversed().joined(separator:"\0")+"\0"
            func snake(_ bytes: Data) throws -> TonCell { var b=TonBuilder(); try b.bytes(Data(bytes.prefix(127))); if bytes.count>127 { try b.ref(snake(Data(bytes.dropFirst(127)))) }; return try b.cell() }
            try b.ref(snake(Data(dns.utf8))); try b.ref(cell); digest=try b.cell().hash
        } else {
            let text=r.params["type"].string == "text"
            let payload=text ? Data(r.params["text"].string!.utf8) : TonIdentity.base64(r.params["bytes"].string!)!
            let parts=r.account.split(separator:":"), wc=UInt32(bitPattern:Int32(parts[0])!)
            var data=Data([255,255])+Data("ton-connect/sign-data/".utf8)
            data += TonCell.uint(UInt64(wc),4) + (try TronIdentity.hex(String(parts[1])))
            data += TonCell.uint(UInt64(r.domain.utf8.count),4)+Data(r.domain.utf8)+TonCell.uint(timestamp,8)
            data += Data((text ? "txt":"bin").utf8)+TonCell.uint(UInt64(payload.count),4)+payload
            digest=Data(SHA256.hash(data:data))
        }
        return digest
    }
}

public struct WalletConnectTonProofRequest: Codable, Sendable, Equatable {
    public let network: TonSendNetwork, account: String, domain: String, payload: String
    public init(chain: String, account: String, domain: String, payload: String) throws {
        guard let network = TonSendNetwork(walletConnectChain: chain), !payload.isEmpty, payload.utf8.count <= 1_024,
              !domain.isEmpty, domain.utf8.count <= 253, domain == domain.lowercased(),
              domain.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 46 }) else { throw TonSendError.malformed }
        self.network = network; self.account = try network.address(account); self.domain = domain; self.payload = payload
    }
}
extension WalletConnectTonCrypto {
    public static func signProof(_ request: WalletConnectTonProofRequest, privateKey: Data, timestamp: UInt64) throws -> Data {
        let rebuilt = try WalletConnectTonProofRequest(chain:request.network.walletConnectChain, account:request.account, domain:request.domain, payload:request.payload)
        guard rebuilt == request, try TonSendCrypto.address(publicKey:TonSendCrypto.publicKey(privateKey:privateKey)) == request.account else { throw TonSendError.wrongOwner }
        return try Curve25519.Signing.PrivateKey(rawRepresentation:privateKey).signature(for: proofDigest(request, timestamp:timestamp))
    }
    static func proofDigest(_ request: WalletConnectTonProofRequest, timestamp: UInt64) throws -> Data {
        let parts=request.account.split(separator:":"), wc=UInt32(bitPattern:Int32(parts[0])!)
        var data=Data("ton-proof-item-v2/".utf8)
        data += TonCell.uint(UInt64(wc),4) + (try TronIdentity.hex(String(parts[1])))
        data += Data(TonCell.uint(UInt64(request.domain.utf8.count),4).reversed()) + Data(request.domain.utf8)
        data += Data(TonCell.uint(timestamp,8).reversed()) + Data(request.payload.utf8)
        let digest=Data(SHA256.hash(data:Data([255,255])+Data("ton-connect".utf8)+Data(SHA256.hash(data:data))))
        return digest
    }
}
