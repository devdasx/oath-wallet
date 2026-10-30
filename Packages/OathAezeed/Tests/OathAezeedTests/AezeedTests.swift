import XCTest
@testable import OathAezeed

final class AezeedTests: XCTestCase {
    // Deterministic public entropy from LND, encoded with production N=32768.
    // Upstream's unit-test words use a deliberately incompatible test KDF.
    struct Vector: Decodable { let phrase: String; let password: String; let version: UInt8; let birthday: UInt16 }
    var vectors: [Vector] { get throws {
        try JSONDecoder().decode([Vector].self, from: Data(contentsOf: Bundle.module.url(forResource: "lnd-production", withExtension: "json")!))
    } }
    var plain: String { try! vectors[0].phrase }
    var protected: String { try! vectors[1].phrase }
    let password = "!very_safe_55345_password*"
    func testOfficialLNDVectors() throws {
        let first = try Aezeed.decode(plain)
        let second = try Aezeed.decode(protected, passphrase: password)
        XCTAssertEqual(first.entropy, Data([0x81,0xb6,0x37,0xd8,0x63,0x59,0xe6,0x96,0x0d,0xe7,0x95,0xe4,0x1e,0x0b,0x4c,0xfd]))
        XCTAssertEqual(first.entropy, second.entropy)
        XCTAssertEqual(first.birthday, 3365)
        XCTAssertEqual(second.birthday, 3365)
        XCTAssertEqual(first.version, 0)
        XCTAssertTrue(first.isValid)
        XCTAssertEqual(try Aezeed.decode(plain, passphrase: "aezeed").entropy, first.entropy)
    }
    func testExactPasswordAndNoSilentBIP39Fallback() throws {
        for value in ["", "wrong", " " + password, password + " "] {
            XCTAssertThrowsError(try Aezeed.decode(protected, passphrase: value)) { error in
                XCTAssertEqual(error as? AezeedError, .incorrectPassphrase)
            }
        }
        // scrypt's HMAC zero-pads short passwords; trailing NUL equivalence
        // is upstream behavior, not C-string truncation at this bridge.
        XCTAssertEqual(try Aezeed.decode(protected, passphrase: password + "\0").entropy,
                       try Aezeed.decode(protected, passphrase: password).entropy)
        XCTAssertThrowsError(try Aezeed.decode(protected, passphrase: String(repeating: "x", count: 4097)))
    }
    func testRecognitionBoundsChecksumAndCanonicalization() throws {
        XCTAssertTrue(Aezeed.recognizes(plain))
        XCTAssertTrue(Aezeed.recognizes(protected))
        XCTAssertEqual(try Aezeed.decode(" \n" + plain.uppercased().replacingOccurrences(of: " ", with: "\n") + " ").entropy,
                       try Aezeed.decode(plain).entropy)
        for input in ["", String(repeating: "a", count: 4097), plain + " ability",
                      plain.split(separator: " ").dropLast().joined(separator: " ") + " abandon",
                      "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"] {
            XCTAssertFalse(Aezeed.recognizes(input))
            XCTAssertThrowsError(try Aezeed.decode(input))
        }
    }
    func testVersionAndExactUnicodePassword() throws {
        let unicode = try vectors[2]
        let decoded = try Aezeed.decode(unicode.phrase, passphrase: unicode.password)
        XCTAssertEqual(decoded.version, 1)
        XCTAssertEqual(decoded.passphrase, unicode.password)
        XCTAssertThrowsError(try Aezeed.decode(unicode.phrase, passphrase: unicode.password.decomposedStringWithCompatibilityMapping))
        let unsupported = try vectors[3]
        XCTAssertThrowsError(try Aezeed.decode(unsupported.phrase)) { error in
            XCTAssertEqual(error as? AezeedError, .unsupportedVersion)
        }
    }
    func testEncryptedLocalMaterialRoundTrip() throws {
        let decoded = try Aezeed.decode(protected, passphrase: password)
        XCTAssertEqual(try JSONDecoder().decode(AezeedMaterial.self, from: JSONEncoder().encode(decoded)), decoded)
    }
}
