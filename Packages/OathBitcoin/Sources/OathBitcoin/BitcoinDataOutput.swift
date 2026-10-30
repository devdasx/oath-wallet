import Foundation

/// Public output data, decoded independently of the transaction's funding addresses.
/// Binary or malformed payloads remain visible as the original script hex. They
/// are valid receipt content, not application failures, and must not be logged.
public struct BitcoinDataOutput: Equatable, Sendable {
    public let scriptHex: String
    public let message: String?
    public var displayValue: String { message ?? "0x" + scriptHex }

    public init?(script: Data) {
        guard script.first == 0x6a else { return nil }
        scriptHex = script.hex
        message = Self.decodeMessage(Array(script))
    }

    private static func decodeMessage(_ bytes: [UInt8]) -> String? {
        var offset = 1
        var content = Data()
        var pushes = 0
        while offset < bytes.count {
            let opcode = bytes[offset]
            offset += 1
            if pushes > 0 { content.append(0x0a) }
            pushes += 1
            switch opcode {
            case 0...0x4e:
                var length = Int(opcode)
                if opcode >= 0x4c {
                    let width = opcode == 0x4c ? 1 : opcode == 0x4d ? 2 : 4
                    guard width <= bytes.count - offset else { return nil }
                    var decoded: UInt32 = 0
                    for i in 0..<width { decoded |= UInt32(bytes[offset + i]) << (8 * i) }
                    offset += width
                    guard UInt64(decoded) <= UInt64(bytes.count - offset) else { return nil }
                    length = Int(decoded)
                }
                guard length <= bytes.count - offset else { return nil }
                content.append(contentsOf: bytes[offset..<(offset + length)])
                offset += length
            case 0x4f: content.append(0x81)
            case 0x51...0x60: content.append(opcode - 0x50)
            default: return nil
            }
        }
        guard let text = String(data: content, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.unicodeScalars.allSatisfy({ scalar in
                  let value = scalar.value
                  // Keep newlines, tabs and Unicode text, but do not render
                  // binary controls or direction overrides as an ordinary message.
                  return (![0...8, 11...12, 14...31, 127...159, 0x202a...0x202e, 0x2066...0x2069]
                      .contains { $0.contains(value) })
              }) else { return nil }
        return text
    }
}
