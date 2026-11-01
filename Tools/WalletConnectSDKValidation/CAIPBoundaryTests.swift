import XCTest
import WalletConnectUtils

final class CAIPBoundaryTests: XCTestCase {
    // Independent ASCII-byte oracle, including the SDK's existing TON address extension.
    private func valid(_ value: String, minimum: Int, maximum: Int, alphabet: String) -> Bool {
        let bytes = Array(value.utf8)
        return (minimum...maximum).contains(bytes.count) && bytes.allSatisfy { alphabet.utf8.contains($0) }
    }
    private let lower = "abcdefghijklmnopqrstuvwxyz0123456789-"
    private let reference = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_"
    private let address = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._%="
    private func expected(_ parts: [String]) -> Bool {
        valid(parts[0], minimum: 3, maximum: 8, alphabet: lower) &&
        valid(parts[1], minimum: 1, maximum: 32, alphabet: reference) &&
        (parts.count == 2 || valid(parts[2], minimum: 1, maximum: 128, alphabet: address))
    }

    func testSeparateFieldsCannotSupplyMissingChainComponent() {
        for (chain, account) in [("eip155", "1:synthetic"), ("cosmos", "cosmoshub-4:synthetic")] {
            XCTAssertNil(Blockchain(chain))
            XCTAssertNil(Account(chainIdentifier: chain, address: account), "Invalid chain must not borrow an address component")
        }
    }

    func testLineTerminatorsAreRejectedInEveryComponent() throws {
        for ending in ["\n", "\r", "\r\n", "\u{0085}", "\u{2028}", "\u{2029}"] {
            for count in [2, 3] {
                for index in 0..<count {
                    var parts = Array(["eip155", "1", "synthetic"].prefix(count)); parts[index] += ending
                    let value = parts.joined(separator: ":")
                    let encoded = try JSONEncoder().encode(value)
                    if count == 2 {
                        XCTAssertNil(Blockchain(value))
                        XCTAssertThrowsError(try JSONDecoder().decode(Blockchain.self, from: encoded))
                    } else {
                        XCTAssertNil(Account(value))
                        XCTAssertThrowsError(try JSONDecoder().decode(Account.self, from: encoded))
                    }
                }
            }
        }
    }

    func testComponentBoundsAndTONExtensionRoundTrip() throws {
        for namespace in ["abc", "abcdefgh"] {
            for ref in ["1", String(repeating: "R", count: 32)] {
                let chain = try XCTUnwrap(Blockchain(namespace: namespace, reference: ref))
                for addr in ["a", String(repeating: "a", count: 128), "Synthetic_TON-base64url==", "0.0.123-test", "synthetic%2Fvalue"] {
                    let value = try XCTUnwrap(Account(blockchain: chain, address: addr))
                    XCTAssertEqual(value.address, addr)
                    XCTAssertEqual(value.blockchain, chain)
                    XCTAssertEqual(value, Account(chainIdentifier: chain.absoluteString, address: addr))
                    XCTAssertEqual(try JSONDecoder().decode(Account.self, from: JSONEncoder().encode(value)), value)
                }
            }
        }
    }

    func testInvalidBoundsAndDelimiters() {
        for namespace in ["", "ab", String(repeating: "a", count: 9), "EIP155", "eip:155"] {
            XCTAssertNil(Blockchain(namespace: namespace, reference: "1"))
        }
        for ref in ["", String(repeating: "1", count: 33), "1:2"] {
            XCTAssertNil(Blockchain(namespace: "eip155", reference: ref))
        }
        let chain = Blockchain("eip155:1")!
        for addr in ["", String(repeating: "a", count: 129), "a:b", "a/b", "a\\b"] {
            XCTAssertNil(Account(blockchain: chain, address: addr))
            XCTAssertThrowsError(try Account(blockchain: chain, accountAddress: addr))
        }
    }

    func testEveryASCIIByteAndNonASCIIInputAgainstOracle() {
        let scalars = (0...127).map { String(UnicodeScalar($0)!) } + ["é", "e\u{0301}", "０", "α", "😀", "\u{200B}", "\u{202E}"]
        for scalar in scalars {
            for count in [2, 3] {
                for field in 0..<count {
                    for position in [0, 1, 3] {
                        var parts = Array(["abc", "123", "xyz"].prefix(count))
                        parts[field].insert(contentsOf: scalar, at: parts[field].index(parts[field].startIndex, offsetBy: position))
                        let input = parts.joined(separator: ":")
                        XCTAssertEqual(count == 2 ? Blockchain(input) != nil : Account(input) != nil, expected(parts))
                    }
                }
            }
        }
    }

    func testSeededBoundedCorpusAgainstOracle() {
        var state: UInt64 = 0xCA1F2026
        let alphabet = Array((lower + reference + address + ": \n\r\t" + "é😀").map(String.init))
        func next() -> UInt64 { state = state &* 6364136223846793005 &+ 1442695040888963407; return state }
        for iteration in 0..<4096 {
            let limits = [10, 34, 130]
            let parts = limits.map { limit in (0..<Int(next() % UInt64(limit))).map { _ in alphabet[Int(next() % UInt64(alphabet.count))] }.joined() }
            let chainParts = Array(parts.prefix(2))
            XCTAssertEqual(Blockchain(chainParts.joined(separator: ":")) != nil, expected(chainParts), "Chain corpus index \(iteration)")
            XCTAssertEqual(Account(parts.joined(separator: ":")) != nil, expected(parts), "Account corpus index \(iteration)")
            XCTAssertEqual(Account(chainIdentifier: chainParts.joined(separator: ":"), address: parts[2]) != nil, expected(parts), "Field corpus index \(iteration)")
        }
    }

    func testIdentityRemainsCaseSensitiveAndUntrimmed() throws {
        let a = try XCTUnwrap(Account("eip155:1:Synthetic"))
        let b = try XCTUnwrap(Account("eip155:1:synthetic"))
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(a.absoluteString, "eip155:1:Synthetic")
        XCTAssertNil(Account(" eip155:1:synthetic"))
        XCTAssertNil(Account("eip155:1:synthetic "))
        XCTAssertNil(Blockchain("eip155:1 "))
    }
}
