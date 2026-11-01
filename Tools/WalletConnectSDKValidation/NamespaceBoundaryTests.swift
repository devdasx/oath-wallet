import XCTest
@testable import Schemas
import WalletConnectNetworking

final class NamespaceBoundaryTests: XCTestCase {
    private let eth = Blockchain("eip155:1")!
    private let polygon = Blockchain("eip155:137")!
    private var ethAccount: Account { Account(blockchain: eth, address: "0x1111111111111111111111111111111111111111")! }
    private var polygonAccount: Account { Account(blockchain: polygon, address: "0x2222222222222222222222222222222222222222")! }
    private var metadata: AppMetadata {
        AppMetadata(name: "Synthetic", description: "Namespace fixture", url: "https://example.invalid", icons: [],
            redirect: try! AppMetadata.Redirect(native: "", universal: nil))
    }
    private func proposal(_ required: [String: ProposalNamespace], optional: [String: ProposalNamespace] = [:]) -> Session.Proposal {
        SessionProposal(relays: [], proposer: Participant(publicKey: "synthetic-peer", metadata: metadata),
            requiredNamespaces: required, optionalNamespaces: optional).publicRepresentation(pairingTopic: "synthetic-pairing")
    }
    private func session(required: [String: ProposalNamespace]) -> WCSession {
        let owner = Participant(publicKey: "synthetic-owner", metadata: metadata)
        let params = SessionType.SettleParams(relay: RelayProtocolOptions(protocol: "irn", data: nil), controller: owner,
            namespaces: ["eip155": SessionNamespace(accounts: [ethAccount], methods: ["personal_sign"], events: [])],
            sessionProperties: nil, scopedProperties: nil, expiry: Int64(Date().timeIntervalSince1970) + 86400, proposalRequestsResponses: nil)
        return WCSession(topic: "synthetic-session", pairingTopic: "synthetic-pairing", timestamp: Date(),
            selfParticipant: owner, peerParticipant: Participant(publicKey: "synthetic-peer", metadata: metadata),
            settleParams: params, requiredNamespaces: required, acknowledged: true, transportType: .relay, verifyContext: nil)
    }
    private var qualified: [String: ProposalNamespace] {
        ["eip155:1": ProposalNamespace(methods: ["personal_sign"], events: [])]
    }
    private var approval: SessionNamespace {
        SessionNamespace(accounts: [ethAccount], methods: ["personal_sign"], events: [])
    }

    func testMalformedQualifiedKeysAreRejected() {
        for key in ["eip155:", ":1", "eip155:1:2", "EIP155:1", "eip155:bad space"] {
            XCTAssertThrowsError(try Namespace.validate([key: ProposalNamespace(methods: [], events: [])]), "Malformed qualified key must throw")
        }
    }
    func testMalformedApprovalDoesNotTrap() {
        XCTAssertThrowsError(try Namespace.validateApproved(["eip155": approval], against:
            ["eip155:": ProposalNamespace(methods: [], events: [])]), "Malformed approval requirement must throw")
    }
    func testQualifiedSessionUpdateDoesNotTrap() throws {
        var value = session(required: qualified)
        try value.updateNamespaces(["eip155:1": approval])
        XCTAssertEqual(value.namespaces, ["eip155:1": approval])
    }
    func testQualifiedRequirementAcceptsBaseSessionUpdate() throws {
        var value = session(required: qualified)
        try value.updateNamespaces(["eip155": approval])
        XCTAssertEqual(value.namespaces, ["eip155": approval])
    }
    func testQualifiedApprovalPreservesChainSpecificPermissions() throws {
        let required = ["eip155:1": ProposalNamespace(methods: ["personal_sign"], events: []),
                        "eip155:137": ProposalNamespace(methods: ["eth_sendTransaction"], events: [])]
        let approved = ["eip155:1": approval,
                        "eip155:137": SessionNamespace(accounts: [polygonAccount], methods: ["eth_sendTransaction"], events: [])]
        try Namespace.validateApproved(approved, against: required)
    }
    func testMixedRequirementsCannotBeLostByDictionaryOrder() {
        var acceptedIncomplete = false
        var coveredQualifiedFirst = false
        for capacity in [4, 16, 64, 256] {
        for reference in 2...129 {
            let chain = Blockchain("eip155:\(reference)")!
            var required: [String: ProposalNamespace] = [:]
            required.reserveCapacity(capacity)
            required["eip155"] = ProposalNamespace(chains: [eth], methods: ["personal_sign"], events: [])
            required[chain.absoluteString] = ProposalNamespace(methods: ["eth_sendTransaction"], events: ["chainChanged"])
            if required.keys.first == chain.absoluteString { coveredQualifiedFirst = true }
            if (try? Namespace.validateApproved(["eip155": approval], against: required)) != nil { acceptedIncomplete = true }
        }
        }
        XCTAssertTrue(coveredQualifiedFirst, "Fixture must exercise qualified-before-base ordering")
        XCTAssertFalse(acceptedIncomplete, "Mixed requirements must never disappear")
    }
    func testPermissionsOnAnotherChainCannotSatisfyRequirement() {
        let approved = ["eip155:1": SessionNamespace(accounts: [ethAccount], methods: [], events: []),
                        "eip155:137": SessionNamespace(accounts: [polygonAccount], methods: ["personal_sign"], events: [])]
        XCTAssertThrowsError(try Namespace.validateApproved(approved, against: qualified))
    }
    func testInvalidUpdatePreservesEntireSession() {
        var value = session(required: [:]); let original = value
        XCTAssertThrowsError(try value.updateNamespaces(["cosmos": approval]), "Mismatched update accounts must throw")
        XCTAssertEqual(value, original, "Rejected namespace update must preserve session")
    }
    func testBuilderRequiresAnAccountForEveryRequiredChain() {
        let required = ["eip155": ProposalNamespace(chains: [eth, polygon], methods: ["personal_sign"], events: [])]
        XCTAssertThrowsError(try AutoNamespaces.build(sessionProposal: proposal(required), chains: [eth, polygon],
            methods: ["personal_sign"], events: [], accounts: [ethAccount]), "Every required chain needs an account")
    }
    func testOptionalChainsWithoutAccountsAreNotAdvertised() throws {
        let result = try AutoNamespaces.build(sessionProposal: proposal(qualified,
            optional: ["eip155": ProposalNamespace(chains: [polygon], methods: ["personal_sign"], events: [])]),
            chains: [eth, polygon], methods: ["personal_sign"], events: [], accounts: [ethAccount])
        XCTAssertEqual(result["eip155"]?.chains, [eth], "Unusable optional chain must be omitted")
    }
    func testBuilderRejectsMalformedRequiredKey() {
        XCTAssertThrowsError(try AutoNamespaces.build(sessionProposal: proposal([
            "eip155:1:1": ProposalNamespace(methods: ["personal_sign"], events: [])]),
            chains: [eth], methods: ["personal_sign"], events: [], accounts: [ethAccount]),
            "Malformed required key must not be reinterpreted")
    }
    func testBuilderOmitsMalformedOptionalKey() throws {
        let result = try AutoNamespaces.build(sessionProposal: proposal(qualified, optional: [
            "eip155:137:137": ProposalNamespace(methods: ["eth_sendTransaction"], events: [])]),
            chains: [eth, polygon], methods: ["personal_sign", "eth_sendTransaction"], events: [], accounts: [ethAccount, polygonAccount])
        XCTAssertEqual(result["eip155"]?.chains, [eth], "Malformed optional chain must not be reinterpreted")
        XCTAssertEqual(result["eip155"]?.methods, ["personal_sign"], "Malformed optional methods must not be granted")
    }
    func testBaseApprovalAndPermissionSupersetRemainValid() throws {
        let required = ["eip155": ProposalNamespace(chains: [eth], methods: ["personal_sign"], events: [])]
        let approved = ["eip155": SessionNamespace(accounts: [ethAccount, polygonAccount], methods: ["personal_sign", "eth_sendTransaction"], events: ["chainChanged"])]
        try Namespace.validateApproved(approved, against: required)
    }
    func testRejectedRequiredPermissionRemovalPreservesState() {
        var value = session(required: ["eip155": ProposalNamespace(chains: [eth], methods: ["personal_sign"], events: [])])
        let original = value
        XCTAssertThrowsError(try value.updateNamespaces(["eip155": SessionNamespace(accounts: [ethAccount], methods: [], events: [])]))
        XCTAssertEqual(value, original)
    }
    func testValidBuilderSatisfiesCompleteMixedRequirements() throws {
        let required = ["eip155": ProposalNamespace(chains: [eth], methods: ["personal_sign"], events: []),
                        "eip155:137": ProposalNamespace(methods: ["eth_sendTransaction"], events: ["chainChanged"])]
        let result = try AutoNamespaces.build(sessionProposal: proposal(required), chains: [eth, polygon],
            methods: ["personal_sign", "eth_sendTransaction"], events: ["chainChanged"], accounts: [ethAccount, polygonAccount])
        try Namespace.validateApproved(result, against: required)
        XCTAssertEqual(Set(result["eip155"]?.accounts ?? []), Set([ethAccount, polygonAccount]))
    }
}
