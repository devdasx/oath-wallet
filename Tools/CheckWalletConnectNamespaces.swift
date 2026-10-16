import Foundation
import XCTest
@testable import WalletConnectSign
import OathAnkr

/// Tests the exact policy used by consent and approval, and the SDK's own
/// required-namespace validator. All identities are synthetic public fixtures.
final class WalletConnectNamespaceTests: XCTestCase {
    private let address = "0x0000000000000000000000000000000000000001"
    private let arc = "eip155:5042"
    private let thor = ThorchainWalletConnectRequest.blockchain
    private let transaction: Set<String> = ["eth_sendTransaction", "personal_sign"]

    private func account(_ chain: String) -> Account {
        Account(blockchain: Blockchain(chain)!, address: address)!
    }
    private func namespace(_ chains: [String]?, _ methods: Set<String>, events: Set<String> = []) -> ProposalNamespace {
        .init(chains: chains?.map { Blockchain($0)! }, methods: methods, events: events)
    }
    private func proposal(_ required: [String: ProposalNamespace] = [:], optional: [String: ProposalNamespace] = [:]) -> Session.Proposal {
        let metadata = AppMetadata(name: "Namespace regression", description: "Public host fixture",
                                   url: "https://example.org", icons: [],
                                   redirect: try! .init(native: "namespace-test://", universal: nil))
        return .init(id: "fixture", pairingTopic: "fixture", proposer: metadata,
            requiredNamespaces: required, optionalNamespaces: optional, sessionProperties: nil,
            scopedProperties: nil, proposal: .init(relays: [], proposer: .init(publicKey: "", metadata: metadata),
                requiredNamespaces: required, optionalNamespaces: optional), requests: nil)
    }
    private func build(_ input: Session.Proposal, _ chains: [String]) throws -> [String: SessionNamespace] {
        let result = try OathWalletConnectPolicy.namespaces(for: input, accounts: chains.map(account))
        try Namespace.validate(result)
        try Namespace.validateApproved(result, against: input.requiredNamespaces)
        return result
    }

    func testSolanaMainnetDevnetTestnetAndMixedNamespaces() throws {
        let owner = try SolanaSendCrypto.address(privateKey: Data(repeating: 1, count: 32))
        let chains = [SolanaSendNetwork.mainnet, .devnet, .testnet].map(\.walletConnectChain)
        let accounts = chains.map { Account(blockchain: Blockchain($0)!, address: owner)! }
        let input = proposal(["solana": namespace(chains, WalletConnectSolanaRequest.signingMethods, events: ["accountsChanged", "chainChanged"])], optional: ["eip155": namespace(["eip155:1"], transaction)])
        let result = try OathWalletConnectPolicy.namespaces(for: input, accounts: accounts + [account("eip155:1")])
        try Namespace.validateApproved(result, against: input.requiredNamespaces)
        XCTAssertEqual(Set(result["solana"]?.accounts ?? []), Set(accounts))
        XCTAssertEqual(result["solana"]?.methods, WalletConnectSolanaRequest.signingMethods)
        XCTAssertFalse(result["eip155"]!.methods.contains("solana_signTransaction"))
        XCTAssertThrowsError(try OathWalletConnectPolicy.namespaces(for: input, accounts: [accounts[0]]))
        let devnetOnly = proposal(["solana": namespace([chains[1]], ["solana_signTransaction"])])
        let devnet = try OathWalletConnectPolicy.namespaces(for: devnetOnly, accounts: [accounts[1]])
        XCTAssertEqual(Set(devnet["solana"]!.accounts.map { $0.blockchain.absoluteString }), [chains[1]])
        if let path = ProcessInfo.processInfo.environment["OATH_NAMESPACE_FIXTURE"] {
            try JSONEncoder().encode(["all": result, "devnet": devnet]).write(to: URL(fileURLWithPath: path + ".solana"))
        }
    }
    func testUniswapOptionalEthereumAndArcKeepTransactionPermission() throws {
        let input = proposal(optional: ["eip155": namespace(["eip155:1", "eip155:42161", arc], transaction)])
        let result = try build(input, ["eip155:1", "eip155:42161", arc])
        XCTAssertTrue(result["eip155"]!.methods.contains("eth_sendTransaction"))
        XCTAssertEqual(Set(result["eip155"]!.accounts.map { $0.blockchain.absoluteString }), ["eip155:1", "eip155:42161"])
        XCTAssertFalse(result["eip155"]!.chains!.contains(Blockchain(arc)!))
    }
    func testOriginalDowngradeReproducedAndFixedForBrowserValidator() throws {
        let chains = ["eip155:1", "eip155:42161", arc]
        let accounts = chains.map(account)
        let input = proposal(optional: ["eip155": namespace(chains, transaction)])
        // Reproduce the original service's global downgrade whenever any
        // approved EVM chain lacks a transaction adapter (Arc in this fixture).
        var legacyMethods = OathWalletConnectPolicy.methods
        if accounts.contains(where: { !OathWalletConnectPolicy.transactionChains.contains($0.blockchain.absoluteString) }) {
            legacyMethods.remove("eth_sendTransaction")
        }
        let legacy = try AutoNamespaces.build(sessionProposal: input,
            chains: accounts.map(\.blockchain), methods: Array(legacyMethods), events: [], accounts: accounts)
        XCTAssertFalse(legacy["eip155"]!.methods.contains("eth_sendTransaction"))
        let fixed = try build(input, chains)
        XCTAssertTrue(fixed["eip155"]!.methods.contains("eth_sendTransaction"))
        // Public synthetic sessions only. The JS check uses the exact browser
        // validator that rejected Uniswap's request before it reached Oath.
        if let path = ProcessInfo.processInfo.environment["OATH_NAMESPACE_FIXTURE"] {
            try JSONEncoder().encode(["legacy": legacy, "fixed": fixed]).write(to: URL(fileURLWithPath: path))
        }
    }
    func testRequiredEthereumTransactionSurvivesOptionalUnsupportedChain() throws {
        let input = proposal(["eip155": namespace(["eip155:1"], transaction)],
            optional: ["eip155": namespace([arc, "eip155:8453"], transaction)])
        let result = try build(input, ["eip155:1", arc, "eip155:8453"])
        XCTAssertTrue(result["eip155"]!.methods.contains("eth_sendTransaction"))
        XCTAssertEqual(result["eip155"]!.accounts.count, 2)
    }
    func testRequiredUnsupportedChainFailsInsteadOfDowngradingEthereum() {
        let input = proposal(["eip155": namespace(["eip155:1", arc], transaction)])
        XCTAssertThrowsError(try build(input, ["eip155:1", arc]))
    }
    func testChainQualifiedRequiredAndOptionalNamespaces() throws {
        let input = proposal(["eip155:1": namespace(nil, transaction)],
            optional: [arc: namespace(nil, transaction), "eip155:42161": namespace(nil, transaction)])
        let result = try build(input, ["eip155:1", "eip155:42161", arc])
        XCTAssertEqual(Set(result["eip155"]!.accounts.map { $0.blockchain.absoluteString }), ["eip155:1", "eip155:42161"])
        XCTAssertTrue(result["eip155"]!.methods.contains("eth_sendTransaction"))
    }
    func testEverySupportedEVMNetworkRetainsTransactionsInMixedProposal() throws {
        for chain in OathWalletConnectPolicy.transactionChains {
            let input = proposal(optional: ["eip155": namespace([chain, arc], transaction)])
            let result = try build(input, [chain, arc])
            XCTAssertEqual(result["eip155"]!.accounts, [account(chain)])
            XCTAssertTrue(result["eip155"]!.methods.contains("eth_sendTransaction"), chain)
        }
    }
    func testUnselectedOrUnownedNetworksAreNeverGranted() throws {
        let input = proposal(optional: ["eip155": namespace(["eip155:1", "eip155:42161"], transaction)])
        let result = try build(input, ["eip155:1"])
        XCTAssertEqual(result["eip155"]!.accounts, [account("eip155:1")])
        XCTAssertThrowsError(try build(proposal(["eip155": namespace(["eip155:42161"], transaction)]), ["eip155:1"]))
    }
    func testNoTransactionPermissionAddedToMessageOnlyProposal() throws {
        let input = proposal(["eip155": namespace(["eip155:1"], ["personal_sign"])])
        XCTAssertEqual(try build(input, ["eip155:1"])["eip155"]!.methods, ["personal_sign"])
    }
    func testUnsupportedRequiredMethodsAndEventsFail() {
        for method in ["wallet_sendCalls", "wallet_addEthereumChain", "eth_sign", "cosmos_signDirect"] {
            XCTAssertThrowsError(try build(proposal(["eip155": namespace(["eip155:1"], [method])]), ["eip155:1"]))
        }
        XCTAssertThrowsError(try build(proposal(["eip155": namespace(["eip155:1"], transaction, events: ["unknown"])]), ["eip155:1"]))
    }
    func testCosmosAndEVMMethodsNeverCrossNamespaces() throws {
        let all = transaction.union(ThorchainWalletConnectRequest.methods)
        let input = proposal(optional: ["eip155": namespace(["eip155:1", arc], all),
            "cosmos": namespace([thor], all, events: ["chainChanged"])])
        let result = try build(input, ["eip155:1", arc, thor])
        XCTAssertEqual(result["eip155"]!.methods, transaction)
        XCTAssertEqual(result["cosmos"]!.methods, ThorchainWalletConnectRequest.methods)
        XCTAssertTrue(result["cosmos"]!.events.isEmpty)
    }
    func testUnsupportedOnlyAndUnimplementedOptionalMethodsDoNotCreateEmptyConnection() {
        XCTAssertThrowsError(try build(proposal(optional: ["eip155": namespace([arc], transaction)]), [arc]))
        XCTAssertThrowsError(try build(proposal(optional: ["eip155": namespace(["eip155:1"], ["wallet_sendCalls"])]), ["eip155:1"]))
        XCTAssertThrowsError(try build(proposal(optional: ["eip155": namespace(["eip155:1"], ["cosmos_signDirect"])]), ["eip155:1"]))
    }
    func testOnlyImplementedMainnetConnectionsAreOffered() {
        XCTAssertFalse(OathWalletConnectPolicy.supportsConnection(arc))
        XCTAssertFalse(OathWalletConnectPolicy.supportsConnection("eip155:11155111"))
        XCTAssertFalse(OathWalletConnectPolicy.supportsConnection("eip155:999999999"))
        XCTAssertFalse(OathWalletConnectPolicy.supportsConnection("eip155:01"))
        XCTAssertTrue(OathWalletConnectPolicy.supportsConnection(thor))
        XCTAssertFalse(OathWalletConnectPolicy.supportsConnection("cosmos:cosmoshub-4"))
    }

    func testPolygonAuthenticationMethodsSurviveMixedChainProposal() throws {
        let authentication: Set<String> = ["personal_sign", "eth_signTypedData_v4", "eth_accounts", "eth_requestAccounts", "eth_chainId", "wallet_switchEthereumChain"]
        let input = proposal(["eip155": namespace(["eip155:137"], authentication)],
            optional: ["eip155": namespace(["eip155:1", arc], authentication)])
        let result = try build(input, ["eip155:137", "eip155:1", arc])
        XCTAssertEqual(result["eip155"]!.methods, authentication)
        XCTAssertEqual(Set(result["eip155"]!.accounts.map { $0.blockchain.absoluteString }), ["eip155:137", "eip155:1"])
        XCTAssertFalse(result["eip155"]!.methods.contains("eth_sendTransaction"))
    }

    func testFirstAuthenticationRequestCanArriveBeforeOrAfterApprovalCommits() {
        typealias Presentation = OathWalletConnectPolicy.RequestPresentation
        let topic = "synthetic-approved-peer"
        // Settlement can publish requests before the local wallet association
        // is committed. Both reads and consent must wait at that boundary.
        let requests = ["eth_accounts", "eth_chainId", "personal_sign", "eth_signTypedData_v4"]
        for method in requests {
            let needsApproval = OathWalletConnectPolicy.approvalMethods.contains(method)
            XCTAssertTrue(Presentation.committingConnection.defersRequest(topic: topic, requiresApproval: needsApproval))
            // Replay after ownership commits, with the Connected sheet still
            // open. The old blanket connectedTopic check stalled this step.
            XCTAssertFalse(Presentation.connected(topic: topic).defersRequest(topic: topic, requiresApproval: needsApproval))
        }
    }

    func testConnectedPageHandsOffEverySupportedApprovalMethodToSamePeerOnly() {
        let connected = OathWalletConnectPolicy.RequestPresentation.connected(topic: "approved-peer")
        for method in OathWalletConnectPolicy.approvalMethods {
            XCTAssertFalse(connected.defersRequest(topic: "approved-peer", requiresApproval: true), method)
            XCTAssertTrue(connected.defersRequest(topic: "another-peer", requiresApproval: true), method)
        }
    }

    func testActiveConsentAndResultsCannotBeReplacedByFollowingRequests() {
        for state in [OathWalletConnectPolicy.RequestPresentation.reviewing, .completed] {
            for topic in ["approved-peer", "another-peer"] {
                XCTAssertTrue(state.defersRequest(topic: topic, requiresApproval: true))
                // Non-signing discovery remains available. It neither changes
                // the current review nor gives a dApp a signature.
                XCTAssertFalse(state.defersRequest(topic: topic, requiresApproval: false))
            }
        }
    }

    func testDeferredOtherPeerCanResumeAfterConnectedSheetDismissal() {
        let connected = OathWalletConnectPolicy.RequestPresentation.connected(topic: "approved-peer")
        XCTAssertTrue(connected.defersRequest(topic: "waiting-peer", requiresApproval: true))
        XCTAssertFalse(OathWalletConnectPolicy.RequestPresentation.idle.defersRequest(topic: "waiting-peer", requiresApproval: true))
    }

    func testSamePeerSignInHandoffStillValidatesOriginAccountAndChain() throws {
        let topic = "synthetic-login-peer"
        XCTAssertFalse(OathWalletConnectPolicy.RequestPresentation.connected(topic: topic)
            .defersRequest(topic: topic, requiresApproval: true))
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let text = """
        example.org wants you to sign in with your Ethereum account:
        \(address)

        Sign in to the isolated host test.

        URI: https://example.org
        Version: 1
        Chain ID: 137
        Nonce: Test12345678
        Issued At: \(ISO8601DateFormatter().string(from: now))
        """
        let bytes = Data(text.utf8)
        XCTAssertNotNil(try WalletConnectSignIn.parse(bytes, account: address, chainID: 137, website: "https://example.org", now: now))
        XCTAssertThrowsError(try WalletConnectSignIn.parse(bytes, account: address, chainID: 1, website: "https://example.org", now: now))
        XCTAssertThrowsError(try WalletConnectSignIn.parse(bytes, account: address, chainID: 137, website: "https://unrelated.example", now: now))
        XCTAssertThrowsError(try WalletConnectSignIn.parse(bytes, account: "0x0000000000000000000000000000000000000002", chainID: 137, website: "https://example.org", now: now))
    }
}
