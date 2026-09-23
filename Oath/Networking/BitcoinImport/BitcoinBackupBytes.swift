import Foundation

/// Bounded binary decoding. Backup data is untrusted and never interpolated into errors.
struct BitcoinBackupBytes {
    let data: Data
    var offset = 0

    init(_ data: Data) { self.data = Data(data) }
    var remaining: Int { data.count - offset }

    mutating func take(_ count: Int) throws -> Data {
        guard count >= 0, count <= remaining else { throw BitcoinImportError.invalidFile }
        defer { offset += count }
        return Data(data[offset..<(offset + count)])
    }

    mutating func integer(_ count: Int, bigEndian: Bool = false) throws -> UInt64 {
        guard (1...8).contains(count) else { throw BitcoinImportError.invalidFile }
        let bytes = try take(count)
        return (bigEndian ? Array(bytes) : Array(bytes.reversed())).reduce(0) { ($0 << 8) | UInt64($1) }
    }

    mutating func compactSize(limit: Int = 64 * 1024 * 1024) throws -> Int {
        let prefix = try integer(1)
        let value: UInt64
        switch prefix {
        case 253:
            value = try integer(2)
            guard value >= 253 else { throw BitcoinImportError.invalidFile }
        case 254:
            value = try integer(4)
            guard value > UInt16.max else { throw BitcoinImportError.invalidFile }
        case 255:
            value = try integer(8)
            guard value > UInt32.max else { throw BitcoinImportError.invalidFile }
        default: value = prefix
        }
        guard value <= UInt64(limit) else { throw BitcoinImportError.fileTooLarge }
        return Int(value)
    }

    mutating func vector(limit: Int = 64 * 1024 * 1024) throws -> Data {
        try take(compactSize(limit: limit))
    }

    mutating func string(limit: Int = 16_384) throws -> String {
        guard let text = String(data: try vector(limit: limit), encoding: .utf8) else {
            throw BitcoinImportError.invalidFile
        }
        return text
    }

    func integer(at position: Int, count: Int, bigEndian: Bool = false) throws -> UInt64 {
        var reader = self
        guard position >= 0, position <= data.count else { throw BitcoinImportError.invalidFile }
        reader.offset = position
        return try reader.integer(count, bigEndian: bigEndian)
    }

    func slice(at position: Int, count: Int) throws -> Data {
        var reader = self
        guard position >= 0, position <= data.count else { throw BitcoinImportError.invalidFile }
        reader.offset = position
        return try reader.take(count)
    }
}

struct BitcoinBackupRecord: Equatable, Sendable {
    let key: Data
    let value: Data
}
