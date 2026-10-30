import Foundation

struct PolkadotScale {
    let data: Data
    var offset = 0
    init(_ data: Data) { self.data = data }
    mutating func take(_ count: Int) throws -> Data {
        guard count >= 0, count <= data.count - offset else { throw PolkadotSendError.malformed }
        defer { offset += count }; return data.subdata(in: offset..<offset+count)
    }
    mutating func byte() throws -> UInt8 { try take(1)[0] }
    mutating func compact() throws -> String {
        let b = try byte()
        switch b & 3 {
        case 0: return String(b >> 2)
        case 1:
            let value = UInt64(b) | UInt64(try byte()) << 8
            guard value >> 2 >= 64 else { throw PolkadotSendError.malformed }; return String(value >> 2)
        case 2:
            let rest = try take(3), value = UInt64(b) | UInt64(rest[0]) << 8 | UInt64(rest[1]) << 16 | UInt64(rest[2]) << 24
            guard value >> 2 >= 16384 else { throw PolkadotSendError.malformed }; return String(value >> 2)
        default:
            let length = Int(b >> 2) + 4
            guard length <= 16 else { throw PolkadotSendError.malformed }
            let raw = try take(length), value = PolkadotIdentity.uint(raw)
            guard raw.last != 0, !XrplSendAmount.less(value, "1073741824") else { throw PolkadotSendError.malformed }; return value
        }
    }
    mutating func count(_ limit: Int = 100_000) throws -> Int {
        guard let n = Int(try compact()), n <= limit else { throw PolkadotSendError.malformed }; return n
    }
    mutating func text() throws -> String {
        let bytes = try take(count(1_000_000))
        guard let value = String(data: bytes, encoding: .utf8) else { throw PolkadotSendError.malformed }; return value
    }
    mutating func optional<T>(_ body: (inout Self) throws -> T) throws -> T? {
        switch try byte() { case 0: return nil; case 1: return try body(&self); default: throw PolkadotSendError.malformed }
    }
    mutating func docs() throws { for _ in 0..<(try count()) { _ = try text() } }
    static func le<T: FixedWidthInteger>(_ n: T) -> Data { var value = n.littleEndian; return withUnsafeBytes(of: &value) { Data($0) } }
    static func compact(_ n: String) throws -> Data {
        _ = try NearSendAmount.checked(n)
        if let v = UInt64(n) {
            if v < 64 { return Data([UInt8(v << 2)]) }
            if v < 16384 { return le(UInt16(v << 2 | 1)) }
            if v < 1 << 30 { return le(UInt32(v << 2 | 2)) }
        }
        var raw = Data(try TronSendCrypto.uint256(n).suffix(16).reversed())
        while raw.count > 4 && raw.last == 0 { raw.removeLast() }
        return Data([UInt8((raw.count-4) << 2 | 3)]) + raw
    }
}

/// Runtime metadata supplies call indices, storage layouts and signed-extension order.
/// An unfamiliar encoding fails before authentication rather than guessing a transaction.
struct PolkadotRuntime: Sendable {
    struct Field: Sendable { let name: String?; let type: Int }
    struct Variant: Sendable { let name: String; let fields: [Field]; let index: UInt8 }
    enum Definition: Sendable { case composite([Field]), variants([Variant]), sequence(Int), array(Int,Int), tuple([Int]), primitive(UInt8), compact(Int), bits(Int) }
    struct Entry: Sendable { let type: Int; let fallback: Data }
    struct Pallet: Sendable { let index: UInt8; let calls: Int?; let storage: [String: Entry]; let constants: [String: Data] }
    struct Extension: Sendable { let name: String; let type: Int; let additional: Int }
    let types: [Int: Definition], pallets: [String: Pallet], extensions: [Extension]
    let fingerprint: String
    init(_ bytes: Data) throws {
        guard bytes.count <= 8_000_000 else { throw PolkadotSendError.malformed }
        var r = PolkadotScale(bytes)
        guard try r.take(4) == Data("meta".utf8), try r.byte() == 14 else { throw PolkadotSendError.runtimeUnsupported }
        func fields(_ r: inout PolkadotScale) throws -> [Field] {
            try (0..<r.count()).map { _ in
                let name = try r.optional { try $0.text() }, type = try r.count()
                _ = try r.optional { try $0.text() }; try r.docs(); return Field(name: name, type: type)
            }
        }
        var types: [Int: Definition] = [:]
        for _ in 0..<(try r.count()) {
            let id = try r.count(); try r.docs()
            for _ in 0..<(try r.count()) { _ = try r.text(); _ = try r.optional { try $0.count() } }
            let definition: Definition
            switch try r.byte() {
            case 0: definition = .composite(try fields(&r))
            case 1:
                var values: [Variant] = []
                for _ in 0..<(try r.count(256)) { let name = try r.text(), f = try fields(&r), index = try r.byte(); try r.docs(); values.append(.init(name:name,fields:f,index:index)) }
                definition = .variants(values)
            case 2: definition = .sequence(try r.count())
            case 3:
                guard let length = Int(PolkadotIdentity.uint(try r.take(4))), length <= 100_000 else { throw PolkadotSendError.malformed }
                definition = .array(length, try r.count())
            case 4: definition = .tuple(try (0..<r.count()).map { _ in try r.count() })
            case 5: definition = .primitive(try r.byte())
            case 6: definition = .compact(try r.count())
            case 7: let store = try r.count(); _ = try r.count(); definition = .bits(store)
            default: throw PolkadotSendError.malformed
            }
            try r.docs(); guard types.updateValue(definition,forKey:id) == nil else { throw PolkadotSendError.malformed }
        }
        var pallets: [String: Pallet] = [:]
        for _ in 0..<(try r.count(256)) {
            let name = try r.text()
            let storage = try r.optional { r -> [String: Entry] in
                _ = try r.text(); var entries: [String: Entry] = [:]
                for _ in 0..<(try r.count()) {
                    let name = try r.text(); _ = try r.byte(); let type: Int
                    switch try r.byte() {
                    case 0: type = try r.count()
                    case 1: _ = try r.take(r.count(64)); _ = try r.count(); type = try r.count()
                    default: throw PolkadotSendError.malformed
                    }
                    let fallback = try r.take(r.count(1_000_000)); try r.docs(); entries[name] = .init(type:type,fallback:fallback)
                }; return entries
            } ?? [:]
            let calls = try r.optional { try $0.count() }; _ = try r.optional { try $0.count() }
            var constants: [String:Data] = [:]
            for _ in 0..<(try r.count()) { let name = try r.text(); _ = try r.count(); constants[name] = try r.take(r.count(1_000_000)); try r.docs() }
            _ = try r.optional { try $0.count() }
            pallets[name] = Pallet(index: try r.byte(), calls:calls, storage:storage, constants:constants)
        }
        _ = try r.count(); guard try r.byte() == 4 else { throw PolkadotSendError.runtimeUnsupported }
        var extensions: [Extension] = []
        for _ in 0..<(try r.count(64)) { extensions.append(.init(name:try r.text(), type:try r.count(), additional:try r.count())) }
        _ = try r.count(); guard r.offset == bytes.count else { throw PolkadotSendError.malformed }
        self.types = types; self.pallets = pallets; self.extensions = extensions; fingerprint = PolkadotIdentity.hex(SuiSendCrypto.hash(bytes))
    }
    func call(pallet name: String, name callName: String) throws -> (Data, [Field]) {
        guard let p = pallets[name], let id = p.calls, case .variants(let calls) = types[id], let call = calls.first(where: { $0.name == callName }) else { throw PolkadotSendError.runtimeUnsupported }
        return (Data([p.index,call.index]),call.fields)
    }
    func decode(_ data: Data, pallet: String, storage: String) throws -> SolanaJSON {
        guard let entry = pallets[pallet]?.storage[storage] else { throw PolkadotSendError.runtimeUnsupported }
        var reader = PolkadotScale(data.isEmpty ? entry.fallback : data), budget = 200_000
        let result = try decode(entry.type,reader:&reader,depth:0,budget:&budget)
        guard reader.offset == reader.data.count else { throw PolkadotSendError.malformed }; return result
    }
    func decode(_ id: Int, reader r: inout PolkadotScale, depth: Int, budget: inout Int) throws -> SolanaJSON {
        budget -= 1; guard depth < 64, budget >= 0, let type = types[id] else { throw PolkadotSendError.malformed }
        func value(_ id: Int) throws -> SolanaJSON { try decode(id,reader:&r,depth:depth+1,budget:&budget) }
        func fields(_ fields: [Field]) throws -> SolanaJSON {
            if fields.count == 1, fields[0].name == nil { return try value(fields[0].type) }
            if fields.allSatisfy({$0.name != nil}) {
                var object: [String:SolanaJSON] = [:]; for field in fields { object[field.name!] = try value(field.type) }; return .object(object)
            }
            return .array(try fields.map { try value($0.type) })
        }
        switch type {
        case .composite(let f): return try fields(f)
        case .tuple(let ids): return .array(try ids.map(value))
        case .variants(let variants):
            let index = try r.byte(); guard let v = variants.first(where: {$0.index == index}) else { throw PolkadotSendError.malformed }
            return .object(["type":.string(v.name),"value":try fields(v.fields)])
        case .sequence(let id): return .array(try (0..<r.count()).map { _ in try value(id) })
        case .array(let count,let id): return .array(try (0..<count).map { _ in try value(id) })
        case .compact: return .string(try r.compact())
        case .primitive(let p):
            if p == 0 { let n = try r.byte(); guard n < 2 else { throw PolkadotSendError.malformed }; return .bool(n == 1) }
            if p == 2 { return .string(try r.text()) }
            if p == 1 {
                guard let scalar = UInt32(PolkadotIdentity.uint(try r.take(4))), let unicode = UnicodeScalar(scalar) else { throw PolkadotSendError.malformed }
                return .string(String(unicode))
            }
            guard (3...14).contains(p) else { throw PolkadotSendError.runtimeUnsupported }
            let signed = p >= 9, size = 1 << (signed ? p-9 : p-3), bytes = try r.take(size)
            if signed, bytes.last! & 128 != 0 {
                var magnitude = bytes.map { ~$0 }, carry:UInt16 = 1
                for i in magnitude.indices { let n = UInt16(magnitude[i])+carry;magnitude[i]=UInt8(n & 255);carry=n >> 8 }
                return .string("-"+PolkadotIdentity.uint(Data(magnitude)))
            }
            return .string(PolkadotIdentity.uint(bytes))
        case .bits(let store):
            guard case .primitive(let p) = types[store], (3...6).contains(p) else { throw PolkadotSendError.runtimeUnsupported }
            let bits = try r.count(), bytes = 1 << (p-3), words = (bits + bytes*8-1)/(bytes*8)
            return .string(PolkadotIdentity.hex(try r.take(words*bytes)))
        }
    }
    func empty(_ id: Int, depth: Int = 0) -> Bool {
        guard depth < 32 else { return false }
        switch types[id] {
        case .composite(let fields): return fields.allSatisfy { empty($0.type,depth:depth+1) }
        case .tuple(let ids): return ids.allSatisfy { empty($0,depth:depth+1) }
        default: return false
        }
    }
}
