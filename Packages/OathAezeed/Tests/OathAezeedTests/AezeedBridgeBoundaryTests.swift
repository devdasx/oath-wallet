import XCTest
import OathAezeedCore

final class AezeedBridgeBoundaryTests: XCTestCase {
    func testInvalidInputClearsOnlyTheDeclaredOutput() {
        let encoded = [UInt8](repeating: 0, count: 33)
        let password = [UInt8](repeating: 0, count: 4097)
        for length in [0, 1, 32, 34, Int.max] {
            var output = [UInt8](repeating: 0x7a, count: 21)
            let status = encoded.withUnsafeBufferPointer { input in
                output.withUnsafeMutableBufferPointer { buffer in
                    OathAezeedDecode(input.baseAddress, length, nil, 0, buffer.baseAddress! + 1, 19)
                }
            }
            XCTAssertEqual(status, 1)
            XCTAssertEqual(output, [0x7a] + Array(repeating: 0, count: 19) + [0x7a])
        }
        for missingPassword in [false, true] {
            var output = [UInt8](repeating: 0x7a, count: 21)
            let status = encoded.withUnsafeBufferPointer { input in
                password.withUnsafeBufferPointer { pass in
                    output.withUnsafeMutableBufferPointer { buffer in
                        OathAezeedDecode(input.baseAddress, 33,
                            missingPassword ? nil : pass.baseAddress,
                            missingPassword ? 1 : 4097, buffer.baseAddress! + 1, 19)
                    }
                }
            }
            XCTAssertEqual(status, 1)
            XCTAssertEqual(output, [0x7a] + Array(repeating: 0, count: 19) + [0x7a])
        }
    }

    func testInvalidOutputAndMalformedSeedCannotExposePlaintext() {
        XCTAssertEqual(OathAezeedDecode(nil, 0, nil, 0, nil, 19), 1)
        for length in [0, 18, 20, Int.max] {
            var output = [UInt8](repeating: 0x7a, count: 21)
            let status = output.withUnsafeMutableBufferPointer { buffer in
                OathAezeedDecode(nil, 0, nil, 0, buffer.baseAddress, length)
            }
            XCTAssertEqual(status, 1)
            XCTAssertEqual(output, Array(repeating: 0x7a, count: 21))
        }
        let encoded = [UInt8](repeating: 0, count: 33)
        var output = [UInt8](repeating: 0x7a, count: 21)
        let status = encoded.withUnsafeBufferPointer { input in
            output.withUnsafeMutableBufferPointer { buffer in
                OathAezeedDecode(input.baseAddress, 33, nil, 0, buffer.baseAddress! + 1, 19)
            }
        }
        XCTAssertNotEqual(status, 0)
        XCTAssertEqual(output, [0x7a] + Array(repeating: 0, count: 19) + [0x7a])
    }
}
