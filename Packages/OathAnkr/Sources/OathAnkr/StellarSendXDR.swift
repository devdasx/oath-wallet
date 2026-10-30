import Foundation
import CryptoKit

/// Restricted XDR encoder: one locally constructed Payment/CreateAccount or
/// SEP-41 transfer. Provider responses cannot supply operation bytes to sign.
enum StellarSendXDR {
    static func u32(_ n: UInt32) -> Data { Data(StellarIdentity.u32(n)) }
    static func u64(_ n: UInt64) -> Data { u32(UInt32(n>>32))+u32(UInt32(truncatingIfNeeded:n)) }
    static func opaque(_ bytes: Data) -> Data { u32(UInt32(bytes.count))+bytes+Data(repeating:0,count:(4-bytes.count%4)%4) }
    static func account(_ address: String) throws -> Data { try u32(0)+Data(StellarIdentity.bytes(address,version:48)) }
    static func asset(code: String?, issuer: String?) throws -> Data {
        guard let code, let issuer else { guard code == nil, issuer == nil else { throw StellarSendError.malformed };return u32(0) }
        guard (1...12).contains(code.utf8.count), code.utf8.allSatisfy({(48...57).contains($0)||(65...90).contains($0)||(97...122).contains($0)}) else { throw StellarSendError.malformed }
        let size = code.utf8.count <= 4 ? 4:12
        return try u32(size == 4 ? 1:2)+Data(code.utf8)+Data(repeating:0,count:size-code.utf8.count)+account(issuer)
    }
    static func scAddress(_ owner: String) throws -> Data { try u32(18)+u32(0)+account(owner) }
    static func scAmount(_ amount: String) throws -> Data {
        _ = try StellarIdentity.uint(amount)
        var bytes = [UInt8](repeating:0,count:16)
        for digit in amount.utf8 {
            var carry = Int(digit-48)
            for i in bytes.indices.reversed() { carry += Int(bytes[i])*10;bytes[i]=UInt8(carry & 255);carry >>= 8 }
            guard carry == 0 else { throw StellarSendError.amount }
        }
        guard bytes[0] & 128 == 0 else { throw StellarSendError.amount }
        return u32(10)+Data(bytes)
    }
    static func invocation(reference: String, function: String, args: [Data]) throws -> Data {
        try u32(1)+Data(StellarIdentity.bytes(reference,version:16))+opaque(Data(function.utf8))+u32(UInt32(args.count))+args.reduce(Data(),+)
    }
    static func transfer(reference: String, sender: String, recipient: String, amount: String) throws -> Data {
        try invocation(reference:reference,function:"transfer",args:[scAddress(sender),scAddress(recipient),scAmount(amount)])
    }
    static func sourceAuthorization(reference: String, sender: String, recipient: String, amount: String) throws -> Data {
        try u32(0)+u32(0)+transfer(reference:reference,sender:sender,recipient:recipient,amount:amount)+u32(0)
    }
    static func memo(_ memo: StellarSendMemo) throws -> Data {
        try memo.validate();if memo.value.isEmpty { return u32(0) }
        switch memo.type {
        case .text: return u32(1)+opaque(Data(memo.value.utf8))
        case .id: guard let n = UInt64(memo.value) else { throw StellarSendError.amount };return u32(2)+u64(n)
        case .hash,.returnHash: return try u32(memo.type == .hash ? 3:4)+Data(TronIdentity.hex(memo.value))
        }
    }
    static func transaction(_ plan: StellarSendPlan, readFunction: String? = nil, readArgs: [Data] = []) throws -> Data {
        try plan.validate(checkAge:false)
        var b = try account(plan.sender)+u32(plan.fee)+u64(UInt64(plan.sequence))
        // V2 time and ledger bounds, exact sequence, no extra signers.
        b += u32(2)+u32(1)+u64(0)+u64(plan.maxTime)+u32(1)+u32(plan.firstLedger)+u32(plan.lastLedger)
        b += u32(0)+u64(0)+u32(0)+u32(0)
        b += try memo(plan.memo)
        if plan.kind == .configureMultisig, let policy = plan.multisig {
            b += try configure(policy)
        } else if plan.kind == .changeTrust {
            b += u32(1) + u32(0) + u32(6)
            b += try asset(code: plan.assetCode, issuer: plan.issuer) + u64(UInt64(Int64.max))
        } else {
        b += u32(1)+u32(0)
        if plan.kind == .contract {
            let call = try readFunction.map { try invocation(reference:plan.reference,function:$0,args:readArgs) }
                ?? transfer(reference:plan.reference,sender:plan.sender,recipient:plan.recipient,amount:plan.amount)
            b += u32(24)+u32(0)+call
            b += u32(UInt32(plan.authorization.count))+plan.authorization.reduce(Data(),+)
        } else {
            guard let amount = UInt64(plan.amount), amount <= UInt64(Int64.max) else { throw StellarSendError.amount }
            b += u32(plan.kind == .createAccount ? 0:1)
            b += try account(plan.recipient)
            if plan.kind == .payment { b += try asset(code:plan.assetCode,issuer:plan.issuer) }
            b += u64(amount)
        }
        }
        if let resources = plan.sorobanData { b += u32(1)+resources } else { b += u32(0) }
        return b
    }
    static func envelope(_ transaction: Data, publicKey: Data? = nil, signature: Data? = nil) -> Data {
        guard let publicKey, let signature else { return u32(2)+transaction+u32(0) }
        return u32(2)+transaction+u32(1)+publicKey.suffix(4)+opaque(signature)
    }
    static func resourceFee(_ data: Data) throws -> UInt64 {
        var reader = Reader(data:data)
        let ext = try reader.word()
        if ext == 1 { let count = try reader.count();for _ in 0..<count { _ = try reader.word() } }
        else if ext != 0 { throw StellarSendError.malformed }
        for _ in 0..<2 { let n = try reader.count();for _ in 0..<n { try reader.ledgerKey() } }
        _ = try reader.take(12)
        let fee = try reader.long()
        guard fee <= UInt64(StellarSendPlan.maximumFee), reader.offset == data.count else { throw StellarSendError.feeTooHigh }
        return fee
    }
    struct Reader {
        let data: Data
        var offset = 0
        mutating func take(_ count: Int) throws -> Data {
            guard count >= 0, offset <= data.count, count <= data.count-offset else { throw StellarSendError.malformed }
            defer { offset += count };return data.subdata(in:offset..<offset+count)
        }
        mutating func word() throws -> UInt32 { try take(4).reduce(0){($0<<8)|UInt32($1)} }
        mutating func long() throws -> UInt64 { try take(8).reduce(0){($0<<8)|UInt64($1)} }
        mutating func count(_ maximum: UInt32 = 1024) throws -> Int { let n = try word();guard n <= maximum else { throw StellarSendError.malformed };return Int(n) }
        mutating func opaque(_ max: UInt32 = 4096) throws { let n = try count(max);_ = try take(n);let pad = try take((4-n%4)%4);guard pad.allSatisfy({$0 == 0}) else { throw StellarSendError.malformed } }
        mutating func account() throws { guard try word() == 0 else { throw StellarSendError.malformed };_ = try take(32) }
        mutating func address() throws {
            switch try word() {
            case 0: try account()
            case 1,4: _ = try take(32)
            case 2,5: _ = try take(40)
            case 3: guard try word() == 0 else { throw StellarSendError.malformed };_ = try take(32)
            default: throw StellarSendError.malformed
            }
        }
        mutating func value(depth: Int = 0) throws {
            guard depth < 16 else { throw StellarSendError.malformed }
            switch try word() {
            case 0: guard try word() <= 1 else { throw StellarSendError.malformed }
            case 1,20: break
            case 2: _ = try take(8)
            case 3,4: _ = try take(4)
            case 5...8,21: _ = try take(8)
            case 9,10: _ = try take(16)
            case 11,12: _ = try take(32)
            case 13,14: try opaque()
            case 15,22: try opaque(32)
            case 16,17:
                let typeAt = offset-4, type = data[typeAt..<typeAt+4].reduce(UInt32(0)){($0<<8)|UInt32($1)}
                let present = try word();guard present <= 1 else { throw StellarSendError.malformed }
                if present == 1 { let n = try count();for _ in 0..<(n*(type == 17 ? 2:1)) { try value(depth:depth+1) } }
            case 18: try address()
            default: throw StellarSendError.malformed
            }
        }
        mutating func ledgerKey() throws {
            switch try word() {
            case 0: try account()
            case 1:
                try account();switch try word() {
                case 1: _ = try take(4);try account()
                case 2: _ = try take(12);try account()
                case 3: _ = try take(32)
                default: throw StellarSendError.malformed
                }
            case 2: try account();_ = try take(8)
            case 3: try account();try opaque(64)
            case 4: guard try word() == 0 else { throw StellarSendError.malformed };_ = try take(32)
            case 5,7,9: _ = try take(32)
            case 6: try address();try value();guard try word() <= 1 else { throw StellarSendError.malformed }
            case 8: _ = try take(4)
            default: throw StellarSendError.malformed
            }
        }
    }
}

public enum StellarSendCrypto {
    public static func address(privateKey: Data) throws -> String {
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation:privateKey)
        return StellarIdentity.encode(Array(key.publicKey.rawRepresentation),version:48)
    }
    static func digest(_ transaction: Data, network: StellarSendNetwork) -> Data {
        Data(SHA256.hash(data:Data(SHA256.hash(data:Data(network.passphrase.utf8)))+StellarSendXDR.u32(2)+transaction))
    }
    public static func sign(_ plan: StellarSendPlan, privateKey: Data, now: Date = .now) throws -> StellarSignedSend {
        try plan.validate(now:now)
        guard plan.kind != .contract || plan.sorobanData != nil, try address(privateKey:privateKey) == plan.sender else { throw StellarSendError.signing }
        guard plan.multisig == nil || plan.kind == .configureMultisig else { throw StellarSendError.signing }
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation:privateKey), tx = try StellarSendXDR.transaction(plan)
        let digest = digest(tx,network:plan.network), signature = try key.signature(for:digest), pub = key.publicKey.rawRepresentation
        let value = StellarSignedSend(bytes:StellarSendXDR.envelope(tx,publicKey:pub,signature:signature),publicKey:pub,signature:signature,hash:hex(digest))
        try verify(value,plan:plan);return value
    }
    public static func verify(_ signed: StellarSignedSend, plan: StellarSendPlan) throws {
        try plan.validate(checkAge:false)
        if plan.multisig != nil, plan.kind != .configureMultisig { try verifyMultisig(signed, plan: plan); return }
        guard signed.signatures == nil else { throw StellarSendError.signing }
        guard signed.publicKey.count == 32, signed.signature.count == 64,
              StellarIdentity.encode(Array(signed.publicKey),version:48) == plan.sender,
              plan.kind != .contract || plan.sorobanData != nil else { throw StellarSendError.signing }
        let tx = try StellarSendXDR.transaction(plan), digest = digest(tx,network:plan.network)
        guard signed.hash == hex(digest), signed.bytes == StellarSendXDR.envelope(tx,publicKey:signed.publicKey,signature:signed.signature),
              try Curve25519.Signing.PublicKey(rawRepresentation:signed.publicKey).isValidSignature(signed.signature,for:digest) else { throw StellarSendError.signing }
    }
    static func hex(_ data: Data) -> String { data.map{String(format:"%02x",$0)}.joined() }
}
