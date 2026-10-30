import Foundation
import XCTest
@testable import WalletConnectSign
import OathAnkr
import OathBitcoin

/// Tests the exact policy used by consent and approval, and the SDK's own
/// required-namespace validator. All identities are synthetic public fixtures.
final class WalletConnectNamespaceTests: XCTestCase {
    func testXrplNamespaces() throws {
        for chain in ["xrpl:0", "xrpl:1"] {
            XCTAssertTrue(OathWalletConnectPolicy.supportsConnection(chain))
            let approved = try build(proposal(["xrpl":namespace([chain],WalletConnectXrplRequest.methods)]),[chain])
            XCTAssertEqual(approved["xrpl"]?.methods,WalletConnectXrplRequest.methods)
            XCTAssertEqual(approved["xrpl"]?.events,[])
            XCTAssertEqual(Set(approved["xrpl"]!.accounts.map { $0.blockchain.absoluteString }),[chain])
            XCTAssertThrowsError(try build(proposal(["xrpl":namespace([chain],["eth_sendTransaction"])]),[chain]))
        }
        XCTAssertFalse(OathWalletConnectPolicy.supportsConnection("xrpl:2"))
        XCTAssertFalse(OathWalletConnectPolicy.approvalMethods.contains("xrpl_signMessage"))
    }

    func testBitcoinNetworksMethodsAndEventsKeepExactPermissions() throws {
        let networks = BitcoinConnectNetwork.allCases.map(\.chain)
        var fixtures: [String: [String: SessionNamespace]] = [:]
        for chain in networks {
            XCTAssertTrue(OathWalletConnectPolicy.supportsConnection(chain))
            let input = proposal(["bip122": namespace([chain], BitcoinConnectRequest.methods, events: Set(BitcoinConnectRequest.events))])
            let approved = try build(input, [chain])
            let value = try XCTUnwrap(approved["bip122"])
            XCTAssertEqual(value.methods, BitcoinConnectRequest.methods)
            XCTAssertEqual(value.events, Set(BitcoinConnectRequest.events))
            XCTAssertEqual(Set(value.accounts.map { $0.blockchain.absoluteString }), [chain])
            for method in ["eth_sendTransaction", "cosmos_signDirect", "wallet_sendCalls"] {
                XCTAssertThrowsError(try build(proposal(["bip122": namespace([chain], [method])]), [chain]))
            }
            fixtures[chain] = approved
        }
        XCTAssertTrue(BitcoinConnectRequest.signingMethods.isSubset(of: OathWalletConnectPolicy.approvalMethods))
        XCTAssertFalse(OathWalletConnectPolicy.approvalMethods.contains("getAccountAddresses"))
        let groups = OathWalletConnectPolicy.networkGroups(requested: Set(networks), required: [networks[0]])
        XCTAssertEqual(groups.count, 4)
        XCTAssertEqual(groups.filter(\.required).count, 1)
        if let path = ProcessInfo.processInfo.environment["OATH_NAMESPACE_FIXTURE"] {
            try JSONEncoder().encode(fixtures).write(to: URL(fileURLWithPath: path + ".bitcoin"))
        }
    }
    func testStellarNamespacesAndExactMethods() throws {
        for chain in ["stellar:pubnet","stellar:testnet"] {
            XCTAssertTrue(OathWalletConnectPolicy.supportsConnection(chain))
            let approved = try build(proposal(["stellar":namespace([chain],WalletConnectStellarRequest.methods)]),[chain])
            XCTAssertEqual(approved["stellar"]?.methods,WalletConnectStellarRequest.methods)
            XCTAssertEqual(approved["stellar"]?.events,[])
            XCTAssertEqual(Set(approved["stellar"]!.accounts.map { $0.blockchain.absoluteString }),[chain])
            XCTAssertThrowsError(try build(proposal(["stellar":namespace([chain],["eth_sendTransaction"])]),[chain]))
        }
        XCTAssertFalse(OathWalletConnectPolicy.supportsConnection("stellar:devnet"))
        XCTAssertFalse(OathWalletConnectPolicy.approvalMethods.contains("stellar_signMessage"))
        XCTAssertTrue(WalletConnectStellarRequest.signingMethods.isSubset(of:OathWalletConnectPolicy.approvalMethods))
    }
    func testNearNamespacesAndAccessPermissions() throws {
        for chain in ["near:mainnet","near:testnet"] {
            XCTAssertTrue(OathWalletConnectPolicy.supportsConnection(chain))
            let approved = try build(proposal(["near":namespace([chain],WalletConnectNearRequest.methods)]),[chain])
            XCTAssertEqual(approved["near"]?.methods,WalletConnectNearRequest.methods)
            XCTAssertEqual(approved["near"]?.events,[])
            XCTAssertEqual(Set(approved["near"]!.accounts.map { $0.blockchain.absoluteString }),[chain])
            XCTAssertThrowsError(try build(proposal(["near":namespace([chain],["eth_sendTransaction"])]),[chain]))
        }
        XCTAssertFalse(OathWalletConnectPolicy.supportsConnection("near:devnet"))
        XCTAssertFalse(OathWalletConnectPolicy.approvalMethods.contains("near_getAccounts"))
        XCTAssertTrue(WalletConnectNearRequest.signingMethods.isSubset(of:OathWalletConnectPolicy.approvalMethods))
    }
    func testTronNamespacesAreIsolatedAndRequireImplementedMethods() throws {
        for chain in WalletConnectTronRequest.blockchains {
            XCTAssertTrue(OathWalletConnectPolicy.supportsConnection(chain))
            let approved = try build(proposal(["tron": namespace([chain], WalletConnectTronRequest.methods)]), [chain])
            XCTAssertEqual(approved["tron"]?.methods, WalletConnectTronRequest.methods)
            XCTAssertEqual(approved["tron"]?.events, [])
            for method in ["eth_sendTransaction", "cosmos_signDirect", "tron_sendTransaction"] {
                XCTAssertThrowsError(try build(proposal(["tron": namespace([chain], [method])]), [chain]))
            }
        }
        XCTAssertFalse(OathWalletConnectPolicy.supportsConnection("tron:0x94a9059e"))
        XCTAssertTrue(WalletConnectTronRequest.methods.isSubset(of: OathWalletConnectPolicy.approvalMethods))
    }
    func testPolkadotNetworksAndMethodsAreBound() throws {
        for network in PolkadotConnectNetwork.allCases {
            let chain = network.chain
            XCTAssertTrue(OathWalletConnectPolicy.supportsConnection(chain))
            let approved = try build(proposal(["polkadot": namespace([chain],WalletConnectPolkadotRequest.methods)]),[chain])
            XCTAssertEqual(approved["polkadot"]?.methods,WalletConnectPolkadotRequest.methods)
            XCTAssertEqual(approved["polkadot"]?.events,[])
            XCTAssertEqual(Set(approved["polkadot"]!.accounts.map { $0.blockchain.absoluteString }),[chain])
            XCTAssertThrowsError(try build(proposal(["polkadot": namespace([chain],["eth_sendTransaction"])]),[chain]))
        }
        XCTAssertFalse(OathWalletConnectPolicy.supportsConnection("polkadot:"+String(repeating:"0",count:32)))
        XCTAssertTrue(WalletConnectPolkadotRequest.methods.isSubset(of:OathWalletConnectPolicy.approvalMethods))
    }
    func testSuiNetworksAndMethodsAreBound() throws {
        for chain in ["sui:mainnet", "sui:testnet"] {
            XCTAssertTrue(OathWalletConnectPolicy.supportsConnection(chain))
            let approved = try build(proposal(["sui": namespace([chain],WalletConnectSuiRequest.methods)]),[chain])
            XCTAssertEqual(approved["sui"]?.methods,WalletConnectSuiRequest.methods)
            XCTAssertEqual(approved["sui"]?.events,[])
            XCTAssertEqual(Set(approved["sui"]!.accounts.map { $0.blockchain.absoluteString }),[chain])
            XCTAssertThrowsError(try build(proposal(["sui": namespace([chain],["eth_sendTransaction"])]),[chain]))
        }
        XCTAssertFalse(OathWalletConnectPolicy.supportsConnection("sui:unknown"))
        XCTAssertFalse(OathWalletConnectPolicy.approvalMethods.contains("sui_getAccounts"))
        XCTAssertTrue(WalletConnectSuiRequest.signingMethods.isSubset(of:OathWalletConnectPolicy.approvalMethods))
    }
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

    func testThorchainConsentShowsSeparateBadgedRowsWithIndependentSelection() throws {
        let aliases = Set(ThorchainWalletConnectRequest.blockchains)
        let evm: Set<String> = ["eip155:1", "eip155:42161", "eip155:43114", "eip155:56", "eip155:8453"]
        let requested = aliases.union(evm)
        let groups = OathWalletConnectPolicy.networkGroups(requested: requested, required: [])
        XCTAssertEqual(groups.count, 7)
        XCTAssertEqual(Set(groups.flatMap(\.blockchains)), requested)
        XCTAssertEqual(groups.map(\.id), groups.map(\.id).sorted())
        let input = proposal(optional: ["cosmos": namespace(Array(aliases), ThorchainWalletConnectRequest.methods),
                                        "eip155": namespace(Array(evm), transaction)])
        for alias in aliases {
            let row = try XCTUnwrap(groups.first { $0.id == alias })
            XCTAssertEqual(row.blockchains, [alias])
            XCTAssertEqual(row.identifierBadge, alias)
            XCTAssertFalse(row.required)
            XCTAssertTrue(row.isSelected(in: requested))
            let remaining = requested.subtracting([alias])
            XCTAssertEqual(row.togglingSelection(in: requested), remaining)
            XCTAssertFalse(row.isSelected(in: remaining))
            XCTAssertEqual(row.togglingSelection(in: remaining), requested)
            XCTAssertEqual(row.togglingSelection(in: evm), evm.union([alias]))
            let approved = try build(input, Array(row.togglingSelection(in: requested)))
            XCTAssertEqual(Set(approved["cosmos"]!.accounts.map { $0.blockchain.absoluteString }), aliases.subtracting([alias]))
            XCTAssertEqual(Set(approved["eip155"]!.accounts.map { $0.blockchain.absoluteString }), evm)
        }
        XCTAssertTrue(groups.filter { evm.contains($0.id) }.allSatisfy { $0.identifierBadge == nil })
        var deselected = requested
        for row in groups where aliases.contains(row.id) { deselected = row.togglingSelection(in: deselected) }
        XCTAssertEqual(deselected, evm)
        XCTAssertNil(try build(input, Array(deselected))["cosmos"])
    }

    func testRequiredThorchainIdentifierDoesNotLockItsOptionalAlternative() throws {
        let aliases = Set(ThorchainWalletConnectRequest.blockchains)
        for required in [[thor], ["cosmos:thorchain-1"], Array(aliases)] {
            let groups = OathWalletConnectPolicy.networkGroups(requested: aliases, required: Set(required))
            XCTAssertEqual(groups.count, 2)
            var selected = aliases
            for row in groups {
                XCTAssertEqual(row.required, required.contains(row.id))
                XCTAssertEqual(row.identifierBadge, row.id)
                let toggled = row.togglingSelection(in: aliases)
                XCTAssertEqual(toggled, row.required ? aliases : aliases.subtracting([row.id]))
                selected = row.togglingSelection(in: selected)
            }
            XCTAssertEqual(selected, Set(required))
            let input = proposal(["cosmos": namespace(required, ThorchainWalletConnectRequest.methods)],
                optional: ["cosmos": namespace(Array(aliases), ThorchainWalletConnectRequest.methods)])
            let approved = try build(input, Array(selected))
            XCTAssertEqual(Set(approved["cosmos"]!.accounts.map { $0.blockchain.absoluteString }), Set(required))
        }
    }

    func testSingleThorchainAliasNeverGrantsItsUnrequestedAlternative() throws {
        for alias in ThorchainWalletConnectRequest.blockchains {
            let row = try XCTUnwrap(OathWalletConnectPolicy.networkGroups(requested: [alias], required: []).first)
            XCTAssertEqual(row.id, alias)
            XCTAssertEqual(row.identifierBadge, alias)
            XCTAssertEqual(row.blockchains, [alias])
            XCTAssertEqual(row.togglingSelection(in: []), [alias])
            XCTAssertEqual(row.togglingSelection(in: [alias]), [])
            let input = proposal(optional: ["cosmos": namespace([alias], ThorchainWalletConnectRequest.methods)])
            let approved = try build(input, Array(row.togglingSelection(in: [])))
            XCTAssertEqual(Set(approved["cosmos"]!.accounts.map { $0.blockchain.absoluteString }), [alias])
        }
    }

    func testSolanaConsentGroupsAliasesButKeepsClustersSeparate() throws {
        let networks: [SolanaSendNetwork] = [.mainnet, .devnet, .testnet]
        let requested = Set(networks.flatMap(\.walletConnectChains))
        let required: Set<String> = [SolanaSendNetwork.devnet.walletConnectChains[1]]
        let groups = OathWalletConnectPolicy.networkGroups(requested: requested, required: required)
        XCTAssertEqual(groups.count, 3)
        XCTAssertEqual(Set(groups.flatMap(\.blockchains)), requested)
        for network in networks {
            let row = try XCTUnwrap(groups.first { $0.id == network.walletConnectChain })
            XCTAssertEqual(row.blockchains, Set(network.walletConnectChains))
            XCTAssertNil(row.identifierBadge)
            XCTAssertEqual(row.required, network == .devnet)
            if network == .devnet {
                XCTAssertEqual(row.togglingSelection(in: requested), requested)
            } else {
                XCTAssertEqual(row.togglingSelection(in: requested), requested.subtracting(network.walletConnectChains))
                XCTAssertEqual(row.togglingSelection(in: []), Set(network.walletConnectChains))
            }
        }
    }

    func testNetworkGroupingDoesNotMergeUnknownIDsOrDistinctEVMChains() {
        let requested: Set<String> = ["cosmos:thorchain", "cosmos:THORCHAIN-1", "cosmos:thorchain-stagenet-v2",
                                     "solana:unknown", "eip155:1", "eip155:56", "eip155:11155111"]
        let groups = OathWalletConnectPolicy.networkGroups(requested: requested, required: [])
        XCTAssertEqual(groups.count, requested.count)
        XCTAssertEqual(Set(groups.map(\.id)), requested)
        XCTAssertTrue(groups.allSatisfy { $0.blockchains == [$0.id] })
        XCTAssertEqual(OathWalletConnectPolicy.networkGroups(requested: [], required: []), [])
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
    func testThorchainIdentifiersRequireExactApprovedPermissions() throws {
        let owner = try ThorchainSendCrypto.address(publicKey: ThorchainSendCrypto.publicKey(privateKey: Data(repeating: 1, count: 32)), network: .mainnet)
        let chains = ThorchainWalletConnectRequest.blockchains
        XCTAssertEqual(Set(chains), ["cosmos:thorchain", "cosmos:thorchain-1"])
        var fixtures = [String: [String: SessionNamespace]]()
        for chain in chains {
            let approved = Account(blockchain: Blockchain(chain)!, address: owner)!
            let other = Account(blockchain: Blockchain(chains.first { $0 != chain }!)!, address: owner)!
            let required = proposal(["cosmos": namespace([chain], ThorchainWalletConnectRequest.methods)])
            let result = try OathWalletConnectPolicy.namespaces(for: required, accounts: [approved])
            try Namespace.validateApproved(result, against: required.requiredNamespaces)
            XCTAssertEqual(result["cosmos"]?.accounts, [approved])
            XCTAssertEqual(result["cosmos"]?.methods, ThorchainWalletConnectRequest.methods)
            XCTAssertThrowsError(try OathWalletConnectPolicy.namespaces(for: required, accounts: [other]))
            let optional = proposal(optional: ["cosmos": namespace(chains, ThorchainWalletConnectRequest.methods)])
            let limited = try OathWalletConnectPolicy.namespaces(for: optional, accounts: [approved])
            XCTAssertEqual(limited["cosmos"]?.accounts, [approved])
            let qualified = proposal([chain: namespace(nil, ThorchainWalletConnectRequest.methods)])
            let scoped = try OathWalletConnectPolicy.namespaces(for: qualified, accounts: [approved])
            try Namespace.validateApproved(scoped, against: qualified.requiredNamespaces)
            fixtures[chain] = result
        }
        for unsupported in ["cosmos:thorchain-mainnet-v1", "cosmos:thorchain-stagenet-v2", "cosmos:oath-thorchain-test-1", "cosmos:THORCHAIN-1"] {
            XCTAssertFalse(OathWalletConnectPolicy.supportsConnection(unsupported))
            XCTAssertThrowsError(try build(proposal(["cosmos": namespace([unsupported], ThorchainWalletConnectRequest.methods)]), [unsupported]))
        }
        if let path = ProcessInfo.processInfo.environment["OATH_NAMESPACE_FIXTURE"] {
            try JSONEncoder().encode(fixtures).write(to: URL(fileURLWithPath: path + ".thorchain"))
        }
    }
    func testSolanaHistoricalIdentifiersRequireExplicitSessionApproval() throws {
        let owner = try SolanaSendCrypto.address(privateKey: Data(repeating: 1, count: 32))
        var fixtures = [String: [String: SessionNamespace]]()
        for network in [SolanaSendNetwork.mainnet, .devnet] {
            let canonical = network.walletConnectChain, historical = network.walletConnectChains[1]
            let historicalAccount = Account(blockchain: Blockchain(historical)!, address: owner)!
            let canonicalAccount = Account(blockchain: Blockchain(canonical)!, address: owner)!
            let required = proposal(["solana": namespace([historical], WalletConnectSolanaRequest.methods)])
            let result = try OathWalletConnectPolicy.namespaces(for: required, accounts: [historicalAccount])
            try Namespace.validateApproved(result, against: required.requiredNamespaces)
            XCTAssertEqual(result["solana"]?.accounts, [historicalAccount])
            // Recognition of an alias never grants that alias to an existing
            // canonical-only session or grants another cluster implicitly.
            XCTAssertThrowsError(try OathWalletConnectPolicy.namespaces(for: required, accounts: [canonicalAccount]))
            let optional = proposal(optional: ["solana": namespace([canonical, historical], WalletConnectSolanaRequest.methods)])
            let limited = try OathWalletConnectPolicy.namespaces(for: optional, accounts: [canonicalAccount])
            XCTAssertEqual(limited["solana"]?.accounts, [canonicalAccount])
            fixtures[historical] = result
            fixtures[canonical] = limited
        }
        if let path = ProcessInfo.processInfo.environment["OATH_NAMESPACE_FIXTURE"] {
            try JSONEncoder().encode(fixtures).write(to: URL(fileURLWithPath: path + ".solana-aliases"))
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

    func testActiveConsentCannotBeReplacedByFollowingRequests() {
        for state in [OathWalletConnectPolicy.RequestPresentation.reviewing] {
            for topic in ["approved-peer", "another-peer"] {
                XCTAssertTrue(state.defersRequest(topic: topic, requiresApproval: true))
                // Non-signing discovery remains available. It neither changes
                // the current review nor gives a dApp a signature.
                XCTAssertFalse(state.defersRequest(topic: topic, requiresApproval: false))
            }
        }
    }

    func testApprovalPermitAndSwapContinueWithoutDismissingPreviousResult() {
        typealias Presentation = OathWalletConnectPolicy.RequestPresentation
        let topic = "synthetic-uniswap-peer"
        var state = Presentation.connected(topic: topic)
        // ERC20 approval -> Permit2 signature -> router swap, each reviewed
        // separately. No completed screen may require an extra dismissal.
        for method in ["eth_sendTransaction", "eth_signTypedData_v4", "eth_sendTransaction"] {
            XCTAssertTrue(OathWalletConnectPolicy.approvalMethods.contains(method))
            XCTAssertFalse(state.defersRequest(topic: topic, requiresApproval: true), method)
            state = .reviewing
            XCTAssertTrue(state.defersRequest(topic: topic, requiresApproval: true))
            state = .completed(topic: topic)
            XCTAssertTrue(state.defersRequest(topic: "different-peer", requiresApproval: true))
        }
    }

    func testCompletionAllowsEverySamePeerReviewButNotAnotherPeersConsent() {
        let state = OathWalletConnectPolicy.RequestPresentation.completed(topic: "approved-peer")
        for method in OathWalletConnectPolicy.approvalMethods {
            XCTAssertFalse(state.defersRequest(topic: "approved-peer", requiresApproval: true), method)
            XCTAssertTrue(state.defersRequest(topic: "another-peer", requiresApproval: true), method)
        }
        for topic in ["approved-peer", "another-peer"] {
            XCTAssertFalse(state.defersRequest(topic: topic, requiresApproval: false))
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
