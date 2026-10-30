import XCTest
@testable import OathTokenImages

final class TonArtworkAddressTests: XCTestCase {
    private let raw = "0:ca6e321c7cce9ecedf0a8ca2492ec8592494aa5fb5ce0387dff96ef6af982a3e"
    private let bounce = "EQDKbjIcfM6ezt8KjKJJLshZJJSqX7XOA4ff-W72r5gqPrHF"
    private let nonbounce = "UQDKbjIcfM6ezt8KjKJJLshZJJSqX7XOA4ff-W72r5gqPuwA"
    private func list(_ addresses: [String], distinctLogos: Bool = false) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["tokens": addresses.enumerated().map {
            ["chainId": NSNull(), "address": $0.element, "logoURI": "https://cdn.example.org/\(distinctLogos ? $0.offset : 0).png"]
        }])
    }
    func testOfficialTEP2VectorsMatchRawWithBothBase64Alphabets() {
        for value in [raw, raw.uppercased(), bounce, nonbounce, bounce.replacingOccurrences(of: "-", with: "+")] {
            XCTAssertEqual(TonArtworkAddress.raw(value), raw)
        }
        XCTAssertEqual(TonArtworkAddress.raw("EQD36Lxp6p4FMzHQThWzvFNaqhbT8Qip4rMF1NYjCSgY6ksE"),
                       "0:f7e8bc69ea9e053331d04e15b3bc535aaa16d3f108a9e2b305d4d623092818ea")
    }
    func testCorruptTestnetUnsupportedFlagsAndMalformedRawNeverMatch() {
        for invalid in ["kQDKbjIcfM6ezt8KjKJJLshZJJSqX7XOA4ff-W72r5gqPgpP",
                        "0QDKbjIcfM6ezt8KjKJJLshZJJSqX7XOA4ff-W72r5gqPleK",
                        String(bounce.dropLast()) + "A", " " + bounce, bounce + "=",
                        "256:" + raw.split(separator: ":")[1], "00:" + raw.split(separator: ":")[1],
                        raw.replacingOccurrences(of: "ca6e", with: "xyz0")] {
            XCTAssertNil(TonArtworkAddress.raw(invalid))
        }
        // A valid checksum cannot make an unsupported tag a valid mainnet address.
        var bytes = Data(base64Encoded: bounce.replacingOccurrences(of: "-", with: "+"))!
        bytes[0] = 0x31
        var crc: UInt16 = 0
        for byte in bytes.prefix(34) { crc ^= UInt16(byte) << 8; for _ in 0..<8 { crc = crc & 0x8000 != 0 ? (crc &<< 1) ^ 0x1021 : crc &<< 1 } }
        bytes[34] = UInt8(crc >> 8); bytes[35] = UInt8(crc & 255)
        XCTAssertNil(TonArtworkAddress.raw(bytes.base64EncodedString()))
    }
    func testAliasesShareOnlySameWorkchainAndConflictingImagesFail() throws {
        let decoded = try ArtworkFallbackCatalog.decode(list([raw, bounce, nonbounce]), chainID: nil, networkID: "ton")
        XCTAssertEqual(decoded, [raw: "https://cdn.example.org/0.png"])
        XCTAssertThrowsError(try ArtworkFallbackCatalog.decode(list([raw, bounce], distinctLogos: true), chainID: nil, networkID: "ton"))
        let otherWorkchain = raw.replacingOccurrences(of: "0:", with: "-1:")
        XCTAssertNotEqual(TonArtworkAddress.raw(otherWorkchain), raw)
        let separate = try ArtworkFallbackCatalog.decode(list([raw, otherWorkchain], distinctLogos: true), chainID: nil, networkID: "ton")
        XCTAssertEqual(separate.count, 2)
    }
}
