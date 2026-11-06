import Foundation
import XCTest
@testable import OathAnkr

final class TokenDiscoverySnapshotTests: XCTestCase {
    func testEveryShippingIdentityIsCanonicalAndUnique() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        struct Snapshot: Decodable { let format: Int; let entries: [TokenDiscoveryEntry] }
        let data = try Data(contentsOf: root.appendingPathComponent("Sources/OathAnkr/Resources/TokenDiscoverySeed.json"))
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
        XCTAssertEqual(snapshot.format, 1)
        XCTAssertFalse(snapshot.entries.isEmpty)
        var identities = Set<String>()
        for entry in snapshot.entries {
            if TokenDiscoveryNetworks.isNativeRepresentation(entry.reference, network: entry.network) {
                XCTAssertEqual(try TokenDiscoveryNetworks.canonical(entry.reference, network: entry.network), "native")
                continue // The released prepared-snapshot reader deliberately removes these aliases.
            }
            XCTAssertEqual(try TokenDiscoveryNetworks.canonical(entry.reference, network: entry.network), entry.reference, entry.id)
            XCTAssertTrue(identities.insert(entry.id).inserted, entry.id)
            XCTAssertFalse(TokenDiscoveryNetworks.nativeOnly.contains(entry.network))
            XCTAssertNotEqual(entry.reference, "native")
        }
    }
}
