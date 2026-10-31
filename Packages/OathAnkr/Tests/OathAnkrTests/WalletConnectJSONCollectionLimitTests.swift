import Foundation
import XCTest
@testable import OathAnkr

final class WalletConnectJSONCollectionLimitTests: XCTestCase {
    func testObjectAndArrayBoundsAreSymmetric() throws {
        for limit in [1, 2, 16, 1024] {
            let members = (0..<limit).map { "\"k\($0)\":0" }.joined(separator: ",")
            XCTAssertNoThrow(try WalletConnectJSON.decode(Data("{\(members)}".utf8), collectionLimit: limit))
            XCTAssertThrowsError(try WalletConnectJSON.decode(Data("{\(members),\"overflow\":0}".utf8), collectionLimit: limit))
            let elements = Array(repeating: "0", count: limit).joined(separator: ",")
            XCTAssertNoThrow(try WalletConnectJSON.decode(Data("[\(elements)]".utf8), collectionLimit: limit))
            XCTAssertThrowsError(try WalletConnectJSON.decode(Data("[\(elements),0]".utf8), collectionLimit: limit))
        }
    }

    func testNestedObjectsRetainIndividualLimits() throws {
        XCTAssertNoThrow(try WalletConnectJSON.decode(Data("{\"a\":{\"b\":0}}".utf8), collectionLimit: 1))
        XCTAssertThrowsError(try WalletConnectJSON.decode(Data("{\"a\":{\"b\":0,\"c\":0}}".utf8), collectionLimit: 1))
        XCTAssertNoThrow(try WalletConnectJSON.decode(Data("{}".utf8), collectionLimit: 0))
        XCTAssertThrowsError(try WalletConnectJSON.decode(Data("{\"a\":0}".utf8), collectionLimit: 0))
    }
}
