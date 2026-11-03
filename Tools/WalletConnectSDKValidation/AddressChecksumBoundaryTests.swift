import XCTest
@testable import WalletConnectSigner
import WalletConnectNetworking

private final class ChecksumCryptoProbe: CryptoProvider {
    var hash = Data(repeating: 0xab, count: 32)
    var inputs: [Data] = []
    func keccak256(_ data: Data) -> Data { inputs.append(data); return hash }
    func recoverPubKey(signature: EthereumSignature, message: Data) throws -> Data {
        XCTFail("Checksum encoding must not recover a key")
        return Data()
    }
}

final class AddressChecksumBoundaryTests: XCTestCase {
    func testKnownAnswerChecksumsAndCanonicalHashInput() throws {
        for vector in checksumVectors {
            let crypto = ChecksumCryptoProbe()
            crypto.hash = Data(hex: vector.hash)
            let encoder = EIP55(crypto: crypto)
            XCTAssertEqual(try encoder.encode(vector.input), vector.expected)
            XCTAssertEqual(try encoder.encode("0x" + vector.input.uppercased()), vector.expected)
            XCTAssertEqual(try encoder.encode(Data(hex: vector.input)), String(vector.expected.dropFirst(2)))
            XCTAssertEqual(crypto.inputs, Array(repeating: Data(vector.input.utf8), count: 3))
        }
    }

    func testUppercasePrefixPreservesAddress() throws {
        for vector in checksumVectors {
            let crypto = ChecksumCryptoProbe(); crypto.hash = Data(hex: vector.hash)
            XCTAssertEqual(try EIP55(crypto: crypto).encode("0X" + vector.input), vector.expected)
        }
    }

    func testNonAddressByteLengthsRejectBeforeHashing() {
        let crypto = ChecksumCryptoProbe(); let encoder = EIP55(crypto: crypto)
        for length in [0, 1, 19, 21, 32, 33, 128] {
            XCTAssertThrowsError(try encoder.encode(Data(repeating: 0xab, count: length)))
        }
        XCTAssertTrue(crypto.inputs.isEmpty)
    }

    func testWrongHexLengthsRejectBeforeHashing() {
        let crypto = ChecksumCryptoProbe(); let encoder = EIP55(crypto: crypto)
        for length in [0, 1, 2, 38, 39, 41, 42, 64, 80] {
            XCTAssertThrowsError(try encoder.encode("0x" + String(repeating: "a", count: length)))
        }
        XCTAssertTrue(crypto.inputs.isEmpty)
    }

    func testInvalidNibblesRejectInsteadOfChangingAddress() {
        let crypto = ChecksumCryptoProbe(); let encoder = EIP55(crypto: crypto)
        for position in [0, 1, 18, 19, 38, 39] {
            var chars = Array(String(repeating: "a", count: 40)); chars[position] = "g"
            XCTAssertThrowsError(try encoder.encode("0x" + String(chars)))
        }
        XCTAssertTrue(crypto.inputs.isEmpty)
    }

    func testEmbeddedAndRepeatedPrefixesAreNotRemoved() {
        let crypto = ChecksumCryptoProbe(); let encoder = EIP55(crypto: crypto)
        for text in ["0x0x" + String(repeating: "a", count: 40), String(repeating: "a", count: 20) + "0x" + String(repeating: "a", count: 20)] {
            XCTAssertThrowsError(try encoder.encode(text))
        }
        XCTAssertTrue(crypto.inputs.isEmpty)
    }

    func testUnicodeAndWhitespaceAreNotCoerced() {
        let crypto = ChecksumCryptoProbe(); let encoder = EIP55(crypto: crypto)
        for text in [String(repeating: "Ａ", count: 40), String(repeating: "a", count: 39) + "é", " " + String(repeating: "a", count: 40), String(repeating: "a", count: 40) + "\n", String(repeating: "a", count: 39) + "\0"] {
            XCTAssertThrowsError(try encoder.encode(text))
        }
        XCTAssertTrue(crypto.inputs.isEmpty)
    }

    func testInvalidHashLengthCannotTruncateOutput() {
        for length in [0, 1, 19, 20, 31, 33, 64] {
            let crypto = ChecksumCryptoProbe(); crypto.hash = Data(repeating: 0, count: length)
            XCTAssertThrowsError(try EIP55(crypto: crypto).encode(Data(repeating: 0xab, count: 20)))
        }
    }

    func testNonzeroOriginDataSliceRetainsAddress() throws {
        let vector = checksumVectors[0]
        let crypto = ChecksumCryptoProbe(); crypto.hash = Data(hex: vector.hash)
        let data = (Data([0xff]) + Data(hex: vector.input)).dropFirst()
        XCTAssertEqual(try EIP55(crypto: crypto).encode(data), String(vector.expected.dropFirst(2)))
    }
}
