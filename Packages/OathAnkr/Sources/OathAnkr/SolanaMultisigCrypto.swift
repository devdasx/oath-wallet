import Foundation
import CryptoKit

/// Locally built legacy messages. No provider-supplied instructions are signed.
public enum SolanaMultisigCrypto {
    /// Solana exports contain a 32-byte seed followed by its Ed25519 public key.
    /// Accept Base58 or the CLI JSON array; reject mismatched public halves.
    public static func importSigner(_ input: String) throws -> Data {
        guard input.utf8.count <= 2048 else { throw SolanaSendError.signing }
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        var pair: Data
        if text.hasPrefix("[") { pair = Data(try JSONDecoder().decode([UInt8].self,from:Data(text.utf8))) }
        else { pair = try SolanaSendCrypto.decode(text) }
        defer { pair.resetBytes(in:0..<pair.count) }
        guard pair.count == 64, try SolanaSendCrypto.publicKey(privateKey:Data(pair.prefix(32))) == Data(pair.suffix(32)) else { throw SolanaSendError.signing }
        return Data(pair.prefix(32))
    }

    /// SLIP-0010 Ed25519, m/44'/501'/0'/0'. Input is a validated BIP39 seed.
    public static func deriveSigner(seed: Data) throws -> Data {
        guard seed.count == 64 else { throw SolanaSendError.signing }
        var digest = Data(HMAC<SHA512>.authenticationCode(for:seed,using:SymmetricKey(data:Data("ed25519 seed".utf8))))
        defer { digest.resetBytes(in:0..<digest.count) }
        for index: UInt32 in [44,501,0,0] {
            let hardened = index | 0x80000000
            let path = Data([UInt8(hardened >> 24), UInt8((hardened >> 16) & 255), UInt8((hardened >> 8) & 255), UInt8(hardened & 255)])
            digest = Data(HMAC<SHA512>.authenticationCode(for:Data([0])+digest.prefix(32)+path,using:SymmetricKey(data:digest.suffix(32))))
        }
        return Data(digest.prefix(32))
    }

    struct Meta: Equatable { let key: String; var signer: Bool; var writable: Bool
        init(_ key: String, _ signer: Bool = false, _ writable: Bool = false) { self.key = key; self.signer = signer; self.writable = writable }
    }
    struct Instruction { let program: String; let keys: [Meta]; let data: Data }
    struct Compiled { let keys: [Meta]; let instructions: [Instruction]
        var signerCount: Int { keys.filter(\.signer).count }
        var header: Data { Data([UInt8(signerCount), UInt8(keys.filter { $0.signer && !$0.writable }.count), UInt8(keys.filter { !$0.signer && !$0.writable }.count)]) }
        func encodedInstructions(compact: Bool) throws -> Data {
            var result = compact ? Data([UInt8(instructions.count)]) : SolanaSendCrypto.short(instructions.count)
            for ix in instructions {
                guard let program = keys.firstIndex(where: { $0.key == ix.program }), ix.keys.count < 256, ix.data.count < 65536 else { throw SolanaSendError.malformed }
                result.append(UInt8(program))
                result += compact ? Data([UInt8(ix.keys.count)]) : SolanaSendCrypto.short(ix.keys.count)
                for meta in ix.keys { guard let i = keys.firstIndex(where: { $0.key == meta.key }) else { throw SolanaSendError.malformed }; result.append(UInt8(i)) }
                result += compact ? SolanaSendCrypto.le(UInt16(ix.data.count)) : SolanaSendCrypto.short(ix.data.count)
                result += ix.data
            }
            return result
        }
        func message(_ blockhash: String) throws -> Data {
            var bytes = header + SolanaSendCrypto.short(keys.count)
            for key in keys { bytes += try SolanaSendCrypto.decode(key.key) }
            bytes += try SolanaSendCrypto.decode(blockhash); bytes += try encodedInstructions(compact: false)
            guard bytes.count + 1 + signerCount * 64 <= 1232 else { throw SolanaSendError.amount }
            return bytes
        }
        func wrapped() throws -> Data {
            var bytes = Data([UInt8(signerCount), UInt8(keys.filter { $0.signer && $0.writable }.count), UInt8(keys.filter { !$0.signer && $0.writable }.count), UInt8(keys.count)])
            for key in keys { bytes += try SolanaSendCrypto.decode(key.key) }
            bytes += try encodedInstructions(compact: true); bytes.append(0); return bytes
        }
    }
    static func compile(payer: String, instructions: [Instruction]) throws -> Compiled {
        guard !instructions.isEmpty, instructions.count < 64, SolanaIdentity.isAddress(payer) else { throw SolanaSendError.malformed }
        var entries = [Meta(payer, true, true)]
        func merge(_ m: Meta) throws {
            guard SolanaIdentity.isAddress(m.key) else { throw SolanaSendError.malformed }
            if let i = entries.firstIndex(where: { $0.key == m.key }) { entries[i].signer = entries[i].signer || m.signer; entries[i].writable = entries[i].writable || m.writable }
            else { entries.append(m) }
        }
        for ix in instructions { try merge(.init(ix.program)); for key in ix.keys { try merge(key) } }
        let keys = entries.filter { $0.signer && $0.writable } + entries.filter { $0.signer && !$0.writable } + entries.filter { !$0.signer && $0.writable } + entries.filter { !$0.signer && !$0.writable }
        guard keys.count < 256 else { throw SolanaSendError.malformed }
        return .init(keys: keys, instructions: instructions)
    }
    static func instruction(_ name: String, _ keys: [Meta], _ body: Data = Data()) -> Instruction {
        .init(program: SolanaMultisigPolicy.program, keys: keys, data: Data(SHA256.hash(data: Data("global:\(name)".utf8)).prefix(8)) + body)
    }
    static func setup(_ c: SolanaMultisigContext) throws -> Compiled {
        let p = c.policy; try p.validate()
        guard let treasury = c.setupTreasury, SolanaIdentity.isAddress(treasury), c.index == 0 else { throw SolanaSendError.changed }
        var body = Data([0]) + SolanaSendCrypto.le(UInt16(p.required)) + SolanaSendCrypto.le(UInt32(p.members.count))
        for key in p.members { body += try SolanaSendCrypto.decode(key); body.append(7) }
        body += SolanaSendCrypto.le(UInt32(0)); body += Data([0,0])
        return try compile(payer: c.payer, instructions: [instruction("multisig_create_v2", [Meta(SolanaMultisigPolicy.programConfig),Meta(treasury,false,true),Meta(p.multisig,false,true),Meta(p.createKey,true),Meta(c.payer,true,true),Meta(SolanaSendCrypto.system)], body)])
    }
    static func inner(_ p: SolanaSendPlan) throws -> Compiled {
        var instructions = [Instruction]()
        func memo() { if !p.memo.isEmpty { instructions.append(.init(program: SolanaSendCrypto.memoProgram, keys: [.init(p.sender,true)], data: Data(p.memo.utf8))) } }
        if p.reference == "native" {
            memo(); instructions.append(.init(program: SolanaSendCrypto.system, keys: [.init(p.sender,true,true),.init(p.recipient,false,true)],data: SolanaSendCrypto.le(UInt32(2)) + SolanaSendCrypto.le(p.amount)))
        } else {
            let ata = try SolanaSendCrypto.associatedAddress(owner: p.recipient, mint: p.reference, program: p.program)
            instructions.append(.init(program: SolanaSendCrypto.associated, keys: [.init(p.sender,true,true),.init(ata,false,true),.init(p.recipient),.init(p.reference),.init(SolanaSendCrypto.system),.init(p.program)], data: Data([1])))
            for (i,source) in p.sources.enumerated() {
                memo()
                let data = p.tokenFees.isEmpty ? Data([12]) + SolanaSendCrypto.le(source.amount) + Data([UInt8(p.decimals)]) : Data([26,1]) + SolanaSendCrypto.le(source.amount) + Data([UInt8(p.decimals)]) + SolanaSendCrypto.le(p.tokenFees[i])
                instructions.append(.init(program:p.program,keys:[.init(source.address,false,true),.init(p.reference),.init(ata,false,true),.init(p.sender,true)],data:data))
            }
        }
        let references = p.paymentReferences ?? []
        let compiled = try compile(payer: p.sender, instructions: instructions)
        // References must never gain signer/writable privileges through another
        // instruction in the same message.
        guard !references.contains(p.sender), instructions.flatMap(\.keys).filter({ $0.signer || $0.writable }).allSatisfy({ !references.contains($0.key) }) else { throw SolanaSendError.malformed }
        guard !references.isEmpty else { return compiled }
        instructions = instructions.map { ix in
            guard ix.program == SolanaSendCrypto.system || ix.program == p.program else { return ix }
            return Instruction(program: ix.program, keys: ix.keys + references.map { Meta($0) }, data: ix.data)
        }
        return try compile(payer: p.sender, instructions: instructions)
    }
    static func stages(_ p: SolanaSendPlan) throws -> [Compiled] {
        guard let c = p.multisig else { throw SolanaSendError.changed }
        if c.setupTreasury != nil { return [try setup(c)] }
        let policy = c.policy, m = try policy.multisig, t = try policy.transaction(c.index), proposal = try policy.proposal(c.index), payer = c.payer
        let inner = try inner(p), wrapped = try inner.wrapped()
        let create = instruction("vault_transaction_create", [.init(m,false,true),.init(t,false,true),.init(payer,true),.init(payer,true,true),.init(SolanaSendCrypto.system)], Data([0,0]) + SolanaSendCrypto.le(UInt32(wrapped.count)) + wrapped + Data([0]))
        let propose = instruction("proposal_create", [.init(m),.init(proposal,false,true),.init(payer,true),.init(payer,true,true),.init(SolanaSendCrypto.system)], SolanaSendCrypto.le(c.index) + Data([0]))
        var approvals = c.signingMembers.map { instruction("proposal_approve", [.init(m),.init($0,true,true),.init(proposal,false,true)],Data([0])) }
        approvals.append(instruction("vault_transaction_execute", [.init(m),.init(proposal,false,true),.init(t),.init(payer,true)] + inner.keys.map { .init($0.key,false,$0.writable) }))
        return try [compile(payer:payer,instructions:[create,propose]), compile(payer:payer,instructions:approvals)]
    }
    public static func messages(_ p: SolanaSendPlan) throws -> [Data] { try p.validate(checkAge:false); return try stages(p).map { try $0.message(p.blockhash) } }
    public static func sign(_ p: SolanaSendPlan, privateKeys: [Data]) throws -> SolanaSignedSend {
        try p.validate()
        let compiled = try stages(p)
        var keys = [String: Curve25519.Signing.PrivateKey]()
        for raw in privateKeys {
            let key = try Curve25519.Signing.PrivateKey(rawRepresentation:raw), address = SolanaSendCrypto.encode(key.publicKey.rawRepresentation)
            guard keys.updateValue(key,forKey:address) == nil else { throw SolanaSendError.signing }
        }
        let needed = Set(compiled.flatMap { $0.keys.filter(\.signer).map(\.key) })
        guard Set(keys.keys) == needed else { throw SolanaSendError.wrongOwner }
        let stages = try compiled.map { stage -> SolanaSignedStage in
            let message = try stage.message(p.blockhash)
            let signatures = try stage.keys.filter(\.signer).map { try keys[$0.key]!.signature(for:message) }
            return .init(bytes:SolanaSendCrypto.short(signatures.count) + signatures.reduce(Data(),+) + message, hash:SolanaSendCrypto.encode(signatures[0]))
        }
        let last = stages.last!, firstKey = try SolanaSendCrypto.decode(compiled.last!.keys[0].key)
        let signed = SolanaSignedSend(bytes:last.bytes, publicKey:firstKey, signature:try SolanaSendCrypto.decode(last.hash), hash:last.hash, preparations:stages.count > 1 ? Array(stages.dropLast()) : nil)
        try verify(signed,plan:p); return signed
    }
    public static func verify(_ signed: SolanaSignedSend, plan: SolanaSendPlan) throws {
        try plan.validate(checkAge:false)
        let compiled = try stages(plan), supplied = (signed.preparations ?? []) + [.init(bytes:signed.bytes,hash:signed.hash)]
        guard compiled.count == supplied.count, signed.publicKey == (try SolanaSendCrypto.decode(compiled.last!.keys[0].key)), signed.signature == (try SolanaSendCrypto.decode(signed.hash)) else { throw SolanaSendError.signing }
        for (stage, tx) in zip(compiled,supplied) {
            let message = try stage.message(plan.blockhash), count = stage.signerCount
            guard tx.bytes.count == 1 + count * 64 + message.count, tx.bytes.first == UInt8(count), tx.bytes.suffix(message.count) == message,
                  tx.hash == SolanaSendCrypto.encode(Data(tx.bytes[1..<65])) else { throw SolanaSendError.signing }
            for (i,key) in stage.keys.filter(\.signer).enumerated() {
                guard try Curve25519.Signing.PublicKey(rawRepresentation:SolanaSendCrypto.decode(key.key)).isValidSignature(tx.bytes[(1+i*64)..<(65+i*64)],for:message) else { throw SolanaSendError.signing }
            }
        }
    }
}
public struct SolanaSignedStage: Codable, Equatable, Sendable {
    public let bytes: Data, hash: String
    public init(bytes: Data, hash: String) { self.bytes = bytes; self.hash = hash }
}
