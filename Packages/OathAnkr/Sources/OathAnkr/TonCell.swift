import Foundation
import CryptoKit

/// Level-zero ordinary/library-reference cells. Jetton deployment traces may
/// contain library code references. Pruned/Merkle cells remain unsupported;
/// sizes, references, padding and BOC CRCs are validated before hashing.
struct TonCell: Sendable, Equatable {
    let bits: [UInt8]
    let refs: [TonCell]
    let library: Bool
    let depth: Int
    let hash: Data
    init(_ bits: [UInt8] = [], _ refs: [TonCell] = [], library:Bool=false) throws {
        guard bits.count <= 1023, refs.count <= 4, bits.allSatisfy({$0 < 2}), refs.allSatisfy({$0.depth < 128}) else { throw TonSendError.malformed }
        guard !library || (bits.count==264 && refs.isEmpty && bits.prefix(8).reduce(0,{($0<<1)|$1})==2) else { throw TonSendError.malformed }
        self.bits = bits; self.refs = refs; self.library=library
        depth = (refs.map(\.depth).max().map { $0 + 1 }) ?? 0
        var paddedBits=bits
        if paddedBits.count % 8 != 0 { paddedBits.append(1); while paddedBits.count % 8 != 0 { paddedBits.append(0) } }
        var data=Data([UInt8(refs.count)+(library ? 8:0),UInt8(bits.count/8+(bits.count+7)/8)])
        data += Data(stride(from:0,to:paddedBits.count,by:8).map { paddedBits[$0..<$0+8].reduce(0){($0<<1)|$1} })
        for ref in refs { data += Self.uint(UInt64(ref.depth),2) }
        for ref in refs { data += ref.hash }
        hash=Data(SHA256.hash(data:data))
    }
    var padded: Data {
        var b=bits
        if b.count % 8 != 0 { b.append(1); while b.count % 8 != 0 { b.append(0) } }
        return Data(stride(from:0,to:b.count,by:8).map { b[$0..<$0+8].reduce(0) { ($0 << 1) | $1 } })
    }
    var descriptors: Data { Data([UInt8(refs.count)+(library ? 8:0), UInt8(bits.count / 8 + (bits.count + 7) / 8)]) }
    static func uint(_ n:UInt64,_ size:Int) -> Data { Data((0..<size).reversed().map { UInt8(truncatingIfNeeded:n >> ($0*8)) }) }
    func boc() throws -> Data {
        // Postorder with identity deduplication, reversed so every reference points forward.
        var cells=[TonCell](), seen=Set<Data>()
        func visit(_ cell:TonCell) throws {
            guard cells.count < 4096 else { throw TonSendError.malformed }
            if !seen.insert(cell.hash).inserted { return }
            for ref in cell.refs { try visit(ref) }; cells.append(cell)
        }
        try visit(self);cells.reverse()
        let indices=Dictionary(uniqueKeysWithValues:cells.enumerated().map { ($0.element.hash,$0.offset) })
        let size=cells.count < 256 ? 1 : 2
        var body=Data()
        for cell in cells {
            body += cell.descriptors+cell.padded
            for ref in cell.refs { body += Self.uint(UInt64(indices[ref.hash]!),size) }
        }
        let offset=body.count < 256 ? 1 : body.count < 65536 ? 2 : 3
        return Data([0xb5,0xee,0x9c,0x72,UInt8(size),UInt8(offset)])+Self.uint(UInt64(cells.count),size)+Self.uint(1,size)+Self.uint(0,size)+Self.uint(UInt64(body.count),offset)+Self.uint(0,size)+body
    }
    static func parse(_ data:Data) throws -> TonCell {
        guard data.count <= 1_048_576, data.count >= 11 else { throw TonSendError.malformed }
        let b=Array(data);var p=0
        func read(_ n:Int) throws -> UInt64 {
            guard (0...8).contains(n),p+n<=b.count else { throw TonSendError.malformed }
            defer {p+=n};return b[p..<p+n].reduce(0){($0<<8)|UInt64($1)}
        }
        guard try read(4)==0xb5ee9c72 else { throw TonSendError.malformed }
        let flags=try read(1),size=Int(flags&7),offset=Int(try read(1))
        guard flags&0x38==0,(1...4).contains(size),(1...4).contains(offset) else { throw TonSendError.malformed }
        let count=Int(try read(size)),roots=try read(size),absent=try read(size),total=Int(try read(offset)),root=Int(try read(size))
        guard (1...4096).contains(count),roots==1,absent==0,root<count else { throw TonSendError.malformed }
        if flags&0x80 != 0 { for _ in 0..<count { _ = try read(offset) } }
        let end=p+total,crc=flags&0x40 != 0
        guard end+(crc ? 4:0)==b.count else { throw TonSendError.malformed }
        if crc {
            var c:UInt32=0xffffffff
            for byte in b[..<end] { c ^= UInt32(byte);for _ in 0..<8 { c = (c>>1) ^ (c&1==1 ? 0x82f63b78:0) } };c = ~c
            guard Array(b[end...])==(0..<4).map({UInt8(truncatingIfNeeded:c>>($0*8))}) else { throw TonSendError.malformed }
        }
        var raw=[([UInt8],[Int],Bool)]();raw.reserveCapacity(count)
        for i in 0..<count {
            let d1=Int(try read(1)),d2=Int(try read(1)),bytes=(d2+1)/2
            guard (d1<=4 || d1==8),p+bytes<=end else { throw TonSendError.malformed }
            var bits=b[p..<p+bytes].flatMap { byte in (0..<8).reversed().map{(byte>>$0)&1} };p+=bytes
            if d2&1==1 { guard let marker=bits.lastIndex(of:1),bits.count-marker<=8 else { throw TonSendError.malformed };bits=Array(bits[..<marker]) }
            var refs=[Int]()
            for _ in 0..<(d1&7) { let r=Int(try read(size));guard r>i,r<count else { throw TonSendError.malformed };refs.append(r) }
            raw.append((bits,refs,d1==8))
        }
        guard p==end else { throw TonSendError.malformed }
        var decoded=[Int:TonCell]()
        for i in (0..<count).reversed() { decoded[i]=try TonCell(raw[i].0,raw[i].1.map{decoded[$0]!},library:raw[i].2) }
        return decoded[root]!
    }
}
struct TonBuilder {
    var bits=[UInt8](),refs=[TonCell]()
    mutating func uint(_ n:UInt64,_ width:Int) throws {
        guard (0...64).contains(width),width==64 || n < (UInt64(1)<<width),bits.count+width<=1023 else { throw TonSendError.malformed }
        for shift in (0..<width).reversed() { bits.append(UInt8((n>>shift)&1)) }
    }
    mutating func bytes(_ data:Data) throws { for byte in data { try uint(UInt64(byte),8) } }
    mutating func jettonCoins(_ amount:TonAmount) throws {
        let bytes=amount.significantBytes;try uint(UInt64(bytes.count),4);try self.bytes(Data(bytes))
    }
    mutating func coins(_ n:UInt64) throws { let size=n==0 ? 0:(64-n.leadingZeroBitCount+7)/8;try uint(UInt64(size),4);if size>0 { try uint(n,size*8) } }
    mutating func address(_ value:String) throws {
        let parts=try TonIdentity.raw(value).split(separator:":")
        try uint(4,3);try uint(UInt64(UInt8(bitPattern:Int8(parts[0])!)),8);try bytes(TronIdentity.hex(String(parts[1])))
    }
    mutating func ref(_ value:TonCell) throws { guard refs.count<4 else { throw TonSendError.malformed };refs.append(value) }
    mutating func inline(_ cell:TonCell) throws { guard bits.count+cell.bits.count<=1023,refs.count+cell.refs.count<=4 else { throw TonSendError.malformed };bits+=cell.bits;refs+=cell.refs }
    func cell() throws -> TonCell { try TonCell(bits,refs) }
}
