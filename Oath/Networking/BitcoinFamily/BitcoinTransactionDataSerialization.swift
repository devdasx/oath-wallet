import Foundation

extension Data {
    mutating func appendCompactSize(_ value: Int) {
        precondition(value >= 0)
        if value < 0xfd {
            append(UInt8(value))
        } else if value <= Int(UInt16.max) {
            append(0xfd)
            appendUInt16LE(UInt16(value))
        } else if UInt64(value) <= UInt64(UInt32.max) {
            append(0xfe)
            appendUInt32LE(UInt32(value))
        } else {
            append(0xff)
            appendUInt64LE(UInt64(value))
        }
    }

    mutating func appendScript(_ script: Data) {
        appendCompactSize(script.count)
        append(script)
    }

    mutating func appendUInt16LE(_ value: UInt16) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }

    mutating func appendUInt32LE(_ value: UInt32) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }

    mutating func appendUInt64LE(_ value: UInt64) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
}
