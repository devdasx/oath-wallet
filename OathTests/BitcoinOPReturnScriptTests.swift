import Foundation
import Testing
@testable import Aperture

struct BitcoinOPReturnScriptTests {
    @Test(arguments: [
        (1, [0x6a, 0x01]), (75, [0x6a, 0x4b]),
        (76, [0x6a, 0x4c, 0x4c]), (255, [0x6a, 0x4c, 0xff]),
        (256, [0x6a, 0x4d, 0x00, 0x01]), (1_131, [0x6a, 0x4d, 0x6b, 0x04]),
        (65_535, [0x6a, 0x4d, 0xff, 0xff]),
        (65_536, [0x6a, 0x4e, 0x00, 0x00, 0x01, 0x00]),
        (99_994, [0x6a, 0x4e, 0x9a, 0x86, 0x01, 0x00])
    ])
    func encodesEveryPushBoundary(vector: (Int, [Int])) throws {
        let (count, prefix) = vector
        let message = String(repeating: "x", count: count)
        let script = try #require(try SendBitcoinOPReturn.scriptPubKey(for: message))
        #expect(Array(script.prefix(prefix.count)).map(Int.init) == prefix)
        #expect(script.count == count + prefix.count)
        #expect(try Self.decodePayload(script) == Data(message.utf8))
    }

    @Test(arguments: [(249, 261), (250, 264), (65_531, 65_546), (65_532, 65_549), (99_994, 100_013)])
    func measuresCompactSizeBoundaries(vector: (Int, Int)) throws {
        let (count, outputBytes) = vector
        let payload = Data(repeating: 0x78, count: count)
        #expect(SendBitcoinV2OutputBuilder.serializedOPReturnSize(payload: payload) == Int64(outputBytes))
        let fixture = try BitcoinOPReturnSigningFixture(types: [.bip84])
        let base = fixture.draft(options: .automatic)
        let message = String(repeating: "x", count: count)
        let draft = base.replacingBitcoinFamilyOptions(.automatic.replacingOPReturnMessage(message))
        #expect(SendNetworkFeeEstimator.templateUTXOVirtualBytes(draft: draft)
                - SendNetworkFeeEstimator.templateUTXOVirtualBytes(draft: base) == UInt64(outputBytes))
    }

    @Test
    func enforcesScriptBudgetWithoutTruncatingUTF8() throws {
        let maximum = String(repeating: "🙂", count: 24_998) + "ab"
        var editor = SendBitcoinOPReturnEditorState(message: "")
        let accepted = editor.replaceMessage(maximum)
        #expect(accepted)
        #expect(editor.byteCount == 99_994)
        #expect(editor.remainingByteCount == 0)
        #expect(try SendBitcoinOPReturn.scriptPubKey(for: maximum)?.count == 100_000)
        let acceptedOversized = editor.replaceMessage(maximum + "a")
        #expect(!acceptedOversized)
        #expect(editor.message == maximum)
        for count in [99_995, 100_000, 100_001] {
            #expect(throws: SendBitcoinFamilyOptionsError.opReturnTooLarge) {
                try SendBitcoinOPReturn.payload(for: String(repeating: "x", count: count))
            }
        }
        #expect(try SendBitcoinOPReturn.scriptPubKey(for: "") == nil)
        #expect(try SendBitcoinOPReturn.scriptPubKey(for: nil) == nil)
    }

    @Test
    func enforcesInclusiveStandardWeightBoundary() throws {
        try SendBitcoinTransactionPolicy.validateWeight(399_999)
        try SendBitcoinTransactionPolicy.validateWeight(400_000)
        try SendBitcoinTransactionPolicy.validateVirtualSize(100_000)
        #expect(throws: SendTransactionSubmissionError.self) {
            try SendBitcoinTransactionPolicy.validateWeight(400_001)
        }
        #expect(throws: SendTransactionSubmissionError.self) {
            try SendBitcoinTransactionPolicy.validateVirtualSize(100_001)
        }
    }

    /// Independent wire decoder: validates minimal push-length encoding and
    /// consumes the complete script, detecting truncation or extra outputs.
    static func decodePayload(_ data: Data) throws -> Data {
        let bytes = Array(data)
        #expect(bytes.first == 0x6a)
        let opcode = try #require(bytes.dropFirst().first)
        let lengthBytes: Int
        let minimum: Int
        switch opcode {
        case 0...75: lengthBytes = 0; minimum = 0
        case 0x4c: lengthBytes = 1; minimum = 76
        case 0x4d: lengthBytes = 2; minimum = 256
        case 0x4e: lengthBytes = 4; minimum = 65_536
        default: throw DecodeError.invalidPush
        }
        guard bytes.count >= 2 + lengthBytes else { throw DecodeError.truncated }
        let length = lengthBytes == 0 ? Int(opcode) : (0..<lengthBytes).reduce(0) {
            $0 | (Int(bytes[2 + $1]) << ($1 * 8))
        }
        #expect(length >= minimum)
        #expect(bytes.count == 2 + lengthBytes + length)
        return Data(bytes.dropFirst(2 + lengthBytes))
    }

    private enum DecodeError: Error { case invalidPush, truncated }
}
