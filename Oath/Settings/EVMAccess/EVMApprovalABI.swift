import Foundation

enum EVMApprovalABI {
    static let approveSelector = "095ea7b3"
    static let setApprovalForAllSelector = "a22cb465"
    private static let allowanceSelector = "dd62ed3e"
    private static let getApprovedSelector = "081812fc"
    private static let isApprovedForAllSelector = "e985e9c5"

    static func allowanceCall(
        ownerAddress: String,
        spenderAddress: String
    ) throws -> String {
        "0x" + allowanceSelector
            + (try addressWord(ownerAddress))
            + (try addressWord(spenderAddress))
    }

    static func getApprovedCall(tokenID: String) throws -> String {
        "0x" + getApprovedSelector + (try uintWord(tokenID))
    }

    static func isApprovedForAllCall(
        ownerAddress: String,
        operatorAddress: String
    ) throws -> String {
        "0x" + isApprovedForAllSelector
            + (try addressWord(ownerAddress))
            + (try addressWord(operatorAddress))
    }

    static func revokeCalldata(
        approval: EVMOnChainApproval
    ) throws -> String {
        switch approval.kind {
        case .tokenAllowance:
            return "0x" + approveSelector
                + (try addressWord(approval.spenderAddress))
                + String(repeating: "0", count: 64)
        case .nftToken:
            return "0x" + approveSelector
                + String(repeating: "0", count: 64)
                + (try uintWord(approval.tokenID ?? ""))
        case .operatorAccess:
            return "0x" + setApprovalForAllSelector
                + (try addressWord(approval.spenderAddress))
                + String(repeating: "0", count: 64)
        }
    }

    static func topicAddress(_ topic: String) -> String? {
        guard topic.count == 66,
              topic.hasPrefix("0x"),
              topic.dropFirst(2).allSatisfy(\.isHexDigit),
              topic.dropFirst(2).prefix(24).allSatisfy({ $0 == "0" })
        else {
            return nil
        }
        return "0x" + topic.suffix(40).lowercased()
    }

    static func topicUnsignedInteger(_ topic: String) throws -> String {
        try SendAtomicAmount.decimalFromHexQuantity(topic)
    }

    static func unsignedInteger(_ output: String) throws -> String {
        try SendAtomicAmount.decimalFromABIUnsignedInteger(output)
    }

    static func address(_ output: String) -> String? {
        guard let word = firstWord(output),
              word.prefix(24).allSatisfy({ $0 == "0" }) else {
            return nil
        }
        let address = "0x" + word.suffix(40)
        guard SendAddressValidator.isValidEVMAddress(address) else {
            return nil
        }
        return address.lowercased()
    }

    static func boolean(_ output: String) throws -> Bool {
        let value = try unsignedInteger(output)
        guard value == "0" || value == "1" else {
            throw AnkrAPIError.invalidResponse
        }
        return value == "1"
    }

    static func metadataString(_ output: String) -> String? {
        guard output.hasPrefix("0x"),
              let bytes = Data(hexString: String(output.dropFirst(2))),
              !bytes.isEmpty else {
            return nil
        }
        let content: Data
        if bytes.count == 32 {
            content = Data(bytes.prefix(while: { $0 != 0 }))
        } else if bytes.count >= 64,
                  let offset = boundedInteger(bytes.prefix(32)),
                  offset <= bytes.count - 32,
                  let length = boundedInteger(
                      bytes[offset..<(offset + 32)]
                  ),
                  length <= 160,
                  offset + 32 + length <= bytes.count {
            content = Data(bytes[(offset + 32)..<(offset + 32 + length)])
        } else {
            return nil
        }
        guard let value = String(data: content, encoding: .utf8)?
            .components(separatedBy: .controlCharacters)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !value.isEmpty else {
            return nil
        }
        return String(value.prefix(80))
    }

    static func isZeroAddress(_ address: String) -> Bool {
        address.caseInsensitiveCompare(
            "0x0000000000000000000000000000000000000000"
        ) == .orderedSame
    }

    private static func addressWord(_ address: String) throws -> String {
        let normalized = address.lowercased()
        guard SendAddressValidator.isValidEVMAddress(normalized) else {
            throw SendTransactionSubmissionError.invalidRecipient
        }
        return String(repeating: "0", count: 24)
            + String(normalized.dropFirst(2))
    }

    private static func uintWord(_ value: String) throws -> String {
        try SendAtomicAmount.fixedWidthData(value, byteCount: 32)
            .hexString
    }

    private static func firstWord(_ output: String) -> Substring? {
        guard output.hasPrefix("0x"), output.count >= 66,
              output.dropFirst(2).allSatisfy(\.isHexDigit) else {
            return nil
        }
        return output.dropFirst(2).prefix(64)
    }

    private static func boundedInteger<T: DataProtocol>(
        _ bytes: T
    ) -> Int? where T.Element == UInt8 {
        guard bytes.count == 32 else { return nil }
        let values = Array(bytes)
        guard values.prefix(24).allSatisfy({ $0 == 0 }) else {
            return nil
        }
        var result: UInt64 = 0
        for byte in values.suffix(8) {
            result = (result << 8) | UInt64(byte)
        }
        return Int(exactly: result)
    }
}
