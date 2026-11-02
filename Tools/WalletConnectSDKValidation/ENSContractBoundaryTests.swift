import XCTest
@testable import WalletConnectSigner
import WalletConnectNetworking
import HTTPClient

private struct ENSResponseClient: HTTPClient {
    let result: String

    func request<T: Decodable>(_ type: T.Type, at service: HTTPService) async throws -> T {
        let response = RPCResponse(id: 1, result: result)
        return try JSONDecoder().decode(type, from: JSONEncoder().encode(response))
    }

    func request(service: HTTPService) async throws {
        XCTFail("Unexpected fire-and-forget HTTP request")
    }

    func updateHost(host: String) async {
        XCTFail("Unexpected HTTP host change")
    }
}

final class ENSContractBoundaryTests: XCTestCase {
    private func word(_ value: Int) -> String {
        let hex = String(value, radix: 16)
        return String(repeating: "0", count: 64 - hex.count) + hex
    }

    private func dynamic(_ bytes: [UInt8]) -> String {
        let payload = bytes.map { String(format: "%02x", $0) }.joined()
        let padding = String(repeating: "00", count: (32 - bytes.count % 32) % 32)
        return "0x" + word(32) + word(bytes.count) + payload + padding
    }

    func testIntegerOverflowIsRejected() {
        XCTAssertThrowsError(try ContractDecoder.int("0x" + String(repeating: "f", count: 64)))
    }

    func testNonHexIntegerIsRejected() {
        XCTAssertThrowsError(try ContractDecoder.int("0x" + String(repeating: "g", count: 64)))
    }

    func testSignedIntegerIsRejected() {
        XCTAssertThrowsError(try ContractDecoder.int("0x-" + String(repeating: "0", count: 62) + "1"))
    }

    func testOffsetMultiplicationCannotOverflow() {
        XCTAssertThrowsError(try ContractDecoder.dynamicBytes("0x" + word(0), at: Int.max))
    }

    func testLengthMultiplicationCannotOverflow() {
        XCTAssertThrowsError(try ContractDecoder.dynamicBytes("0x" + word(Int.max), at: 0))
    }

    func testNegativeAndUnalignedOffsetsAreRejected() {
        for offset in [-1, -32, Int.min, 1, 31, 33] {
            XCTAssertThrowsError(try ContractDecoder.dynamicBytes(dynamic([65]), at: offset))
        }
    }

    func testMalformedAddressIsRejected() {
        for value in [String(repeating: "0", count: 24) + String(repeating: "z", count: 40),
                      "1" + String(repeating: "0", count: 63),
                      String(repeating: "é", count: 64)] {
            XCTAssertThrowsError(try ContractDecoder.address("0x" + value))
        }
    }

    func testValidAddressAndIntegers() throws {
        let address = String(repeating: "Ab", count: 20)
        XCTAssertEqual(try ContractDecoder.address("0x" + String(repeating: "0", count: 24) + address).0, "0x" + address)
        for value in [0, 1, 32, Int.max] {
            XCTAssertEqual(try ContractDecoder.int("0x" + word(value)).0, value)
        }
    }

    func testValidDynamicBytesAcrossWordBoundaries() throws {
        for length in [0, 1, 31, 32, 33, 63, 64, 65, 1024] {
            let bytes = (0..<length).map { UInt8($0 % 256) }
            XCTAssertEqual(try ContractDecoder.dynamicBytes(dynamic(bytes), at: 32), Data(bytes))
        }
        XCTAssertEqual(try ContractDecoder.string(dynamic(Array("oath.eth".utf8)), at: 32), "oath.eth")
        XCTAssertEqual(try ContractDecoder.string(dynamic(Array("é.eth".utf8)), at: 32), "é.eth")
    }

    func testTruncatedLengthAndPayloadAreRejected() {
        for result in ["", "0x", "0x0", "0x" + String(repeating: "0", count: 63),
                       "0x" + word(1), "0x" + word(33) + String(repeating: "00", count: 32)] {
            XCTAssertThrowsError(try ContractDecoder.dynamicBytes(result, at: 0))
        }
    }

    func testMalformedHexPayloadIsRejected() {
        for byte in ["zz", "éé", "1", "-1"] {
            let result = "0x" + word(32) + word(1) + byte + String(repeating: "00", count: 31)
            XCTAssertThrowsError(try ContractDecoder.dynamicBytes(result, at: 32))
        }
    }

    func testMissingOrNonzeroPaddingIsRejected() {
        XCTAssertThrowsError(try ContractDecoder.dynamicBytes("0x" + word(1) + "41", at: 0))
        XCTAssertThrowsError(try ContractDecoder.dynamicBytes("0x" + word(1) + "41" + String(repeating: "01", count: 31), at: 0))
    }

    func testInvalidUTF8IsRejected() {
        XCTAssertThrowsError(try ContractDecoder.string(dynamic([255]), at: 32))
    }

    func testResolverRejectsOversizedProviderOffset() async throws {
        let client = ENSResponseClient(result: "0x" + String(repeating: "f", count: 64))
        let resolver = ENSResolverContract(address: "0x" + String(repeating: "0", count: 40),
                                           projectId: "synthetic", chainId: "eip155:1", httpClient: client)
        do {
            _ = try await resolver.name(namehash: Data(repeating: 0, count: 32))
            XCTFail("Expected malformed provider result to fail")
        } catch { }
    }

    func testResolverDecodesValidProviderResult() async throws {
        let client = ENSResponseClient(result: dynamic(Array("oath.eth".utf8)))
        let resolver = ENSResolverContract(address: "0x" + String(repeating: "0", count: 40),
                                           projectId: "synthetic", chainId: "eip155:1", httpClient: client)
        let name = try await resolver.name(namehash: Data(repeating: 0, count: 32))
        XCTAssertEqual(name, "oath.eth")
    }

    func testDeterministicBoundedInvalidWordMutations() {
        let valid = Array(word(32).utf8)
        for index in valid.indices {
            for invalid: UInt8 in [45, 47, 58, 71, 103, 127, 255] {
                var changed = valid
                changed[index] = invalid
                let result = "0x" + String(decoding: changed, as: UTF8.self)
                XCTAssertThrowsError(try ContractDecoder.int(result))
                XCTAssertThrowsError(try ContractDecoder.address(result))
            }
        }
    }
}
