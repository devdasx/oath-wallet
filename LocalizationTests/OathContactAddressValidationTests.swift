import XCTest
@testable import OathAtmosphere

final class OathContactAddressValidationTests: XCTestCase {
    func testDerivedAddressesAreAcceptedOnEverySupportedNetwork() throws {
        let profile = try OathWalletEngine.profile(for: OathWalletEngine.create())
        for address in profile.addresses {
            XCTAssertTrue(OathContactAddressValidator.isValid(address.address, networkID: address.chain.id), address.chain.id)
        }
    }

    func testSelectedNetworkAndChecksumAreEnforced() {
        let ethereum = "0x5AAeb6053F3E94C9b9A09f33669435E7Ef1BeAed"
        // EIP-55's canonical mixed-case vector, plus one corrupted case.
        let checksummed = "0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed"
        XCTAssertTrue(OathContactAddressValidator.isValid(checksummed, networkID: "ethereum"))
        XCTAssertTrue(OathContactAddressValidator.isValid(checksummed.lowercased(), networkID: "base"))
        XCTAssertFalse(OathContactAddressValidator.isValid(ethereum, networkID: "ethereum"))
        XCTAssertFalse(OathContactAddressValidator.isValid(checksummed, networkID: "bitcoin"))
        XCTAssertFalse(OathContactAddressValidator.isValid(checksummed, networkID: "unknown"))
    }

    func testNearNamesAndImplicitAccountsUseAccountIDRules() {
        for value in ["alice.near", "app.alice.near", "max_99.near", "ek-2", String(repeating: "a", count: 64)] {
            XCTAssertTrue(OathContactAddressValidator.isValid(value, networkID: "near"))
        }
        for value in ["system", "a", "Alice.near", "a..near", "near.", "_near", "name-_near", "a@near", String(repeating: "a", count: 65)] {
            XCTAssertFalse(OathContactAddressValidator.isValid(value, networkID: "near"))
        }
    }

    func testWhitespaceURIsAndHiddenDirectionCharactersAreNotSavedAsAddresses() {
        let address = "0x0123456789abcdef0123456789abcdef01234567"
        XCTAssertTrue(OathContactAddressValidator.isValid(" \n" + address + "\n", networkID: "ethereum"))
        for invalid in ["ethereum:" + address, "https://example.com/" + address, address + "\u{202E}", address + " word", ""] {
            XCTAssertFalse(OathContactAddressValidator.isValid(invalid, networkID: "ethereum"))
        }
    }
}
