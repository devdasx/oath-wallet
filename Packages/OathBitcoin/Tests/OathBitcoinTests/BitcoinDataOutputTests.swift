import Foundation
import XCTest
@testable import OathBitcoin

final class BitcoinDataOutputTests: XCTestCase {
    func testAllPushdataLengthsRoundTripWithoutSendPolicyLimits() throws {
        for size in [1, 75, 76, 255, 256, 65_535, 65_536, 99_994] {
            let message = Data(repeating: 0x61, count: size)
            let script = try XCTUnwrap(BitcoinSendOptions(message: message).dataScript)
            let output = try XCTUnwrap(BitcoinDataOutput(script: script))
            XCTAssertEqual(output.message, String(data: message, encoding: .utf8))
            XCTAssertEqual(output.scriptHex, script.hex)
        }
    }

    func testUTF8NewlinesAndSeparatePushes() throws {
        let message = "Payment 💙\nرسالة\t確認"
        let script = try XCTUnwrap(BitcoinSendOptions(message: Data(message.utf8)).dataScript)
        XCTAssertEqual(BitcoinDataOutput(script: script)?.message, message)
        XCTAssertEqual(BitcoinDataOutput(script: Data([0x6a, 3]) + Data("one".utf8)
            + Data([3]) + Data("two".utf8))?.message, "one\ntwo")
        // Nonminimal encodings still occur in historical transactions.
        for prefix: [UInt8] in [[0x6a, 0x4c, 3], [0x6a, 0x4d, 3, 0], [0x6a, 0x4e, 3, 0, 0, 0]] {
            XCTAssertEqual(BitcoinDataOutput(script: Data(prefix) + Data("one".utf8))?.message, "one")
        }
    }

    func testBinaryEmptyAndMalformedScriptsRetainExactHex() throws {
        let scripts: [[UInt8]] = [
            [0x6a], [0x6a, 0], [0x6a, 2, 0xff, 0xfe], [0x6a, 2, 0, 0x61],
            [0x6a, 4, 0x61], [0x6a, 0x4c], [0x6a, 0x4d, 1], [0x6a, 0x4e, 0, 0],
            [0x6a, 0x4e, 0xff, 0xff, 0xff, 0xff], [0x6a, 1, 0x61, 0x76],
            [0x6a, 0x4f]
        ]
        for bytes in scripts + (0x51...0x60).map({ [0x6a, UInt8($0)] }) {
            let script = Data(bytes)
            let output = try XCTUnwrap(BitcoinDataOutput(script: script))
            XCTAssertNil(output.message)
            XCTAssertEqual(output.displayValue, "0x" + script.hex)
        }
        let override = try XCTUnwrap(BitcoinSendOptions(message: Data("ab\u{202e}cd".utf8)).dataScript)
        XCTAssertNil(BitcoinDataOutput(script: override)?.message)
    }

    func testOrdinaryAndUnknownLockingScriptsAreNotMessages() {
        for script in [Data(), Data([0, 0x6a]), Data([0x51]),
                       Data([0x76, 0xa9, 20]) + Data(repeating: 0x6a, count: 20) + Data([0x88, 0xac]),
                       Data([0x51, 32]) + Data(repeating: 0x6a, count: 32)] {
            XCTAssertNil(BitcoinDataOutput(script: script))
        }
    }
}
