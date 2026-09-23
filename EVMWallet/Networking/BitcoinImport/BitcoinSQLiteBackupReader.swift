import Foundation

/// Reads a standalone Bitcoin Core SQLite backup directly, without opening another
/// SQLite connection, executing file-provided SQL, or copying secrets to disk.
struct BitcoinSQLiteBackupReader {
    private let bytes: BitcoinBackupBytes
    private let pageSize: Int
    private let usable: Int
    private let pageCount: Int

    init(data: Data) throws {
        guard data.count >= 512, data.count <= 64 * 1024 * 1024,
              data.prefix(16) == Data("SQLite format 3\0".utf8) else {
            throw BitcoinImportError.invalidFile
        }
        bytes = BitcoinBackupBytes(data)
        let encodedSize = try bytes.integer(at: 16, count: 2, bigEndian: true)
        pageSize = encodedSize == 1 ? 65536 : Int(encodedSize)
        guard (512...65536).contains(pageSize), pageSize.nonzeroBitCount == 1,
              data.count.isMultiple(of: pageSize) else { throw BitcoinImportError.invalidFile }
        usable = pageSize - Int(data[20])
        pageCount = data.count / pageSize
        guard usable >= 480, Array(data[21...23]) == [64, 32, 32],
              data[18] == 1, data[19] == 1,
              try bytes.integer(at: 24, count: 4, bigEndian: true) == bytes.integer(at: 92, count: 4, bigEndian: true),
              try bytes.integer(at: 28, count: 4, bigEndian: true) == pageCount else {
            throw BitcoinImportError.incompleteBackup
        }
        guard try bytes.integer(at: 68, count: 4, bigEndian: true) == 0xf9beb4d9 else {
            throw BitcoinImportError.unsupportedNetwork
        }
        guard try bytes.integer(at: 56, count: 4, bigEndian: true) == 1,
              try bytes.integer(at: 60, count: 4, bigEndian: true) == 0 else {
            throw BitcoinImportError.unsupportedDatabase
        }
    }

    func records() throws -> [BitcoinBackupRecord] {
        var root: Int?
        var withoutRowID = false
        for payload in try tree(root: 1, indexTree: false) {
            let fields = try fields(payload)
            guard fields.count == 5 else { throw BitcoinImportError.invalidFile }
            if fields[0].text == "table", fields[1].text == "main", fields[2].text == "main" {
                guard root == nil, let page = fields[3].integer, page > 0,
                      let sql = fields[4].text else { throw BitcoinImportError.invalidFile }
                root = page
                withoutRowID = sql.uppercased().contains("WITHOUT ROWID")
            }
        }
        guard let root else { throw BitcoinImportError.unsupportedDatabase }
        var keys = Set<Data>()
        return try tree(root: root, indexTree: withoutRowID).map { payload in
            let fields = try fields(payload)
            guard fields.count == 2, case let .blob(key) = fields[0],
                  case let .blob(value) = fields[1], keys.insert(key).inserted else {
                throw BitcoinImportError.invalidFile
            }
            return BitcoinBackupRecord(key: key, value: value)
        }
    }

    private func base(_ page: Int) throws -> Int {
        guard (1...pageCount).contains(page) else { throw BitcoinImportError.invalidFile }
        return (page - 1) * pageSize
    }

    private func number(_ offset: Int, _ count: Int) throws -> Int {
        let value = try bytes.integer(at: offset, count: count, bigEndian: true)
        guard value <= Int.max else { throw BitcoinImportError.invalidFile }
        return Int(value)
    }

    private func tree(root: Int, indexTree: Bool) throws -> [Data] {
        var pending = [root]
        var visited = Set<Int>()
        var result: [Data] = []
        var total = 0
        while let page = pending.popLast() {
            try Task.checkCancellation()
            guard visited.insert(page).inserted else { throw BitcoinImportError.invalidFile }
            let start = try base(page)
            let header = start + (page == 1 ? 100 : 0)
            let type = try number(header, 1)
            let interior = type == 2 || type == 5
            guard indexTree ? [2, 10].contains(type) : [5, 13].contains(type) else {
                throw BitcoinImportError.invalidFile
            }
            let count = try number(header + 3, 2)
            let pointers = header + (interior ? 12 : 8)
            guard pointers + count * 2 <= start + usable else { throw BitcoinImportError.invalidFile }
            if interior { pending.append(try number(header + 8, 4)) }
            for index in 0..<count {
                let cell = start + (try number(pointers + index * 2, 2))
                guard cell >= pointers + count * 2, cell < start + usable else {
                    throw BitcoinImportError.invalidFile
                }
                var reader = BitcoinBackupBytes(try bytes.slice(at: cell, count: start + usable - cell))
                if interior { pending.append(Int(try reader.integer(4, bigEndian: true))) }
                if type == 5 { _ = try varint(&reader); continue }
                let size = try varint(&reader)
                guard size <= bytes.data.count else { throw BitcoinImportError.invalidFile }
                if type == 13 { _ = try varint(&reader) }
                let maximum = type == 13 ? usable - 35 : ((usable - 12) * 64 / 255) - 23
                let minimum = ((usable - 12) * 32 / 255) - 23
                let candidate = minimum + (size - minimum) % (usable - 4)
                let local = size <= maximum ? size : (candidate <= maximum ? candidate : minimum)
                var payload = try reader.take(local)
                if local < size {
                    var overflow = Int(try reader.integer(4, bigEndian: true))
                    var seen = Set<Int>()
                    while payload.count < size {
                        guard seen.insert(overflow).inserted else { throw BitcoinImportError.invalidFile }
                        let offset = try base(overflow)
                        let next = try number(offset, 4)
                        let length = min(size - payload.count, usable - 4)
                        payload.append(try bytes.slice(at: offset + 4, count: length))
                        overflow = next
                    }
                    guard overflow == 0 else { throw BitcoinImportError.invalidFile }
                }
                total += payload.count
                guard total <= bytes.data.count, result.count < 500_000 else {
                    throw BitcoinImportError.invalidFile
                }
                result.append(payload)
            }
        }
        return result
    }

    private enum Field {
        case null, integerValue(Int), blob(Data), textValue(String)
        var text: String? { if case let .textValue(value) = self { return value }; return nil }
        var integer: Int? { if case let .integerValue(value) = self { return value }; return nil }
    }

    private func fields(_ payload: Data) throws -> [Field] {
        var header = BitcoinBackupBytes(payload)
        let headerSize = try varint(&header)
        guard headerSize >= header.offset, headerSize <= payload.count else { throw BitcoinImportError.invalidFile }
        var types: [Int] = []
        while header.offset < headerSize {
            types.append(try varint(&header))
            guard types.count <= 16 else { throw BitcoinImportError.invalidFile }
        }
        guard header.offset == headerSize else { throw BitcoinImportError.invalidFile }
        var values = BitcoinBackupBytes(Data(payload.dropFirst(headerSize)))
        let result: [Field] = try types.map { type in
            switch type {
            case 0: return .null
            case 1...6:
                let count = [1, 2, 3, 4, 6, 8][type - 1]
                let value = try values.integer(count, bigEndian: true)
                guard value <= Int.max else { throw BitcoinImportError.invalidFile }
                return .integerValue(Int(value))
            case 8: return .integerValue(0)
            case 9: return .integerValue(1)
            case 12...:
                let data = try values.take((type - 12) / 2)
                if type.isMultiple(of: 2) { return .blob(data) }
                guard let text = String(data: data, encoding: .utf8) else { throw BitcoinImportError.invalidFile }
                return .textValue(text)
            default: throw BitcoinImportError.invalidFile
            }
        }
        guard values.remaining == 0 else { throw BitcoinImportError.invalidFile }
        return result
    }

    private func varint(_ reader: inout BitcoinBackupBytes) throws -> Int {
        var value: UInt64 = 0
        for index in 0..<9 {
            let byte = try reader.integer(1)
            value = index == 8 ? (value << 8) | byte : (value << 7) | (byte & 0x7f)
            if byte < 128 || index == 8 {
                guard value <= Int.max else { throw BitcoinImportError.invalidFile }
                return Int(value)
            }
        }
        throw BitcoinImportError.invalidFile
    }
}
