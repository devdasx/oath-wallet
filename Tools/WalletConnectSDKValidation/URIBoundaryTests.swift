import Foundation
import XCTest
import WalletConnectUtils

final class URIBoundaryTests: XCTestCase {
    private let topic = String(repeating: "a", count: 64)
    private let key = String(repeating: "b", count: 64)
    private var base: String { "wc:\(topic)@2?symKey=\(key)&relay-protocol=irn&expiryTimestamp=4102444800" }

    func testEncodedRelayDataCannotReplaceKey() throws {
        let payload = "%26symKey%3D" + String(repeating: "c", count: 64)
        let uri = try WalletConnectURI(uriString: base + "&relay-data=" + payload)
        XCTAssertEqual(uri.symKey, key)
        XCTAssertEqual(uri.relay.data, "&symKey=" + String(repeating: "c", count: 64))
    }

    func testNestedPercentEncodingRemainsData() throws {
        let uri = try WalletConnectURI(uriString: base + "&relay-data=%2526symKey%253Dliteral")
        XCTAssertEqual(uri.symKey, key)
        XCTAssertEqual(uri.relay.data, "%26symKey%3Dliteral")
    }

    func testReservedCharactersRoundTrip() throws {
        for value in ["a&symKey=other", "literal%26value", "a#fragment?query", "nested wc: text", "مرحبا", "a+b=c"] {
            let original = WalletConnectURI(topic: topic, symKey: key, relay: .init(protocol: "irn", data: value))
            let parsed = try WalletConnectURI(uriString: original.absoluteString)
            XCTAssertEqual(parsed, original, "Relay data must be a single query value")
        }
    }

    func testDuplicateFieldsAreRejected() {
        for extra in ["&symKey=other", "&sym%4Bey=other", "&relay-protocol=other", "&expiryTimestamp=4102444801"] {
            XCTAssertThrowsError(try WalletConnectURI(uriString: base + extra))
        }
    }

    func testPlainHierarchicalAndEncodedURICompatibility() throws {
        let expected = try WalletConnectURI(uriString: base)
        XCTAssertEqual(try WalletConnectURI(uriString: base.replacingOccurrences(of: "wc:", with: "wc://")), expected)
        let encoded = try XCTUnwrap(base.addingPercentEncoding(withAllowedCharacters: .alphanumerics))
        XCTAssertEqual(try WalletConnectURI(uriString: encoded), expected)
        XCTAssertEqual(try WalletConnectURI(uriString: expected.absoluteString), expected)
    }

    func testEncodedFullURIKeepsEncodedFieldBoundary() throws {
        let raw = base + "&relay-data=%26symKey%3Dother"
        let encoded = try XCTUnwrap(raw.addingPercentEncoding(withAllowedCharacters: .alphanumerics))
        let uri = try WalletConnectURI(uriString: encoded)
        XCTAssertEqual(uri.symKey, key)
        XCTAssertEqual(uri.relay.data, "&symKey=other")
    }

    func testExpiryAndMissingRequiredFieldsRemainRejected() {
        XCTAssertThrowsError(try WalletConnectURI(uriString: base.replacingOccurrences(of: "4102444800", with: "1")))
        XCTAssertThrowsError(try WalletConnectURI(uriString: "wc:\(topic)@2?relay-protocol=irn"))
        XCTAssertThrowsError(try WalletConnectURI(uriString: "wc:\(topic)@2?symKey=\(key)"))
    }

    func testLegacyMissingExpiryAndMethodsRemainCompatible() throws {
        let before = UInt64(Date().timeIntervalSince1970)
        let uri = try WalletConnectURI(uriString: "wc:\(topic)@2?symKey=\(key)&relay-protocol=irn&methods=wc_sessionPropose,wc_sessionAuthenticate")
        XCTAssertEqual(uri.methods, ["wc_sessionPropose", "wc_sessionAuthenticate"])
        XCTAssertGreaterThanOrEqual(uri.expiryTimestamp, before + 300)
        XCTAssertLessThanOrEqual(uri.expiryTimestamp, UInt64(Date().timeIntervalSince1970) + 300)
    }
}
