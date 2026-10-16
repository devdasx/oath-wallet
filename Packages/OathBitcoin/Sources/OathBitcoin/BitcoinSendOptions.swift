import Foundation

/// Per-transfer intent, persisted with the reviewed plan. Message bytes are
/// user content: never include this value in diagnostics or provider context.
public struct BitcoinSendOptions: Codable, Equatable, Sendable {
    public let replaceable: Bool
    public let message: Data

    public init(replaceable: Bool = false, message: Data = Data()) {
        self.replaceable = replaceable
        self.message = message
    }

    public static func supportsRBF(_ chain: UTXONetwork) -> Bool {
        chain == .bitcoin || chain == .dogecoin
    }

    /// Payload limits for one zero-value OP_RETURN. Bitcoin Core 30+ permits
    /// 100,000 script bytes; the complete transaction must ALSO fit 400,000 WU.
    /// Older/custom relay policies can reject >80 bytes on Bitcoin. This is
    /// independent of the funding address type: output data has no discount.
    public static func maximumMessageBytes(_ chain: UTXONetwork) -> Int {
        switch chain {
        case .bitcoin: 99_994 // OP_RETURN + PUSHDATA4 + UInt32 length
        case .bitcoincash: 220 // 223 aggregate script bytes
        case .litecoin, .dogecoin: 80 // 83 script bytes
        }
    }

    public func validate(chain: UTXONetwork) throws {
        guard !replaceable || Self.supportsRBF(chain) else { throw BitcoinSendError.invalidOptions }
        guard message.count <= Self.maximumMessageBytes(chain) else { throw BitcoinSendError.messageTooLarge }
    }

    var dataScript: Data? {
        guard !message.isEmpty else { return nil }
        var script = Data([0x6a])
        // Minimal pushes, including single-byte script-number encodings.
        if message.count == 1, message[0] == 0x81 { script.append(0x4f); return script }
        if message.count == 1, (1...16).contains(message[0]) { script.append(0x50 + message[0]); return script }
        if message.count <= 75 { script.append(UInt8(message.count)) }
        else if message.count <= 255 { script += Data([0x4c, UInt8(message.count)]) }
        else if message.count <= 65_535 { script += Data([0x4d]) + BitcoinWire.little(UInt16(message.count)) }
        else { script += Data([0x4e]) + BitcoinWire.little(UInt32(message.count)) }
        return script + message
    }
}

public struct BitcoinSendOutput: Equatable, Sendable {
    public let value: Int64
    public let script: Data
}
