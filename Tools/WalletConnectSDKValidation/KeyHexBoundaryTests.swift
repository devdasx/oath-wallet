import XCTest
import CryptoKit
@testable import WalletConnectKMS
import WalletConnectUtils

final class KeyHexBoundaryTests: XCTestCase {
    private let bytes = Data(repeating: 0x42, count: 32)
    private var validHex: String { bytes.toHexString() }
    private var invalidHex: [String] {
        [String(validHex.dropLast()), String(validHex.dropLast()) + "g",
         "0x" + validHex + "0", String(repeating: "４", count: 64),
         String(validHex.dropLast()) + "\0"]
    }

    func testMalformedLowNibblesDoNotBecomeBytes() {
        for hex in ["ag", "0xag", "a?", "12ag", "12a ", "12a\0"] {
            XCTAssertTrue(Data(hex: hex).isEmpty)
        }
    }

    func testOddHexDigitCountsFailClosed() {
        for length in [1, 3, 39, 63, 65, 127] {
            XCTAssertTrue(Data(hex: String(repeating: "a", count: length)).isEmpty)
        }
    }

    func testEveryASCIIInvalidLowNibbleFailsClosed() {
        let allowed = Set("0123456789abcdefABCDEF".utf8)
        for byte in UInt8(0)...UInt8(127) where !allowed.contains(byte) {
            XCTAssertTrue(Data(hex: "a" + String(UnicodeScalar(byte))).isEmpty, "Invalid ASCII nibble")
        }
    }

    func testKnownBytesRoundTripWithoutCoercion() {
        let data = Data((0...255).map(UInt8.init))
        XCTAssertEqual(Data(hex: data.toHexString()), data)
        XCTAssertEqual(Data(hex: "0x" + data.toHexString().uppercased()), data)
        XCTAssertTrue(Data(hex: "").isEmpty)
    }

    func testNonASCIIHexIsRejected() {
        for value in [String(repeating: "Ａ", count: 64), String(repeating: "é", count: 64), "aé", "a\u{200b}"] {
            XCTAssertTrue(Data(hex: value).isEmpty)
        }
    }

    func testAgreementPublicKeyRejectsMalformedHex() {
        for hex in invalidHex { XCTAssertThrowsError(try AgreementPublicKey(hex: hex)) }
    }

    func testAgreementPrivateKeyRejectsMalformedHex() {
        for hex in invalidHex { XCTAssertThrowsError(try AgreementPrivateKey(hex: hex)) }
    }

    func testSigningPublicKeyRejectsMalformedHex() {
        for hex in invalidHex { XCTAssertThrowsError(try SigningPublicKey(hex: hex)) }
    }

    func testSymmetricKeyRejectsMalformedHex() {
        for hex in invalidHex + ["", "gg", String(repeating: "42", count: 16)] {
            XCTAssertThrowsError(try WalletConnectKMS.SymmetricKey(hex: hex))
        }
    }

    func testSymmetricRawKeyRequires32Bytes() {
        for length in [0, 1, 16, 24, 31, 33, 64] {
            XCTAssertThrowsError(try WalletConnectKMS.SymmetricKey(rawRepresentation: Data(repeating: 0x42, count: length)))
        }
    }

    func testCryptoKitKeyWrapperRequires256Bits() {
        for length in [0, 1, 16, 24, 31, 33, 64] {
            XCTAssertThrowsError(try WalletConnectKMS.SymmetricKey(key: CryptoKit.SymmetricKey(data: Data(repeating: 0x42, count: length))))
        }
    }

    func testValidKeyConstructorsPreserveExactBytes() throws {
        XCTAssertEqual(try AgreementPublicKey(hex: validHex).rawRepresentation, bytes)
        XCTAssertEqual(try AgreementPrivateKey(hex: validHex).rawRepresentation, bytes)
        XCTAssertEqual(try SigningPublicKey(hex: validHex).rawRepresentation, bytes)
        XCTAssertEqual(try WalletConnectKMS.SymmetricKey(hex: validHex).rawRepresentation, bytes)
        XCTAssertEqual(try WalletConnectKMS.SymmetricKey(key: CryptoKit.SymmetricKey(data: bytes)).rawRepresentation, bytes)
        XCTAssertEqual(try WalletConnectKMS.SymmetricKey(hex: "0x" + validHex).rawRepresentation, bytes)
    }

    func testAgreementRejectsMalformedPeerKey() throws {
        let own = try AgreementPrivateKey(rawRepresentation: bytes)
        // RFC 7748 base point, with an invalid low nibble in the final byte.
        let malformed = "09" + String(repeating: "00", count: 30) + "0g"
        XCTAssertThrowsError(try KeyManagementService.generateAgreementKey(from: own, peerPublicKey: malformed))
    }

    func testValidAgreementMatchesCryptoKitAndRestoresRecord() throws {
        let own = try AgreementPrivateKey(rawRepresentation: bytes)
        let peerBytes = Data([9] + Array(repeating: 0, count: 31))
        let result = try KeyManagementService.generateAgreementKey(from: own, peerPublicKey: peerBytes.toHexString())
        let secret = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: bytes)
            .sharedSecretFromKeyAgreement(with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerBytes))
        let expected = secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(), sharedInfo: Data(), outputByteCount: 32)
        XCTAssertEqual(result.sharedKey.rawRepresentation, expected.withUnsafeBytes { Data($0) })
        // Independently generated using Node 26.5.0/OpenSSL X25519 and HKDF-SHA256.
        XCTAssertEqual(result.sharedKey.rawRepresentation, Data([23, 175, 168, 47, 243, 150, 190, 177, 62, 31, 108, 254, 107, 18, 110, 246, 169, 3, 97, 28, 210, 199, 163, 45, 201, 56, 99, 151, 166, 89, 209, 37]))
        XCTAssertEqual(result.sharedKey.rawRepresentation.count, 32)
        XCTAssertEqual(try AgreementKeys(rawRepresentation: result.rawRepresentation), result)
        XCTAssertEqual(result.rawRepresentation.count, 64)
    }

    func testAgreementRecordsKeepTheirSizeBoundary() {
        for length in [0, 1, 32, 63, 65, 128] {
            XCTAssertThrowsError(try AgreementKeys(rawRepresentation: Data(repeating: 0x42, count: length)))
        }
    }
}
