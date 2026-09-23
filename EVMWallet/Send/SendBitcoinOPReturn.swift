import Foundation

enum SendBitcoinOPReturn {
    /// Bitcoin Core 30's default aggregate data-carrier script allowance.
    /// OP_RETURN + OP_PUSHDATA4 + its length take six bytes. The complete
    /// transaction must independently fit the standard transaction weight.
    static let maximumScriptBytes = 100_000
    static let maximumPayloadBytes = maximumScriptBytes - 6

    static func byteCount(_ message: String) -> Int {
        message.utf8.count
    }

    static func remainingByteCount(_ message: String) -> Int {
        max(0, maximumPayloadBytes - byteCount(message))
    }

    static func acceptsEditableInput(_ message: String) -> Bool {
        byteCount(message) <= maximumPayloadBytes
    }

    static func normalizedMessage(
        _ message: String?,
        chain: BitcoinFamilyChain
    ) throws -> String? {
        guard let message, !message.isEmpty else { return nil }
        guard chain.supportsOPReturn else {
            throw SendBitcoinFamilyOptionsError.opReturnUnsupported
        }
        guard acceptsEditableInput(message) else {
            throw SendBitcoinFamilyOptionsError.opReturnTooLarge
        }
        return message
    }

    static func payload(for message: String?) throws -> Data? {
        guard let message, !message.isEmpty else { return nil }
        guard acceptsEditableInput(message) else {
            throw SendBitcoinFamilyOptionsError.opReturnTooLarge
        }
        return Data(message.utf8)
    }

    static func scriptPubKey(for message: String?) throws -> Data? {
        guard let payload = try payload(for: message) else { return nil }
        return scriptPubKey(payload: payload)
    }

    /// Callers pass a payload already validated by `payload(for:)`.
    static func scriptPubKey(payload: Data) -> Data {
        var script = Data([0x6a])
        switch payload.count {
        case ...75:
            script.append(UInt8(payload.count))
        case ...255:
            script.append(contentsOf: [0x4c, UInt8(payload.count)])
        case ...65_535:
            script.append(0x4d)
            var length = UInt16(payload.count).littleEndian
            withUnsafeBytes(of: &length) { script.append(contentsOf: $0) }
        default:
            script.append(0x4e)
            var length = UInt32(payload.count).littleEndian
            withUnsafeBytes(of: &length) { script.append(contentsOf: $0) }
        }
        script.append(payload)
        return script
    }

    static func serializedOutputSize(scriptBytes: Int) -> Int {
        8 + compactSizeLength(scriptBytes) + scriptBytes
    }

    static func compactSizeLength(_ value: Int) -> Int {
        switch value {
        case ...252: 1
        case ...65_535: 3
        case ...Int(UInt32.max): 5
        default: 9
        }
    }
}
