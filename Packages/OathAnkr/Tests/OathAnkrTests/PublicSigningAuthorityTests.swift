import Foundation
import XCTest
@testable import OathAnkr

final class PublicSigningAuthorityTests: XCTestCase {
    typealias Checker = PublicSigningAuthority
    typealias J = SolanaJSON
    func json(_ value: String) throws -> J { try JSONDecoder().decode(J.self, from: Data(value.utf8)) }

    func testTronSingleReplacementKeyIsDetectedWithoutCallingItMultisig() throws {
        let owner = PublicMultisigTests.tron
        let value = try json("""
        {"address":"\(owner)","owner_permission":{"threshold":1,"keys":[{"address":"T9yD14Nj9j7xAB4dbGeiX9h8unkKHxuWwb","weight":1}]}}
        """)
        let result = try Checker.accountPolicy(value, account: .init(chain: .tron, address: owner))
        XCTAssertEqual(result.findings, [.differentSigner, .restricted])
    }
    func testTronThresholdIsComparedToWeightAndZeroOperationActiveIsIgnored() throws {
        let owner = PublicMultisigTests.tron
        for active in [false, true] {
            let policy = """
            {"type":\(active ? 2 : 0),"id":\(active ? 2 : 0),"threshold":2,"operations":"\(active ? String(repeating: "0", count: 64) : "")","keys":[{"address":"\(owner)","weight":1},{"address":"T9yD14Nj9j7xAB4dbGeiX9h8unkKHxuWwb","weight":1}]}
            """
            let value = try json("{\"address\":\"\(owner)\",\"\(active ? "active_permission" : "owner_permission")\":\(active ? "[" + policy + "]" : policy)}")
            let result = try Checker.accountPolicy(value, account: .init(chain: .tron, address: owner))
            XCTAssertEqual(result.findings.contains(.multisig), !active)
            XCTAssertEqual(result.findings.contains(.restricted), !active)
        }
    }
    func testXRPRegularKeyAndDisabledMasterWithNoSignerList() throws {
        let value = try json("""
        {"result":{"status":"success","validated":true,"account_data":{"Account":"\(PublicMultisigTests.xrp)","Flags":1048576,"RegularKey":"\(PublicMultisigTests.signer)"},"signer_lists":[]}}
        """)
        XCTAssertEqual(try Checker.accountPolicy(value, account: .init(chain: .xrpl, address: PublicMultisigTests.xrp)).findings,
                       [.differentSigner, .restricted])
    }
    func testStellarDisabledMasterAndReplacementIsDifferentFromTwoSignatureThreshold() throws {
        for weight in [0, 1] {
            let value = try json("""
            {"account_id":"\(PublicMultisigTests.stellar)","thresholds":{"low_threshold":1,"med_threshold":\(weight == 0 ? 1 : 2),"high_threshold":\(weight == 0 ? 1 : 2)},"signers":[{"key":"\(PublicMultisigTests.stellar)","weight":\(weight),"type":"ed25519_public_key"},{"key":"GAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAWHF","weight":1,"type":"ed25519_public_key"}]}
            """)
            let result = try Checker.accountPolicy(value, account: .init(chain: .stellar, address: PublicMultisigTests.stellar))
            XCTAssertTrue(result.findings.contains(.differentSigner))
            XCTAssertTrue(result.findings.contains(.restricted))
            XCTAssertEqual(result.findings.contains(.multisig), weight == 1)
        }
    }
    func testNearMultipleIndependentKeysAreNotThresholdMultisig() throws {
        let own = Data(repeating: 1, count: 32), other = Data(repeating: 2, count: 32)
        func key(_ bytes: Data) -> J { .object(["public_key": .string("ed25519:" + SolanaSendCrypto.encode(bytes)),
                                              "access_key": .object(["permission": .string("FullAccess")])]) }
        let result = try Checker.nearPolicy(.object(["keys": .array([key(own), key(other)])]), address: TronSendCrypto.hex(own))
        XCTAssertEqual(result.findings, [.additionalSigners])
        let replaced = try Checker.nearPolicy(.object(["keys": .array([key(other)])]), address: TronSendCrypto.hex(own))
        XCTAssertEqual(replaced.findings, [.differentSigner, .restricted])
        XCTAssertThrowsError(try Checker.nearPolicy(.object(["keys": .array([key(own), key(own)])]), address: "fixture.near"))
    }
    func testSolanaProgramOwnerIsNotAutomaticallyMultisig() throws {
        let account: J = .object(["value": .object(["owner": .string(SolanaIdentity.tokenProgram), "executable": .bool(false),
            "data": .array([.string(Data(repeating: 0, count: 165).base64EncodedString()), .string("base64")])])])
        XCTAssertEqual(try Checker.solanaPolicy(account).findings, [.contractControlled])
        var data = Data(repeating: 0, count: 355); data[0] = 2; data[1] = 2; data[2] = 1
        data.replaceSubrange(3..<35, with: Data(repeating: 1, count: 32))
        data.replaceSubrange(35..<67, with: Data(repeating: 2, count: 32))
        func parsed(_ bytes: Data) throws -> PublicSigningAssessment {
            try Checker.solanaPolicy(.object(["value": .object(["owner": .string(SolanaIdentity.tokenProgram),
                "executable": .bool(false), "data": .array([.string(bytes.base64EncodedString()), .string("base64")])])]))
        }
        XCTAssertEqual(try parsed(data).findings, [.multisig])
        data[0] = 3
        XCTAssertThrowsError(try parsed(data))
    }
    func testSquadsDiscriminatorAndOptionalRentCollectorLayout() throws {
        for option: UInt8 in [0, 1] {
            let offset = 96 + (option == 1 ? 32 : 0)
            var bytes = Data(repeating: 0, count: offset + 4 + 66)
            // Anchor discriminator from the official account type.
            bytes.replaceSubrange(0..<8, with: [224, 116, 121, 186, 68, 161, 79, 236])
            bytes[72] = 2; bytes[94] = option; bytes[offset] = 2
            bytes[offset + 4] = 1; bytes[offset + 36] = 2
            bytes[offset + 37] = 2; bytes[offset + 69] = 2
            let result = try Checker.solanaPolicy(.object(["value": .object([
                "owner": .string("SQDS4ep65T869zMMBKyuUq6aD6EgTu8psMjkvj52pCf"), "executable": .bool(false),
                "data": .array([.string(bytes.base64EncodedString()), .string("base64")])])]))
            XCTAssertTrue(result.findings.contains(.multisig))
        }
    }
    func testSafeABIRejectsBadThresholdAndDuplicateOwners() throws {
        func word(_ n: Int) -> String { String(repeating: "0", count: 64 - String(n, radix: 16).count) + String(n, radix: 16) }
        let owners = "0x" + word(32) + word(2) + word(11) + word(22)
        XCTAssertEqual(try Checker.safePolicy(owners: .string(owners), threshold: .string("0x" + word(2))).findings, [.multisig])
        XCTAssertThrowsError(try Checker.safePolicy(owners: .string(owners), threshold: .string("0x" + word(3))))
        XCTAssertThrowsError(try Checker.safePolicy(owners: .string("0x" + word(32) + word(2) + word(11) + word(11)),
                                                   threshold: .string("0x" + word(1))))
    }
    func testUnknownAddressPoliciesStayUnknown() async throws {
        let transport = AuthorityTransport([])
        for network in ["bitcoin", "bitcoincash", "litecoin", "dogecoin", "ton", "sui", "future_chain"] {
            let result = try await Checker(transport: transport).check(.init(network: network, address: "public-fixture"))
            XCTAssertEqual(result.coverage, .notDiscoverable)
            XCTAssertTrue(result.findings.isEmpty)
        }
        let count = await transport.count
        XCTAssertEqual(count, 0)
    }
    func testEVMDelegationWrongChainAndOrdinaryContract() async throws {
        let address = "0x1111111111111111111111111111111111111111"
        func response(_ value: String) -> (Data, Int) { (Data("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":\"\(value)\"}".utf8), 200) }
        for code in ["0x", "0xef0100" + String(repeating: "11", count: 20), "0x6001600055"] {
            let transport = AuthorityTransport([response("0x1"), response("0x10"), response(code)])
            let result = try await Checker(transport: transport).check(.init(network: "eth", address: address))
            if code == "0x" { XCTAssertEqual(result.findings, []) }
            else if code.hasPrefix("0xef") { XCTAssertEqual(result.findings, [.delegatedCode]) }
            else { XCTAssertEqual(result.findings, [.contractControlled]); XCTAssertEqual(result.coverage, .notDiscoverable) }
        }
        let transport = AuthorityTransport([response("0x89")])
        let wrong = try await Checker(transport: transport).check(.init(network: "eth", address: address))
        XCTAssertEqual(wrong.coverage, .unavailable)
        let count = await transport.count; XCTAssertEqual(count, 1)
    }
    func testAptosAbsentResourceStillChecksRotatedAuthenticationKey() async throws {
        let transport = AuthorityTransport([
            (Data("{\"error_code\":\"resource_not_found\"}".utf8), 404),
            (Data("{\"authentication_key\":\"0x456\"}".utf8), 200)
        ])
        let result = try await Checker(transport: transport).check(.init(network: "aptos", address: "0x123"))
        XCTAssertEqual(result.findings, [.differentSigner])
    }
    func testCancellationNeverBecomesCompletedNegative() async {
        do {
            _ = try await Checker(transport: CancelledAuthorityTransport()).check(.init(network: "tron", address: PublicMultisigTests.tron))
            XCTFail("Cancellation must propagate")
        } catch { XCTAssertTrue(error is CancellationError) }
    }
    func testProviderFailuresAreUnavailableNotSingleSigner() async throws {
        let result = try await Checker(transport: AuthorityTransport([(Data("{}".utf8), 503)]))
            .check(.init(network: "tron", address: PublicMultisigTests.tron))
        XCTAssertEqual(result.coverage, .unavailable)
        XCTAssertEqual(result.findings, [])
    }
    func testAllCurrentEVMMainnetsHaveAnAdapter() {
        XCTAssertEqual(Set(Checker.evmEndpoints.keys),
                       Set(EVMSendNetwork.allCases.filter { !$0.isTestnet }.map(\.rawValue)).union(["arc"]))
    }
}
private actor AuthorityTransport: AnkrTransport {
    var responses: [(Data, Int)]; var count = 0
    init(_ responses: [(Data, Int)]) { self.responses = responses }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        count += 1
        guard !responses.isEmpty else { throw URLError(.badServerResponse) }
        return responses.removeFirst()
    }
}
private struct CancelledAuthorityTransport: AnkrTransport {
    func send(_ request: URLRequest) async throws -> (Data, Int) { throw CancellationError() }
}
