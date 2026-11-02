@preconcurrency import WalletConnectSign
@preconcurrency import WalletConnectNetworking
import Foundation
import CryptoKit
import Combine
import Observation
import OathDatabase
import OathDiagnostics
import OathAnkr
import OathBitcoin

@MainActor @Observable final class OathWalletConnectService {
    static let shared = OathWalletConnectService()
    struct Proposal {
        let value: Session.Proposal
        let verify: VerifyContext?
        var domain: String? { OathWalletConnectPolicy.safeHost(value.proposer.url) }
        var blocked: Bool {
            guard let domain else { return true }
            if verify?.validation == .invalid || verify?.validation == .scam { return true }
            if verify?.validation == .valid { return verify?.origin.flatMap(OathWalletConnectPolicy.safeHost) != domain }
            return false
        }
        var unverified: Bool { verify?.validation != .valid }
    }
    struct PendingRequest: Identifiable {
        enum Payload {
            case message(Data, WalletConnectSignIn?)
            case typedData(WalletConnectTypedData)
            case thorchain(ThorchainWalletConnectRequest, ThorchainWalletConnectReview)
            case evm(WalletConnectEVMRequest, OathEVMQuote)
            case solana(WalletConnectSolanaRequest, [WalletConnectSolanaReview])
            case xrpl(WalletConnectXrplRequest, WalletConnectXrplReview)
            case stellar(WalletConnectStellarRequest, WalletConnectStellarReview)
            case near(WalletConnectNearRequest, WalletConnectNearReview)
            case nearAccess(WalletConnectNearAccess, WalletConnectNearReview)
            case sui(WalletConnectSuiRequest, WalletConnectSuiReview?)
            case polkadot(WalletConnectPolkadotRequest, PolkadotConnectReview?)
            case tron(WalletConnectTronRequest, WalletConnectTronReview?)
            case ton(WalletConnectTonRequest, WalletConnectTonPlan?)
            case bitcoin(BitcoinConnectRequest, BitcoinConnectPlan?, BitcoinDerivedAddress?)
            case networkSwitch(UInt64)
        }
        let request: Request
        let peer: Session
        let walletID: String
        let account: String
        var payload: Payload
        var approvalToken: WalletConnectApprovalToken? = nil
        var thorchainSwap: ThorchainEVMSwapReview? = nil
        let operationID = UUID()
        var broadcasts: Bool { switch payload { case .xrpl(let request, _): request.broadcasts; case .stellar(let request, _): request.broadcasts; case .nearAccess: true; case .sui(let request, _): request.broadcasts; case .bitcoin(let request, _, _): request.broadcasts; case .evm: true; case .solana(let request, _): request.broadcasts; case .ton(let request, _): request.broadcasts; default: false } }
        var isTransaction: Bool { switch payload { case .xrpl, .stellar, .near, .nearAccess: true; case .sui(let request, _): request.transaction != nil; case .polkadot(let request, _): request.message == nil; case .tron(let request, _): request.message == nil; case .bitcoin(let request, _, _): request.method != "signMessage"; case .thorchain, .evm: true; case .solana(let request, _): request.message == nil; case .ton(let request, _): request.broadcasts; default: false } }
        var id: String { request.id.string }
        var display: String {
            guard case .message(let message, _) = payload else { return "" }
            if let text = String(data: message, encoding: .utf8), !text.unicodeScalars.contains(where: {
                $0.properties.isBidiControl || ($0.value < 32 && $0.value != 10 && $0.value != 9)
            }) { return text }
            return "0x" + message.map { String(format: "%02x", $0) }.joined()
        }
    }
    enum PresentationIssue { case expired, unsupported, invalid, disconnected, unavailable, changed, gas(network: String, address: String), bitcoinFunds, simulation, declined }
    enum ReviewFailure: Error { case updated, quoteUpdated }
    struct TransactionCompletion {
        let sendID: String, hash: String
        let plan: EVMSendPlan
        var progress = OathWalletConnectTransactionProgress()
        var actualFee: String? { progress.snapshot?.actualFee }
        var blockHeight: Int64? { progress.snapshot?.blockHeight }
        var action: WalletConnectEVMAction? = nil
        var approvalToken: WalletConnectApprovalToken? = nil
    }
    struct Completion {
        let id = UUID()
        let peer: Session
        let walletID: String
        let account: String
        let isTransaction: Bool
        var transaction: TransactionCompletion? = nil
        var selectedChain: UInt64? = nil
        var solana: WalletConnectSolanaSubmission? = nil
        var sui: WalletConnectSuiSubmission? = nil
        var xrpl: WalletConnectXrplSubmission? = nil
        var stellar: WalletConnectStellarSubmission? = nil
        var near: WalletConnectNearSubmission? = nil
        var ton: WalletConnectTonSubmission? = nil
        var bitcoin: WalletConnectBitcoinSubmission? = nil
    }
    private(set) var completion: Completion?
    private(set) var completionHandoffRequested: UUID?
    private(set) var presentationIssue: PresentationIssue?
    private(set) var configured = false
    private(set) var sessions = [Session]()
    private(set) var proposal: Proposal?
    private(set) var pendingRequest: PendingRequest?
    private(set) var working = false
    private(set) var preparingRequest = false
    private(set) var revisingTransaction = false
    var failed = false
    private(set) var connectionFailure: OathWalletConnectPolicy.ConnectionFailure?
    var requiresFreshPairing: Bool { connectionFailure.map { !$0.allowsPairingRetry } ?? false }
    private(set) var connectedTopic: String?
    private(set) var connections = OathWalletConnectConnections()
    private(set) var disconnecting = Set<String>()
    @ObservationIgnored private weak var session: OathWalletSession?
    @ObservationIgnored private var observers = Set<AnyCancellable>()
    @ObservationIgnored private var timeout: Task<Void, Never>?
    @ObservationIgnored private var pairingTopic: String?
    @ObservationIgnored private var pairingProgress = OathWalletConnectPolicy.PairingProgress.idle
    @ObservationIgnored private var operation = UUID()
    @ObservationIgnored private var retryingDisconnections = false
    @ObservationIgnored private var bitcoinRecovery: Task<Void, Never>?
    @ObservationIgnored private var bitcoinAddressEvents: Task<Void, Never>?
    @ObservationIgnored private var bitcoinAddressSnapshots: [String: Data] = [:]
    @ObservationIgnored private var xrplRecovery: Task<Void, Never>?
    @ObservationIgnored private var stellarRecovery: Task<Void, Never>?
    @ObservationIgnored private var nearRecovery: Task<Void, Never>?
    @ObservationIgnored private var suiRecovery: Task<Void, Never>?
    @ObservationIgnored private var tonRecovery: Task<Void, Never>?
    @ObservationIgnored private var tonClients: [String: TonSendClient] = [:]
    @ObservationIgnored private var solanaRecovery: Task<Void, Never>?
    @ObservationIgnored private var solanaClients: [String: SolanaSendClient] = [:]
    @ObservationIgnored private var signingRequest = false
    @ObservationIgnored private var preparationTask: Task<Void, Never>?
    @ObservationIgnored private var preparingItem: Request?
    @ObservationIgnored private var preparationGeneration = UUID()
    private var presentationOwner = OathWalletConnectPolicy.PresentationOwnership()
    var presentationOpen: Bool { presentationOwner.id != nil }
    private var presentationID: UUID? { presentationOwner.id }
    @ObservationIgnored private var responsesInFlight = Set<String>()
    private let mappingKey = "walletconnect.approvedWallets"
    private var walletMapping: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: mappingKey) as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: mappingKey) }
    }
    func configure(session: OathWalletSession) {
        self.session = session
        guard !configured else { return }
        do {
            guard let url = Bundle.main.url(forResource: "TokenRPC", withExtension: "plist") else { throw ConfigurationFailure.missing }
            let data = try Data(contentsOf: url)
            guard let dict = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let project = dict["WalletConnectProjectID"] as? String, project.count == 32,
                  let group = Bundle.main.object(forInfoDictionaryKey: "OathWalletConnectKeychainGroup") as? String,
                  !group.contains("$(") else { throw ConfigurationFailure.missing }
            Networking.configure(groupIdentifier: group, projectId: project, socketFactory: OathWCSocketFactory())
            // Both entry points use the same consent/authentication path. This
            // advertises relay-based mobile linking, not Link Mode transport.
            let metadata = AppMetadata(name: "Oath Wallet", description: OathLocalizer.current.text(.wcWalletDescription),
                url: OathWalletLink.universal, icons: ["https://oathwallet.org/wallet-logo.png"],
                redirect: try AppMetadata.Redirect(native: OathWalletLink.native, universal: OathWalletLink.universal, linkMode: false))
            Pair.configure(metadata: metadata)
            Sign.configure(crypto: OathWCCrypto())
                Events.instance.setTelemetryEnabled(false)
            configured = true
            Networking.instance.socketConnectionStatusPublisher
                // SDK socket callbacks originate on URLSession's queue. Move
                // upstream before any closure inherits this MainActor context;
                // scheduling only the sink still traps inside map in Swift 6.
                .receive(on: DispatchQueue.main)
                .map { status in if case .connected = status { true } else { false } }
                .removeDuplicates().sink { [weak self] connected in
                    guard connected else { return }
                    Task { @MainActor in await self?.retryDisconnections() }
                }.store(in: &observers)
            Sign.instance.sessionProposalPublisher.receive(on: DispatchQueue.main).sink { [weak self] item in
                MainActor.assumeIsolated {
                    guard let self, session.isUnlocked, item.proposal.pairingTopic == self.pairingTopic,
                          self.pairingProgress.receiveProposal() else { return }
                    self.timeout?.cancel(); self.working = false
                    self.failed = false; self.connectionFailure = nil; self.presentationIssue = nil
                    self.proposal = .init(value: item.proposal, verify: item.context)
                }
            }.store(in: &observers)
            Sign.instance.sessionsPublisher.receive(on: DispatchQueue.main).sink { [weak self] _ in
                MainActor.assumeIsolated {
                    // Re-read the SDK: a queued snapshot can predate approval.
                    self?.refreshSessions()
                }
            }.store(in: &observers)
            Sign.instance.sessionProposalExpirationPublisher.receive(on: DispatchQueue.main).sink { [weak self] item in
                MainActor.assumeIsolated { if self?.proposal?.value.id == item.id { self?.proposal = nil; self?.failed = true; self?.working = false; self?.presentationIssue = .expired } }
            }.store(in: &observers)
            Sign.instance.sessionRequestPublisher.receive(on: DispatchQueue.main).sink { [weak self] item in
                MainActor.assumeIsolated { self?.receive(item.request, context: item.context) }
            }.store(in: &observers)
            Sign.instance.requestExpirationPublisher.receive(on: DispatchQueue.main).sink { [weak self] id in
                MainActor.assumeIsolated {
                    if self?.pendingRequest?.request.id == id { self?.pendingRequest = nil; self?.presentationIssue = .expired }
                    if self?.preparingItem?.id == id { self?.cancelPreparation(); self?.presentationIssue = .expired }
                }
            }.store(in: &observers)
            refreshSessions()
            Task { await retryDisconnections() }
            // SDK owns durable encrypted pairing keys. A pending signature is
            // revalidated against current account/session/expiry after relaunch.
            if let first = Sign.instance.getPendingRequests().first { receive(first.request, context: first.context) }
        } catch {
            OathDiagnostics.$operationID.withValue(operation) { OathDiagnostics.record(error, component: "walletconnect", operation: "configure") }
            connectionFailure = .configuration; failed = true
        }
    }
    enum ConfigurationFailure: Error { case missing, invalid }
    func pair(_ raw: String) async {
        // A repeated presentation task must not turn in-flight work into failure.
        guard !working else { return }
        timeout?.cancel()
        operation = UUID()
        pairingProgress = .idle; pairingTopic = nil
        proposal = nil; connectedTopic = nil; completion = nil; presentationIssue = nil
        connectionFailure = nil; failed = false
        // Invalid scans and locked/limited sessions are expected validation, not diagnostics failures.
        guard configured else { failConnection(.configuration); return }
        guard session?.isUnlocked == true else { failConnection(.locked); return }
        guard case .walletConnect = OathScanParser.walletConnect(raw, now: .now) else {
            if case .invalid(.expiredWalletConnect) = OathScanParser.walletConnect(raw, now: .now) { failConnection(.expiredQR) }
            else { failConnection(.invalidQR) }
            return
        }
        let uri: WalletConnectURI
        do { uri = try WalletConnectURI(uriString: raw) }
        catch {
            // URI format/expiry errors are expected scan validation, including expiry during parsing.
            if !(error is WalletConnectURI.Errors) {
                OathDiagnostics.$operationID.withValue(operation) { OathDiagnostics.record(error, component: "walletconnect", operation: "parse_pairing") }
            }
            failConnection(OathWalletConnectPolicy.ConnectionFailure.classify(error) ?? .invalidQR); return
        }
        let token = operation
        working = true; pairingTopic = uri.topic
        pairingProgress = .waiting
        timeout?.cancel()
        // Re-scanning a consumed URI must not replay Pair.pair forever. The SDK
        // can already have the proposal (its topic argument currently does not
        // filter results) or an approved session associated with this pairing.
        if let pending = Sign.instance.getPendingProposals().first(where: { $0.proposal.pairingTopic == uri.topic }) {
            _ = pairingProgress.receiveProposal()
            proposal = .init(value: pending.proposal, verify: pending.context); working = false; return
        }
        if let existing = Sign.instance.getSessions().first(where: { connections.isAssociated($0.topic, with: uri.topic) && $0.expiryDate > .now && walletMapping[$0.topic] != nil }) {
            pairingProgress = .connected
            refreshSessions(); connectedTopic = existing.topic; working = false
            resumeRequests()
            return
        }
        guard sessions.count < 32 else { working = false; pairingProgress = .idle; failConnection(.connectionLimit); return }
        timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(30)) } catch is CancellationError { return } catch { OathDiagnostics.$operationID.withValue(token) { OathDiagnostics.record(error, component: "walletconnect", operation: "pair_timeout") }; return }
            guard let self, operation == token, working, pairingProgress.fail() else { return }
            working = false; failConnection(.peerTimeout)
            OathDiagnostics.$operationID.withValue(token) { OathDiagnostics.record(OathWalletConnectPolicy.ConnectionFailure.peerTimeout, component: "walletconnect", operation: "await_proposal") }
        }
        do { try await Pair.instance.pair(uri: uri) }
        catch {
            guard let failure = OathWalletConnectPolicy.ConnectionFailure.classify(error) else {
                if token == operation, pairingProgress == .waiting { timeout?.cancel(); working = false; pairingProgress = .idle }
                return
            }
            OathDiagnostics.$operationID.withValue(token) { OathDiagnostics.record(error, component: "walletconnect", operation: "pair") }
            guard token == operation else { return }
            // A queued proposal may arrive while pair() returns its old-pairing
            // error. Do not replace that actionable proposal with an error page.
            guard pairingProgress.fail() else { return }
            timeout?.cancel(); working = false
            failConnection(failure)
        }
    }
    private func failConnection(_ failure: OathWalletConnectPolicy.ConnectionFailure) {
        connectionFailure = failure
        failed = true
    }
    func accounts(walletID: String) async -> [AccountRecord] {
        guard let session, session.isUnlocked, session.wallets.contains(where: { $0.id == walletID }) else { return [] }
        do { let db = try await session.vault.database(); var records = try await db.accounts(walletID: walletID)
            for index in records.indices where records[index].networkID == "solana" {
                records[index] = try await db.solanaSigningAccount(accountID: records[index].id)
            }
            guard session.isUnlocked, session.wallets.contains(where: { $0.id == walletID }) else { return [] }
            var unavailableBitcoin = Set<String>()
            for index in records.indices where records[index].networkID == "bitcoin" {
                let addresses = try await db.walletConnectBitcoinAddresses(accountID: records[index].id)
                guard !addresses.isEmpty, addresses.allSatisfy({ $0.multisigInputWeight == nil }) else {
                    unavailableBitcoin.insert(records[index].id); continue
                }
                if let primary = addresses.first(where: { $0.type == .nativeSegwit && $0.change == 0 && $0.index == 0 }) ?? addresses.first {
                    records[index].address = primary.address
                }
            }
            // The consent page displays one address per network. Negotiate exactly those addresses.
            var seen = Set<String>()
            return records.sorted { $0.accountIndex == $1.accountIndex ? $0.id < $1.id : $0.accountIndex < $1.accountIndex }
                .filter {
                    guard $0.derivationPath != "xrpl-multisig-v1", $0.derivationPath != "stellar-multisig-v1", $0.derivationPath != "near-multisig-v1", $0.derivationPath != "sui-multisig-v1", $0.derivationPath != "ton-multisig-v1", $0.derivationPath != "tron-multisig-v1", !unavailableBitcoin.contains($0.id), let blockchain = OathImportChain(rawValue: $0.networkID).flatMap(Self.blockchain),
                          OathWalletConnectPolicy.supportsConnection(blockchain.absoluteString) else { return false }
                    return seen.insert($0.networkID).inserted
                } }
        catch { OathDiagnostics.$operationID.withValue(operation) { OathDiagnostics.record(error, component: "walletconnect", operation: "load_accounts") }; failConnection(.accounts); return [] }
    }
    static func blockchain(_ chain: OathImportChain) -> Blockchain? {
        if chain == .bitcoin { return Blockchain(BitcoinConnectNetwork.mainnet.chain) }
        if chain == .solana { return Blockchain(SolanaSendNetwork.mainnet.walletConnectChain) }
        if chain == .polkadot { return Blockchain(PolkadotConnectNetwork.assetHub.chain) }
        if chain == .tron { return Blockchain(TronSendNetwork.mainnet.walletConnectChain) }
        if chain == .xrpl { return Blockchain("xrpl:0") }
        if chain == .stellar { return Blockchain("stellar:pubnet") }
        if chain == .near { return Blockchain("near:mainnet") }
        if chain == .sui { return Blockchain("sui:mainnet") }
        if chain == .ton { return Blockchain(TonSendNetwork.mainnet.walletConnectChain) }
        if chain == .thorchain { return Blockchain(ThorchainWalletConnectRequest.blockchain) }
        guard chain.isEVM, let id = OathTokenNetwork.all.first(where: { $0.chain == chain })?.chainID else { return nil }
        return Blockchain("eip155:\(id)")
    }
    static func blockchains(networkID: String) -> [Blockchain] {
        if networkID == "bitcoin" { return BitcoinConnectNetwork.allCases.compactMap { Blockchain($0.chain) } }
        if networkID == "solana" { return [SolanaSendNetwork.mainnet, .devnet, .testnet].flatMap(\.walletConnectChains).compactMap { Blockchain($0) } }
        if networkID == "polkadot" { return PolkadotConnectNetwork.allCases.compactMap { Blockchain($0.chain) } }
        if networkID == "tron" { return WalletConnectTronRequest.blockchains.compactMap { Blockchain($0) } }
        if networkID == "xrpl" { return ["xrpl:0", "xrpl:1"].compactMap { Blockchain($0) } }
        if networkID == "stellar" { return ["stellar:pubnet", "stellar:testnet"].compactMap { Blockchain($0) } }
        if networkID == "near" { return ["near:mainnet","near:testnet"].compactMap { Blockchain($0) } }
        if networkID == "sui" { return ["sui:mainnet","sui:testnet"].compactMap { Blockchain($0) } }
        if networkID == "ton" { return WalletConnectTonRequest.blockchains.compactMap { Blockchain($0) } }
        if networkID == "thorchain" { return ThorchainWalletConnectRequest.blockchains.compactMap { Blockchain($0) } }
        return OathImportChain(rawValue: networkID).flatMap(blockchain).map { [$0] } ?? []
    }
    static func chain(for blockchain: String) -> OathImportChain? {
        OathImportChain.allCases.first { blockchains(networkID: $0.rawValue).contains { $0.absoluteString == blockchain } }
    }
    private static func accountMatches(_ lhs: String, _ rhs: String, chain: Blockchain) -> Bool {
        if chain.namespace == "sui" {
            guard let left = try? SuiIdentity.address(lhs), let right = try? SuiIdentity.address(rhs) else { return false }; return left == right
        }
        if chain.namespace == "polkadot" {
            guard let left = try? PolkadotIdentity.publicKey(lhs), let right = try? PolkadotIdentity.publicKey(rhs) else { return false }; return left == right
        }
        if let network = BitcoinConnectNetwork(chain: chain.absoluteString) {
            return network.matchesAccount(lhs,rhs)
        }
        if let network = TonSendNetwork(walletConnectChain: chain.absoluteString) {
            guard let left = try? network.address(lhs), let right = try? network.address(rhs) else { return false }
            return left == right
        }
        return chain.namespace == "eip155" ? lhs.lowercased() == rhs.lowercased() : lhs == rhs
    }
    static func requested(_ proposal: Session.Proposal, required: Bool) -> Set<String> {
        let namespaces = required ? proposal.requiredNamespaces : proposal.optionalNamespaces ?? [:]
        return Set(namespaces.flatMap { key, value in value.chains?.map(\.absoluteString) ?? (key.contains(":") ? [key] : []) })
    }
    func namespaces(for proposal: Session.Proposal, accounts: [AccountRecord], selected: Set<String>) throws -> [String: SessionNamespace] {
        // Builder validates every required chain, method, event and account.
        let approved = accounts.flatMap { record -> [Account] in
            Self.blockchains(networkID: record.networkID).filter { selected.contains($0.absoluteString) }
                .compactMap { chain in
                    let address: String
                    if let network = BitcoinConnectNetwork(chain: chain.absoluteString) {
                        guard let encoded = try? network.address(mainnetAddress:record.address) else { return nil }
                        address = encoded
                    } else if let network = TonSendNetwork(walletConnectChain: chain.absoluteString) {
                        guard let friendly = try? network.walletConnectAddress(record.address) else { return nil }
                        address = friendly
                    } else { address = record.address }
                    return Account(blockchain: chain, address: address)
                }
        }
        return try OathWalletConnectPolicy.namespaces(for: proposal, accounts: approved)
    }
    func approve(accounts: [AccountRecord], selected: Set<String>, walletID: String, acknowledged: Bool, digits: [UInt8]? = nil, reason: String = "") async throws {
        guard let proposal, !proposal.blocked, !proposal.unverified || acknowledged,
              session?.isUnlocked == true, !working else { return }
        working = true; failed = false; connectionFailure = nil
        let token = operation
        defer { if token == operation { working = false } }
        do {
            // Reload ownership immediately before consent is committed.
            let current = await self.accounts(walletID: walletID)
            guard token == operation, session?.isUnlocked == true, self.proposal?.value.id == proposal.value.id,
                  !current.isEmpty, Set(accounts.map(\.id)) == Set(current.map(\.id)) else { throw ConfigurationFailure.invalid }
            let namespaces = try namespaces(for: proposal.value, accounts: current, selected: selected)
            // Transfer a detached value across the SDK's nonisolated async boundary.
            let encoded = try JSONEncoder().encode(namespaces)
            var properties: [String: String] = [:]
            if namespaces.values.contains(where: { $0.accounts.contains(where: { $0.blockchain.namespace == "sui" }) }),
               let record = current.first(where: { $0.networkID == "sui" }), let session {
                let key = try await session.vault.suiPublicKey(walletID:walletID,accountID:record.id)
                properties["sui_getAccounts"] = String(data:try JSONEncoder().encode(WalletConnectSuiRequest.accountResponse(publicKey:key)),encoding:.utf8)
            }
            if namespaces.values.contains(where: { $0.accounts.contains(where: { $0.blockchain.namespace == "tron" }) }) {
                properties["tron_method_version"] = "v1"
            }
            if namespaces.values.contains(where: { $0.accounts.contains(where: { $0.blockchain.namespace == "ton" }) }),
               let record = current.first(where: { $0.networkID == "ton" }), let session {
                let key = try await session.vault.tonPublicKey(walletID: walletID, accountID: record.id)
                properties["ton_getPublicKey"] = key.map { String(format: "%02x", $0) }.joined()
                properties["ton_getStateInit"] = try WalletConnectTonCrypto.stateInit(publicKey: key)
            }
            if let record = current.first(where: { $0.networkID == "bitcoin" }), let session {
                let shared = try await session.vault.database().walletConnectBitcoinAddresses(accountID:record.id)
                let chains = Set(namespaces.values.flatMap { $0.accounts }.filter { $0.blockchain.namespace == "bip122" }.map { $0.blockchain.absoluteString })
                let rows = try chains.sorted().flatMap { chain -> [BitcoinConnectAddress] in
                    guard let network = BitcoinConnectNetwork(chain:chain) else { return [] }
                    return try shared.map { try BitcoinConnectAddress($0,network:network) }
                }
                if !rows.isEmpty { properties["bip122_getAccountAddresses"] = String(data:try JSONEncoder().encode(rows),encoding:.utf8) }
            }
            guard token == operation, session?.isUnlocked == true else { throw CancellationError() }
            let proofs = try await approveTonProofs(proposal.value, namespaces: namespaces, accounts: current, walletID: walletID, digits: digits, reason: reason)
            guard token == operation, session?.isUnlocked == true else { throw CancellationError() }
            let result = try await Self.commitProposal(id: proposal.value.id, namespaces: encoded, properties: properties, proofs: proofs)
            guard token == operation, session?.isUnlocked == true, self.proposal?.value.id == proposal.value.id else {
                try await Sign.instance.disconnect(topic: result.topic)
                if token == operation { working = false }
                return
            }
            walletMapping[result.topic] = walletID
            connections.approve(result.topic, pairingTopic: proposal.value.pairingTopic)
            refreshSessions(); self.proposal = nil; connectedTopic = result.topic
            pairingProgress = .connected
            timeout?.cancel(); failed = false; connectionFailure = nil; presentationIssue = nil
            OathHaptics.shared.play(.success)
        } catch is CancellationError { throw CancellationError() }
        catch where error is OathBiometricCredentialError || error is OathWalletError {
            // diagnostics: walletconnect-signing-propagation. Authentication retry
            // and passcode fallback are handled by the existing signing sheet.
            throw error
        }
        catch {
            OathDiagnostics.$operationID.withValue(token) { OathDiagnostics.record(error, component: "walletconnect", operation: "approve") }
            guard token == operation else { return }
            if error is ConfigurationFailure { failConnection(.accounts) }
            else if let failure = OathWalletConnectPolicy.ConnectionFailure.classify(error) { failConnection(failure) }
        }
        if token == operation {
            working = false
            // Settlement can deliver the first account/sign-in request before
            // commitProposal returns. Replay it after storing session ownership; the
            // SDK does not publish an already-pending request a second time.
            if self.proposal == nil { resumeRequests() }
        }
    }
    @concurrent nonisolated private static func commitProposal(id: String, namespaces: Data, properties: [String: String], proofs: Data?) async throws -> Session {
        let detached = try JSONDecoder().decode([String: SessionNamespace].self, from: namespaces)
        return try await Sign.instance.approve(proposalId: id, namespaces: detached, sessionProperties: properties.isEmpty ? nil : properties, proposalRequestsResponses: try proofs.map { try JSONDecoder().decode(ProposalRequestsResponses.self, from: $0) })
    }
    func reject(presentationID: UUID) async {
        guard presentationOwner.id == presentationID else { return }
        let rejected = cancelPairing()
        await rejectProposal(rejected)
    }
    private func cancelPairing() -> Proposal? {
        timeout?.cancel(); operation = UUID(); working = false
        pairingProgress = .idle
        let rejected = proposal
        proposal = nil; pairingTopic = nil
        return rejected
    }
    private func rejectProposal(_ rejected: Proposal?) async {
        if let rejected {
            do { try await Sign.instance.rejectSession(proposalId: rejected.value.id, reason: .userRejected) }
            catch { OathDiagnostics.$operationID.withValue(operation) { OathDiagnostics.record(error, component: "walletconnect", operation: "reject") } }
        }
        // Unapproved pairing keys expire in the SDK. Pair.disconnect is a no-op
        // in this SDK; session proposals are explicitly rejected above.
    }
    func walletID(for topic: String) -> String? { walletMapping[topic] }

    func refreshSessions() {
        guard configured else { return }
        sessions = Sign.instance.getSessions().filter { $0.expiryDate > .now }.sorted {
            let first = connections.connectedAt($0.topic) ?? .distantPast
            let second = connections.connectedAt($1.topic) ?? .distantPast
            return first == second ? $0.topic < $1.topic : first > second
        }
        let live = Set(sessions.map(\.topic))
        walletMapping = walletMapping.filter { live.contains($0.key) && !connections.isRevoked($0.key) }
        connections.reconcile(topics: live)
        if let pendingRequest, !live.contains(pendingRequest.request.topic) || connections.isRevoked(pendingRequest.request.topic) {
            self.pendingRequest = nil; presentationIssue = .disconnected
        }
        if let preparingItem, !live.contains(preparingItem.topic) || connections.isRevoked(preparingItem.topic) { cancelPreparation() }
        if let connectedTopic, !live.contains(connectedTopic) { self.connectedTopic = nil }
        resumeBitcoinAddressEvents()
    }

    @discardableResult func disconnect(_ topic: String) async -> Bool {
        guard configured, !disconnecting.contains(topic) else { return false }
        // Revoke before awaiting the relay, including when offline. Existing
        // request/sign guards also re-check this mapping after authentication.
        connections.revoke(topic)
        walletMapping.removeValue(forKey: topic)
        if pendingRequest?.request.topic == topic { pendingRequest = nil }
        if preparingItem?.topic == topic { cancelPreparation() }
        disconnecting.insert(topic)
        defer { disconnecting.remove(topic) }
        return await OathDiagnostics.$operationID.withValue(UUID()) {
            do {
                if Sign.instance.getSessions().contains(where: { $0.topic == topic }) {
                    try await Sign.instance.disconnect(topic: topic)
                }
                refreshSessions()
                return true
            } catch {
                refreshSessions()
                // A peer deletion/expiry winning this race is expected teardown.
                guard sessions.contains(where: { $0.topic == topic }) else { return true }
                OathDiagnostics.record(error, component: "walletconnect", operation: "disconnect")
                return false
            }
        }
    }
    func retryDisconnections() async {
        guard configured, !retryingDisconnections else { return }
        retryingDisconnections = true
        defer { retryingDisconnections = false }
        refreshSessions()
        // Bounded, serial retry on activation/reconnection. The app permits at
        // most 32 sessions; visit each so a failed peer cannot starve the rest.
        for topic in sessions.filter({ connections.isRevoked($0.topic) }).prefix(32).map(\.topic) {
            guard !Task.isCancelled else { return }
            await disconnect(topic)
        }
    }
    /// Older peers omit expiry. Preserve the first-seen deadline across restart,
    /// so opening the app cannot grant a stale signature request a fresh lifetime.
    private func requestDeadline(_ request: Request) -> TimeInterval {
        if let explicit = request.expiryTimestamp { return TimeInterval(explicit) }
        let key = Data(SHA256.hash(data: Data((request.topic + ":" + request.id.string).utf8))).map { String(format: "%02x", $0) }.joined()
        var deadlines = UserDefaults.standard.dictionary(forKey: "walletconnect.requestDeadlines") as? [String: Double] ?? [:]
        if let stored = deadlines[key] { return stored }
        guard deadlines.count < 256 else { return 0 }
        let deadline = Date.now.timeIntervalSince1970 + 300
        deadlines[key] = deadline
        UserDefaults.standard.set(deadlines, forKey: "walletconnect.requestDeadlines")
        return deadline
    }
    private var requestPresentation: OathWalletConnectPolicy.RequestPresentation {
        if presentationOwner.isDismissing { return .reviewing }
        if working, proposal != nil { return .committingConnection }
        if working || signingRequest || proposal != nil || pendingRequest != nil || preparingRequest || presentationIssue != nil { return .reviewing }
        if let completion { return .completed(topic: completion.peer.topic) }
        if presentationOpen, let connectedTopic { return .connected(topic: connectedTopic) }
        return .idle
    }
    private func receive(_ request: Request, context: VerifyContext?, replacingCompletion: UUID? = nil) {
        guard !responsesInFlight.contains(requestKey(request)) else { return }
        if pendingRequest?.request.id == request.id, pendingRequest?.request.topic == request.topic { return }
        if preparingItem?.id == request.id, preparingItem?.topic == request.topic { return }
        if requestPresentation == .committingConnection {
            // A dApp can send its first request as soon as settlement arrives,
            // before approve() has committed the local wallet association.
            if Sign.instance.getPendingRequests().count > 8 { respondError(request, code: 4001) }
            return
        }
        guard let peer = Sign.instance.getSessions().first(where: { $0.topic == request.topic }), peer.expiryDate > .now,
              requestDeadline(request) > Date.now.timeIntervalSince1970,
              let namespace = peer.namespaces[String(request.chainId.absoluteString.prefix(while: { $0 != ":" }))] ?? peer.namespaces[request.chainId.absoluteString],
              namespace.methods.contains(request.method),
              OathWalletConnectPolicy.methods(namespace: String(request.chainId.absoluteString.prefix(while: { $0 != ":" }))).contains(request.method),
              context?.validation != .invalid, context?.validation != .scam,
              context?.validation != .valid || context?.origin.flatMap(OathWalletConnectPolicy.safeHost) == OathWalletConnectPolicy.safeHost(peer.peer.url),
              let walletID = walletMapping[request.topic],
              let account = namespace.accounts.first(where: { $0.blockchain == request.chainId })?.address else {
            respondError(request, code: 4100); return
        }
        guard session?.isUnlocked == true else { return } // SDK retains it; resume after unlock.
        guard session?.wallets.contains(where: { $0.id == walletID }) == true else { respondError(request, code: 4100); return }
        if request.chainId.namespace == "eip155", let active = connections.activeChain(request.topic),
           request.method != "wallet_switchEthereumChain", request.method != "eth_chainId",
           request.chainId.reference != String(active) {
            respondError(request, code: 4901); return
        }
        if requestPresentation.defersRequest(topic: request.topic,
            requiresApproval: OathWalletConnectPolicy.approvalMethods.contains(request.method)) {
            // The SDK retains a bounded waiting queue; never replace a visible
            // review. A connection or completed result can hand off to the same
            // peer's next explicit review, but never to a different peer.
            if Sign.instance.getPendingRequests().count > 8 { respondError(request, code: 4001) }
            return
        }
        if presentationOpen, let completion,
           OathWalletConnectPolicy.CompletionHandoff.shouldQueue(presentation: requestPresentation,
               topic: request.topic, requiresApproval: OathWalletConnectPolicy.approvalMethods.contains(request.method)) {
            // Keep the receipt visible briefly, then revalidate this request
            // through the same path without releasing the presentation owner.
            if replacingCompletion != completion.id {
                if Sign.instance.getPendingRequests().count > 8 { respondError(request, code: 4001) }
                else { completionHandoffRequested = completion.id }
                return
            }
        }
        if OathWalletConnectPolicy.approvalMethods.contains(request.method) {
            // Retire the previous result before preparing the next request.
            // Otherwise a loading/error state can sit behind an old success.
            // This does not grant consent or alter the persisted transaction.
            completion = nil; completionHandoffRequested = nil
        }
        switch request.method {
        case "wallet_switchEthereumChain":
            do {
                let supported = Set(OathTokenNetwork.all.compactMap(\.chainID))
                let authorized = Set(peer.accounts.filter { $0.blockchain.namespace == "eip155" }.compactMap { UInt64($0.blockchain.reference) })
                let target = try WalletConnectNetworkRequest.chainID(params: JSONEncoder().encode(request.params), supported: supported, authorized: authorized)
                pendingRequest = .init(request: request, peer: peer, walletID: walletID, account: account, payload: .networkSwitch(target))
            } catch {
                // Unknown/unauthorized peer networks are expected validation;
                // no peer URLs, names or params enter the diagnostic stream.
                if !(error is WalletConnectNetworkRequest.Failure) && !(error is WalletConnectJSON.Failure) {
                    OathDiagnostics.record(error, component: "walletconnect", operation: "parse_network_switch")
                }
                respondError(request, code: 4902); presentationIssue = .unsupported
            }
        case "eth_sendTransaction":
            guard pendingRequest == nil, !preparingRequest else { return }
            preparingRequest = true; preparingItem = request; preparationGeneration = UUID()
            let generation = preparationGeneration
            preparationTask = Task { await prepareEVM(request, peer: peer, walletID: walletID, account: account, generation: generation) }
        case "personal_sign":
            guard pendingRequest == nil, !preparingRequest, let params = try? request.params.get([String].self),
                  let message = OathWalletConnectPolicy.personalMessage(params, account: account) else { respondError(request, code: 4001); return }
            do {
                guard let chainID = UInt64(request.chainId.reference) else { throw ConfigurationFailure.invalid }
                let signIn = try WalletConnectSignIn.parse(message, account: account, chainID: chainID, website: peer.peer.url)
                completion = nil; presentationIssue = nil
                pendingRequest = .init(request: request, peer: peer, walletID: walletID, account: account, payload: .message(message, signIn))
            } catch {
                // Expected peer input validation. Never upload sign-in text.
                if !(error is WalletConnectSignIn.Failure) && !(error is ConfigurationFailure) {
                    OathDiagnostics.record(error, component: "walletconnect", operation: "parse_sign_in")
                }
                respondError(request, code: -32602); presentationIssue = error is WalletConnectSignIn.Failure ? .invalid : .unsupported
            }
        case "eth_signTypedData_v4":
            guard pendingRequest == nil, !preparingRequest,
                  let params = try? request.params.get([String].self), params.count == 2,
                  params[0].lowercased() == account.lowercased(), params[1].utf8.count <= 65_536,
                  let chainID = UInt64(request.chainId.reference) else { respondError(request, code: -32602); return }
            preparingRequest = true; preparingItem = request; preparationGeneration = UUID()
            let generation = preparationGeneration
            preparationTask = Task {
                defer { if preparationGeneration == generation { preparationTask = nil; preparingItem = nil; preparingRequest = false } }
                do {
                    let data = try await Self.decodeTypedData(Data(params[1].utf8), chainID: chainID, account: account)
                    guard preparationGeneration == generation, !Task.isCancelled, authorized(request, walletID: walletID, account: account), pendingRequest == nil else { return }
                    try data.validatePermissionTime()
                    completion = nil; presentationIssue = nil
                    pendingRequest = .init(request: request, peer: peer, walletID: walletID, account: account, payload: .typedData(data))
                } catch is CancellationError { }
                catch {
                    guard preparationGeneration == generation, !Task.isCancelled, authorized(request, walletID: walletID, account: account) else { return }
                    // Peer schema/chain validation is expected protocol rejection;
                    // signed fields and JSON decoder paths are never diagnostics.
                    if !(error is WalletConnectTypedData.Failure) && !(error is WalletConnectJSON.Failure) {
                        OathDiagnostics.$operationID.withValue(generation) {
                            OathDiagnostics.record(error, component: "walletconnect", operation: "prepare_typed_data")
                        }
                    }
                    respondError(request, code: -32602); failed = true
                    presentationIssue = error as? WalletConnectTypedData.Failure == .expired ? .expired : .invalid
                }
            }
        case "cosmos_getAccounts", "cosmos_signAmino", "cosmos_signDirect":
            guard ThorchainWalletConnectRequest.blockchains.contains(request.chainId.absoluteString),
                  pendingRequest == nil, !preparingRequest else { respondError(request, code: 4001); return }
            preparingRequest = true; preparingItem = request; preparationGeneration = UUID()
            if request.method != "cosmos_getAccounts" { presentationIssue = nil; failed = false }
            let generation = preparationGeneration
            preparationTask = Task { await prepareThorchain(request, peer: peer, walletID: walletID, account: account, generation: generation) }
        case "getAccountAddresses", "sendTransfer", "signPsbt", "signMessage":
            guard pendingRequest == nil, !preparingRequest else { return }
            preparingRequest = true; preparingItem = request; preparationGeneration = UUID()
            let generation = preparationGeneration
            preparationTask = Task { await prepareBitcoin(request,peer:peer,walletID:walletID,account:account,generation:generation) }
        case "xrpl_signTransaction", "xrpl_signTransactionFor":
            guard pendingRequest == nil, !preparingRequest else { return }
            preparingRequest = true; preparingItem = request; preparationGeneration = UUID()
            let generation = preparationGeneration
            preparationTask = Task { await prepareXrpl(request,peer:peer,walletID:walletID,account:account,generation:generation) }
        case "stellar_signXDR", "stellar_signAndSubmitXDR":
            guard pendingRequest == nil, !preparingRequest else { return }
            preparingRequest = true; preparingItem = request; preparationGeneration = UUID()
            let generation = preparationGeneration
            preparationTask = Task { await prepareStellar(request,peer:peer,walletID:walletID,account:account,generation:generation) }
        case "near_getAccounts", "near_signTransaction", "near_signTransactions", "near_signIn", "near_signOut":
            guard pendingRequest == nil, !preparingRequest else { return }
            preparingRequest = true; preparingItem = request; preparationGeneration = UUID()
            let generation = preparationGeneration
            preparationTask = Task { await prepareNear(request,peer:peer,walletID:walletID,account:account,generation:generation) }
        case "sui_getAccounts", "sui_signTransaction", "sui_signAndExecuteTransaction", "sui_signPersonalMessage":
            guard pendingRequest == nil, !preparingRequest else { return }
            preparingRequest = true; preparingItem = request; preparationGeneration = UUID()
            let generation = preparationGeneration
            preparationTask = Task { await prepareSui(request,peer:peer,walletID:walletID,account:account,generation:generation) }
        case "polkadot_signTransaction", "polkadot_signMessage":
            guard pendingRequest == nil, !preparingRequest else { return }
            preparingRequest = true; preparingItem = request; preparationGeneration = UUID()
            let generation = preparationGeneration
            preparationTask = Task { await preparePolkadot(request, peer:peer, walletID:walletID, account:account, generation:generation) }
        case "tron_signTransaction", "tron_signMessage":
            guard pendingRequest == nil, !preparingRequest else { return }
            preparingRequest = true; preparingItem = request; preparationGeneration = UUID()
            let generation = preparationGeneration
            preparationTask = Task { await prepareTron(request, peer:peer, walletID:walletID, account:account, generation:generation) }
        case "ton_sendMessage", "ton_signData":
            guard pendingRequest == nil, !preparingRequest else { return }
            preparingRequest = true; preparingItem = request; preparationGeneration = UUID()
            let generation = preparationGeneration
            preparationTask = Task { await prepareTon(request, peer: peer, walletID: walletID, account: account, generation: generation) }
        case "solana_getAccounts", "solana_requestAccounts":
            respond(request, .response(AnyCodable([["pubkey": account]])))
        case "solana_signMessage", "solana_signTransaction", "solana_signAllTransactions", "solana_signAndSendTransaction":
            guard pendingRequest == nil, !preparingRequest else { return }
            preparingRequest = true; preparingItem = request; preparationGeneration = UUID()
            let generation = preparationGeneration
            preparationTask = Task { await prepareSolana(request, peer: peer, walletID: walletID, account: account, generation: generation) }
        case "eth_accounts", "eth_requestAccounts": respond(request, .response(AnyCodable([account])))
        case "eth_chainId":
            guard let id = connections.activeChain(request.topic) ?? UInt64(request.chainId.reference) else { respondError(request, code: 4100); return }
            respond(request, .response(AnyCodable("0x" + String(id, radix: 16))))
        default: respondError(request, code: 4200)
        }
    }
    func resumeRequests() {
        resumeSolanaSubmissions()
        resumeTonSubmissions()
        resumeSuiSubmissions()
        resumeXrplSubmissions()
        resumeStellarSubmissions()
        resumeNearSubmissions()
        resumeBitcoinSubmissions()
        guard configured, session?.isUnlocked == true, !working, !signingRequest, proposal == nil,
              pendingRequest == nil, !preparingRequest, presentationIssue == nil else { return }
        refreshSessions()
        for item in Sign.instance.getPendingRequests().prefix(8) { receive(item.request, context: item.context); if pendingRequest != nil || preparingRequest || presentationIssue != nil { break } }
    }
    private func authorized(_ request: Request, walletID: String, account: String) -> Bool {
        guard session?.isUnlocked == true, walletMapping[request.topic] == walletID,
              session?.wallets.contains(where: { $0.id == walletID }) == true,
              !connections.isRevoked(request.topic), requestDeadline(request) > Date.now.timeIntervalSince1970,
              let peer = Sign.instance.getSessions().first(where: { $0.topic == request.topic && $0.expiryDate > .now }),
              let namespace = peer.namespaces[String(request.chainId.absoluteString.prefix(while: { $0 != ":" }))] ?? peer.namespaces[request.chainId.absoluteString],
              namespace.methods.contains(request.method),
              namespace.accounts.contains(where: { $0.blockchain == request.chainId && Self.accountMatches($0.address, account, chain: request.chainId) }),
              let pending = Sign.instance.getPendingRequests().first(where: { $0.request == request }),
              pending.context?.validation != .invalid, pending.context?.validation != .scam,
              pending.context?.validation != .valid || pending.context?.origin.flatMap(OathWalletConnectPolicy.safeHost) == OathWalletConnectPolicy.safeHost(peer.peer.url) else { return false }
        return OathWalletConnectPolicy.methods(namespace: String(request.chainId.absoluteString.prefix(while: { $0 != ":" }))).contains(request.method)
    }
    private func cancelPreparation() {
        preparationGeneration = UUID(); preparationTask?.cancel(); preparationTask = nil
        preparingItem = nil; preparingRequest = false
    }
    private func durableSendID(_ request: Request) -> String {
        "wc:" + Data(SHA256.hash(data: Data(requestKey(request).utf8))).map { String(format: "%02x", $0) }.joined()
    }
    private func solanaClient(_ network: SolanaSendNetwork) throws -> SolanaSendClient {
        if let existing = solanaClients[network.rawValue] { return existing }
        let client = try OathTokenRPCConfiguration.bundled().makeSolanaSendClient(network: network)
        solanaClients[network.rawValue] = client; return client
    }
    @concurrent nonisolated private static func decodeSolana(method: String, chain: String, account: String, params: Data) async throws -> WalletConnectSolanaRequest {
        try WalletConnectSolanaRequest(method: method, chain: chain, account: account, params: params)
    }
    private func prepareSolana(_ request: Request, peer: Session, walletID: String, account: String, generation: UUID) async {
        defer { if preparationGeneration == generation { preparationTask = nil; preparingItem = nil; preparingRequest = false } }
        await OathDiagnostics.$chain.withValue("solana") {
            await OathDiagnostics.$operationID.withValue(generation) {
                do {
                    let input = try await Self.decodeSolana(method: request.method, chain: request.chainId.absoluteString, account: account, params: JSONEncoder().encode(request.params))
                    // A replay of a committed request must never generate a second transaction.
                    if input.broadcasts, let session, let stored = try await session.vault.database().walletConnectSolanaSubmission(durableSendID(request)) {
                        guard stored.fingerprint == input.fingerprint, stored.walletID == walletID,
                              authorized(request, walletID: walletID, account: account), preparationGeneration == generation else { throw SolanaSendError.changed }
                        let item = PendingRequest(request: request, peer: peer, walletID: walletID, account: account, payload: .solana(input, []))
                        await finishSolanaSubmission(item, stored: stored); return
                    }
                    let client = try solanaClient(input.network)
                    let reviews = try await client.walletConnectReview(input)
                    guard preparationGeneration == generation, !Task.isCancelled, authorized(request, walletID: walletID, account: account), pendingRequest == nil else { return }
                    completion = nil; presentationIssue = nil
                    pendingRequest = .init(request: request, peer: peer, walletID: walletID, account: account, payload: .solana(input, reviews))
                } catch is CancellationError { }
                catch {
                    guard preparationGeneration == generation, !Task.isCancelled, authorized(request, walletID: walletID, account: account) else { return }
                    // Invalid peer input/expired blockhash are expected validation.
                    // RPC and simulation failures are recorded without request bytes.
                    if !(error is WalletConnectJSON.Failure), error as? SolanaSendError != .malformed,
                       error as? SolanaSendError != .wrongOwner, error as? SolanaSendError != .expired {
                        OathDiagnostics.record(error, component: "walletconnect", operation: "prepare_solana", context: ["chain": "solana"])
                    }
                    respondError(request, code: -32602)
                    presentationIssue = error is SendFeeFundingError ? .gas(network:"solana",address:account) : error as? SolanaSendError == .expired ? .expired : error as? SolanaSendError == .simulationFailed ? .simulation : .invalid
                }
            }
        }
    }
    private func finishSolanaSubmission(_ item: PendingRequest, stored: WalletConnectSolanaSubmission) async {
        // Attempt submission before replying. On an ambiguous transport failure
        // the already committed signature remains pending and recoverable.
        if stored.state == "signed", case .solana(let input, _) = item.payload {
            do {
                _ = try await solanaClient(input.network).walletConnectSubmit(stored.signed, request: input)
                try await session?.vault.database().settleWalletConnectSolana(stored.id, outcome: .accepted)
            } catch {
                OathDiagnostics.record(error, component: "walletconnect", operation: "submit_solana", context: ["chain": "solana"])
            }
        }
        if session?.isUnlocked == true {
            completion = .init(peer: item.peer, walletID: item.walletID, account: item.account, isTransaction: true, solana: stored)
        }
        if pendingRequest?.operationID == item.operationID { pendingRequest = nil }
        respond(item.request, .response(AnyCodable(["signature": stored.signature])))
        resumeSolanaSubmissions()
    }
    /// Bounded foreground recovery also survives dismissal of the request sheet.
    /// iOS can suspend the app; the persisted queue resumes on the next unlock.
    private func resumeSolanaSubmissions() {
        guard solanaRecovery == nil, let session, session.isUnlocked else { return }
        solanaRecovery = Task {
            defer { solanaRecovery = nil }
            await OathDiagnostics.$chain.withValue("solana") {
                await OathDiagnostics.$operationID.withValue(UUID()) {
                    do {
                        let db = try await session.vault.database()
                        for _ in 0..<120 {
                            guard session.isUnlocked, !Task.isCancelled else { return }
                            let rows = try await db.pendingWalletConnectSolanaSubmissions()
                            if rows.isEmpty { return }
                            for row in rows {
                                guard session.wallets.contains(where: { $0.id == row.walletID }) else { continue }
                                do {
                                    guard let network = SolanaSendNetwork(walletConnectChain: row.chain) else { throw SolanaSendError.wrongNetwork }
                                    let client = try solanaClient(network)
                                    var outcome = try await client.walletConnectStatus(row.signature)
                                    if outcome == .unknown {
                                        let params = try JSONEncoder().encode(SolanaJSON.object(["transaction": .string(row.unsigned.base64EncodedString()),
                                            "sendOptions": .object(["minContextSlot": .number(String(row.minimumSlot))])]))
                                        let input = try WalletConnectSolanaRequest(method: "solana_signAndSendTransaction", chain: row.chain, account: row.owner, params: params)
                                        guard input.fingerprint == row.fingerprint else { throw SolanaSendError.changed }
                                        do {
                                            _ = try await client.walletConnectSubmit(row.signed, request: input); outcome = .accepted
                                        } catch {
                                            OathDiagnostics.record(error, component: "walletconnect", operation: "submit_solana", context: ["chain": "solana"])
                                            // Check finalized nonce state before declaring an
                                            // unknown submission expired. A durable nonce has no
                                            // time limit; only consumption/revocation invalidates it.
                                            if Date.now.timeIntervalSince1970 - row.createdAt > 600,
                                               try await client.walletConnectTransactionValid(input.transactions[0], minimumSlot: UInt64(row.minimumSlot), finalized: true) == false {
                                                outcome = try await client.walletConnectStatus(row.signature)
                                                if outcome == .unknown { outcome = .expired }
                                            }
                                        }
                                    }
                                    try await db.settleWalletConnectSolana(row.id, outcome: outcome)
                                    if completion?.solana?.id == row.id, completion?.solana?.state != outcome.rawValue {
                                        completion?.solana?.state = outcome.rawValue
                                        if outcome == .confirmed { OathHaptics.shared.play(.success) }
                                    }
                                    if outcome == .confirmed, network == .mainnet {
                                        await OathPostSendBalanceRefresh.shared.submitted(walletID: row.walletID, networkID: "solana")
                                    }
                                } catch is CancellationError { return }
                                catch { OathDiagnostics.record(error, component: "walletconnect", operation: "recover_solana", context: ["chain": "solana"]) }
                            }
                            try await Task.sleep(for: .seconds(5))
                        }
                    } catch is CancellationError { }
                    catch { OathDiagnostics.record(error, component: "walletconnect", operation: "solana_journal", context: ["chain": "solana"]) }
                }
            }
        }
    }
    private func prepareEVM(_ request: Request, peer: Session, walletID: String, account: String, generation: UUID) async {
        defer { if preparationGeneration == generation { preparationTask = nil; preparingItem = nil; preparingRequest = false } }
        func current() -> Bool { preparationGeneration == generation && !Task.isCancelled && authorized(request, walletID: walletID, account: account) }
        let network = EVMSendNetwork.allCases.first { String($0.chainID) == request.chainId.reference && !$0.isTestnet }
        await OathDiagnostics.$chain.withValue(network?.rawValue) {
            await OathDiagnostics.$operationID.withValue(generation) {
                do {
                    guard let session, let network, current(),
                          let record = await accounts(walletID: walletID).first(where: { $0.networkID == network.rawValue && $0.address.lowercased() == account.lowercased() }) else { throw WalletConnectEVMRequest.Failure.unsupported }
                    let input = try await Self.decodeEVM(try JSONEncoder().encode(request.params), chainID: network.chainID, account: account)
                    let database = try await session.vault.database()
                    let recoveringSigned = try await database.send(durableSendID(request))?.signedPayload != nil
                    async let tokenWork = OathDiagnostics.attemptOptional("walletconnect_approval_metadata") {
                        try await OathEVMSendService.shared.walletConnectApprovalToken(input)
                    }
                    // A relay replay recovers its committed transaction even after
                    // the original deposit or public swap quote has expired.
                    async let swapWork = recoveringSigned ? nil : Self.evmThorchainReview(input)
                    async let quoteWork = OathEVMSendService.shared.walletConnectQuote(input, requestID: durableSendID(request),
                        walletID: walletID, accountID: record.id, vault: session.vault)
                    let (quote, token, swap) = try await (quoteWork, tokenWork, swapWork)
                    guard current(), pendingRequest == nil else { return }
                    completion = nil; presentationIssue = nil
                    // Recover the exact amount previously approved if this is
                    // a replay of an already journaled, edited approval.
                    let reviewed: WalletConnectEVMRequest
                    if input.matches(quote.plan) { reviewed = input }
                    else if input.matchesCommittedApproval(quote.plan), let call = quote.plan.call {
                        reviewed = try input.replacingApprovalAmount(AnkrQuantity.decimal("0x" + call.bytes.suffix(32).map { String(format: "%02x", $0) }.joined()))
                    } else { throw EVMSendError.changed }
                    pendingRequest = .init(request: request, peer: peer, walletID: walletID, account: account,
                        payload: .evm(reviewed, quote), approvalToken: token, thorchainSwap: swap)
                } catch is CancellationError { }
                catch {
                    guard current() else { return }
                    // Peer format errors are expected protocol validation, not app failures.
                    if !(error is WalletConnectEVMRequest.Failure) && !(error is WalletConnectJSON.Failure) {
                        OathDiagnostics.record(error, component: "walletconnect", operation: "prepare_transaction")
                    }
                    if error is SendFeeFundingError {
                        presentationIssue = .gas(network:network?.rawValue ?? "",address:account)
                    } else { switch error as? EVMSendError {
                    case .insufficientFunds: presentationIssue = .gas(network: network?.rawValue ?? "", address: account)
                    case .simulationFailed: presentationIssue = .simulation
                    case .changed, .metadataChanged: presentationIssue = .changed
                    case .expired: presentationIssue = .expired
                    default: presentationIssue = error is WalletConnectEVMRequest.Failure ? .unsupported : .unavailable
                    } }
                    respondError(request, code: error is WalletConnectEVMRequest.Failure ? 4200 : -32000)
                }
            }
        }
    }
    @concurrent nonisolated private static func decodeEVM(_ data: Data, chainID: UInt64, account: String) async throws -> WalletConnectEVMRequest {
        try Task.checkCancellation()
        return try .init(params: data, account: account, chainID: chainID)
    }
    private func prepareThorchain(_ request: Request, peer: Session, walletID: String, account: String, generation: UUID) async {
        defer { if preparationGeneration == generation { preparationTask = nil; preparingItem = nil; preparingRequest = false } }
        func current() -> Bool { preparationGeneration == generation && !Task.isCancelled && authorized(request, walletID: walletID, account: account) }
        await OathDiagnostics.$chain.withValue("thorchain") {
            await OathDiagnostics.$operationID.withValue(generation) {
                do {
                    guard let session, current(),
                          let record = await accounts(walletID: walletID).first(where: { $0.networkID == "thorchain" && $0.address == account }) else { throw ConfigurationFailure.invalid }
                    // The Cosmos WalletConnect account/signature schema here is
                    // single-key only; never expose a multisig as a scalar signer.
                    guard try await session.vault.thorchainMultisigPolicy(walletID: walletID) == nil else {
                        throw ThorchainWalletConnectRequest.Failure.unsupported
                    }
                    let publicKey = try await session.vault.thorchainPublicKey(walletID: walletID, accountID: record.id)
                    if request.method == "cosmos_getAccounts" {
                        guard current() else { return }
                        respond(request, .response(AnyCodable([["address": account, "algo": "secp256k1", "pubkey": publicKey.base64EncodedString()]])))
                        return
                    }
                    let data = try JSONEncoder().encode(request.params)
                    let plan = try await Self.decodeThorchain(method: request.method, data: data, account: account, publicKey: publicKey)
                    let review = try await Self.thorchainReview(plan)
                    guard current(), pendingRequest == nil else { return }
                    pendingRequest = .init(request: request, peer: peer, walletID: walletID, account: account, payload: .thorchain(plan, review))
                } catch is CancellationError { }
                catch {
                    // Dismissal/lock/expiry that wins an await is expected teardown.
                    guard current() else { return }
                    // Malformed/unsupported peer requests are expected protocol
                    // validation. Do not upload their contents or decoder paths.
                    if !(error is ThorchainWalletConnectRequest.Failure) && !(error is WalletConnectJSON.Failure) {
                        OathDiagnostics.record(error, component: "walletconnect", operation: "prepare_thorchain")
                    }
                    let issue = ThorchainWalletConnectIssue(error)
                    respondError(request, code: issue.rpcCode)
                    failed = false
                    switch issue {
                    case .invalid: presentationIssue = .invalid
                    case .unsupported: presentationIssue = .unsupported
                    case .changed: presentationIssue = .changed
                    case .expired: presentationIssue = .expired
                    case .funding: presentationIssue = .gas(network: "thorchain", address: account)
                    case .unavailable: presentationIssue = .unavailable
                    }
                }
            }
        }
    }
    @concurrent nonisolated private static func decodeThorchain(method: String, data: Data, account: String, publicKey: Data) async throws -> ThorchainWalletConnectRequest {
        try Task.checkCancellation()
        return try ThorchainWalletConnectRequest(method: method, params: WalletConnectJSON.decode(data), sender: account, publicKey: publicKey)
    }
    @concurrent nonisolated private static func thorchainReview(_ request: ThorchainWalletConnectRequest, approvedQuote: ThorchainSwapQuote? = nil) async throws -> ThorchainWalletConnectReview {
        // Resolve shortened token names against current pools before validating
        // the destination. The immutable signing document remains untouched.
        if request.recipient == nil, request.coins.count == 1, request.coins[0].reference == "native" {
            // Keep the reviewed estimate through its stated lifetime. Refreshing
            // it after every PIN entry can create an endless re-review loop on
            // a moving pool. The exact signed minimum still protects execution.
            if let approvedQuote, approvedQuote.expires > .now, approvedQuote.memo.rawValue == request.memo,
               approvedQuote.input == request.coins[0].amount {
                async let account = ThorchainSendClient().walletConnectReview(request)
                async let resolved = ThorchainClient().resolvedSwapMemo(request.memo)
                let (review, memo) = try await (account, resolved)
                guard memo == approvedQuote.memo else { throw ThorchainSendError.changed }
                return .init(fee: review.fee, decimals: review.decimals, checkedAt: review.checkedAt, swap: approvedQuote)
            }
            async let account = ThorchainSendClient().walletConnectReview(request)
            async let quote = ThorchainClient().walletConnectSwapQuote(request)
            let (review, swap) = try await (account, quote)
            if let memo = swap?.memo {
                guard let network = OathImportChain(rawValue: memo.networkID),
                      OathScanAddress.decode(memo.destination, chain: network) != nil else { throw ThorchainWalletConnectRequest.Failure.invalidRequest }
            }
            return .init(fee: review.fee, decimals: review.decimals, checkedAt: review.checkedAt, swap: swap)
        }
        return try await ThorchainSendClient().walletConnectReview(request)
    }
    @concurrent nonisolated private static func decodeTypedData(_ data: Data, chainID: UInt64, account: String) async throws -> WalletConnectTypedData {
        try Task.checkCancellation()
        return try WalletConnectTypedData(json: data, chainID: chainID, account: account)
    }
    @concurrent nonisolated private static func evmThorchainReview(_ request: WalletConnectEVMRequest) async throws -> ThorchainEVMSwapReview? {
        guard let deposit = ThorchainEVMDeposit(request),
              let source = EVMSendNetwork.allCases.first(where: { $0.chainID == request.chainID }) else { return nil }
        let client = try await OathEVMSendService.shared.connection(source)
        let decimals = try await client.thorchainDepositDecimals(deposit)
        guard let review = try await ThorchainClient().walletConnectEVMSwapReview(deposit, decimals: decimals) else { return nil }
        let memo = review.quote.memo
        guard let destination = OathImportChain(rawValue: memo.networkID),
              OathScanAddress.decode(memo.destination, chain: destination) != nil else { throw WalletConnectEVMRequest.Failure.malformed }
        return review
    }
    func reviseApproval(amount: String) async throws {
        guard let item = pendingRequest, let session, !signingRequest, !revisingTransaction,
              case .evm(let input, let oldQuote) = item.payload, item.approvalToken != nil,
              authorized(item.request, walletID: item.walletID, account: item.account) else { throw EVMSendError.changed }
        revisingTransaction = true
        defer { revisingTransaction = false }
        // A submitted request is immutable, including when the relay retries.
        let db = try await session.vault.database()
        guard try await db.send(durableSendID(item.request))?.signedPayload == nil else { throw EVMSendError.changed }
        let revised = try input.replacingApprovalAmount(amount)
        let quote = try await OathEVMSendService.shared.walletConnectQuote(revised, requestID: durableSendID(item.request),
            walletID: item.walletID, accountID: oldQuote.accountID, vault: session.vault)
        guard !Task.isCancelled, pendingRequest?.operationID == item.operationID,
              authorized(item.request, walletID: item.walletID, account: item.account), revised.matches(quote.plan) else { throw CancellationError() }
        pendingRequest?.payload = .evm(revised, quote)
    }
    func sign(digits: [UInt8]?, reason: String) async throws {
        guard !revisingTransaction else { throw EVMSendError.busy }
        guard !signingRequest, let item = pendingRequest, let session, session.isUnlocked,
              sessions.contains(where: { $0.topic == item.request.topic && $0.expiryDate > .now }),
              requestDeadline(item.request) > Date.now.timeIntervalSince1970 else { throw ConfigurationFailure.invalid }
        signingRequest = true
        defer {
            signingRequest = false
            // The next permit/swap can arrive before the response await ends.
            // Replay the SDK queue once signing has released the active review.
            Task { @MainActor [weak self] in self?.resumeRequests() }
        }
        if case .networkSwitch(let target) = item.payload {
            try await approveNetworkSwitch(item, target: target)
            return
        }
        let records = await accounts(walletID: item.walletID)
        guard let record = records.first(where: {
            Self.accountMatches($0.address, item.account, chain: item.request.chainId) && Self.blockchains(networkID: $0.networkID).contains(item.request.chainId)
        }) else { throw ConfigurationFailure.invalid }
        guard authorized(item.request, walletID: item.walletID, account: item.account) else { throw CancellationError() }
        let response: AnyCodable
        var transaction: TransactionCompletion?
        switch item.payload {
        case .networkSwitch: throw ConfigurationFailure.invalid
        case .evm(let input, let quote):
            guard input.matches(quote.plan) else { throw EVMSendError.changed }
            let operationID = item.operationID
            let sendID = durableSendID(item.request)
            if let swap = item.thorchainSwap {
                let db = try await session.vault.database()
                if try await db.send(sendID)?.signedPayload == nil {
                    if let expiry = swap.deposit.expiry, Double(expiry) <= Date.now.timeIntervalSince1970 { throw EVMSendError.expired }
                    if swap.quote.expires <= .now {
                        try await refreshEVMReview(item, input: input, quote: quote)
                        throw ReviewFailure.quoteUpdated
                    }
                }
            }
            let result: OathBitcoinSubmission
            do {
                result = try await OathEVMSendService.shared.submit(quote, vault: session.vault, digits: digits, reason: reason,
                    walletConnectRequestID: sendID, authorization: { [weak self] in
                        try await self?.validateTransactionAuthorization(operationID: operationID)
                        guard self != nil else { throw CancellationError() }
                    })
            } catch {
                // diagnostics: walletconnect-signing-propagation. The submit
                // service records the original failure before an unsigned
                // review is refreshed; other errors propagate to the sheet.
                // Expected cancellation/PIN fallback stays excluded there.
                // Teardown defers its response while signing. Only the durable
                // submission owner can tell whether any bytes were committed.
                if pendingRequest?.operationID != operationID { respondError(item.request, code: 4001) }
                else if error as? EVMSendError == .expired || error as? EVMSendError == .changed {
                    // Re-quote the same unsigned intent and require another
                    // confirmation. Never silently sign newly estimated fees.
                    try await refreshEVMReview(item, input: input, quote: quote)
                    throw ReviewFailure.quoteUpdated
                }
                throw error
            }
            response = AnyCodable(result.txid)
            transaction = .init(sendID: sendID, hash: result.txid, plan: quote.plan,
                action: WalletConnectEVMAction(input), approvalToken: item.approvalToken)
            // The transaction is irrevocably journaled at this point. A lock,
            // dismissal or relay failure cannot turn it into a user rejection.
            // An independent response task survives cancellation of the sheet; on
            // retry the same request recovers this hash, never a new nonce.
            if pendingRequest?.operationID == operationID, session.isUnlocked {
                completion = .init(peer: item.peer, walletID: item.walletID, account: item.account,
                    isTransaction: true, transaction: transaction)
            }
            if pendingRequest?.operationID == operationID { pendingRequest = nil }
            respond(item.request, .response(response))
            return
        case .bitcoin(let input, let plan, let address):
            let db = try await session.vault.database(), sendID = durableSendID(item.request)
            if let stored = try await db.walletConnectBitcoinSubmission(sendID) {
                guard stored.fingerprint == input.fingerprint, stored.walletID == item.walletID else { throw BitcoinConnectError.changed }
                await finishBitcoinSubmission(item,stored:stored); return
            }
            if let plan {
                do { try await BitcoinConnectClient().preflight(plan) }
                catch {
                    // diagnostics: walletconnect-signing-propagation. The sheet reports failures; expired reviews require new consent.
                    if error as? BitcoinConnectError == .expired || (input.method == "sendTransfer" && error as? BitcoinConnectError == .changed) {
                        let addresses = try await db.walletConnectBitcoinAddresses(accountID:record.id)
                        let change = try await db.bitcoinChangeAddress(accountID:record.id)
                        let updated = try await BitcoinConnectClient().review(input,addresses:addresses,change:change)
                        try validateTransactionAuthorization(operationID:item.operationID)
                        pendingRequest?.payload = .bitcoin(input,updated,nil)
                        throw ReviewFailure.quoteUpdated
                    }
                    throw error
                }
            }
            try validateTransactionAuthorization(operationID:item.operationID)
            let signed = try await session.vault.signWalletConnectBitcoin(walletID:item.walletID,accountID:record.id,
                request:input,plan:plan,address:address,digits:digits,reason:reason)
            try validateTransactionAuthorization(operationID:item.operationID)
            try Task.checkCancellation()
            switch signed {
            case .transaction(let value):
                guard let plan else { throw BitcoinConnectError.changed }
                if input.broadcasts {
                    let stored = try await db.journalWalletConnectBitcoin(id:sendID,walletID:item.walletID,accountID:record.id,plan:plan,signed:value)
                    await finishBitcoinSubmission(item,stored:stored); return
                }
                response = AnyCodable(["psbt":value.psbt])
            case .message(let value): response = AnyCodable(value)
            }
        case .nearAccess(let access, let review):
            let db = try await session.vault.database(), id = durableSendID(item.request)
            if let stored = try await db.walletConnectNearSubmission(id) {
                guard stored.fingerprint == access.fingerprint, stored.walletID == item.walletID,
                      stored.topic == item.request.topic else { throw NearSendError.changed }
                await finishNearSubmission(item,stored:stored); return
            }
            let key = try await session.vault.nearPublicKey(walletID:item.walletID,accountID:record.id)
            let client = try nearClient(access.network)
            let grants = try await db.walletConnectNearGrants(walletID:item.walletID,accountID:record.id,topic:item.request.topic,chain:access.network.walletConnectChain)
            let refreshed = try await client.walletConnectAccessReview(access,publicKey:key,grants:grants)
            do { try await client.walletConnectPreflight(review,publicKey:key) }
            catch {
                // diagnostics: walletconnect-signing-propagation. Refreshes need fresh consent; other errors reach the shared signing boundary.
                if error as? NearSendError == .expired || error as? NearSendError == .changed {
                    try validateTransactionAuthorization(operationID:item.operationID)
                    pendingRequest?.payload = .nearAccess(access,refreshed); throw ReviewFailure.updated
                }
                throw error
            }
            try access.validate(review)
            try validateTransactionAuthorization(operationID:item.operationID)
            let response = try await session.vault.signWalletConnectNear(walletID:item.walletID,accountID:record.id,
                request:review.request,review:review,digits:digits,reason:reason)
            try validateTransactionAuthorization(operationID:item.operationID)
            try Task.checkCancellation()
            let signed = try WalletConnectNearAccess.signed(response,review:review)
            let stored = try await db.journalWalletConnectNear(id:id,walletID:item.walletID,accountID:record.id,
                topic:item.request.topic,access:access,plan:review,signed:signed)
            await finishNearSubmission(item,stored:stored); return
        case .xrpl(let input, let review):
            let db = try await session.vault.database(), id = durableSendID(item.request)
            if input.broadcasts, let stored = try await db.walletConnectXrplSubmission(id) {
                guard stored.fingerprint == input.fingerprint, stored.walletID == item.walletID else { throw XrplSendError.changed }
                await finishXrplSubmission(item,stored:stored); return
            }
            try await xrplClient(input.network).walletConnectPreflight(review)
            try validateTransactionAuthorization(operationID:item.operationID)
            let signed = try await session.vault.signWalletConnectXrpl(walletID:item.walletID,accountID:record.id,
                request:input,review:review,digits:digits,reason:reason)
            try validateTransactionAuthorization(operationID:item.operationID)
            try Task.checkCancellation()
            if input.broadcasts {
                let stored = try await db.journalWalletConnectXrpl(id:id,walletID:item.walletID,accountID:record.id,plan:review,signed:signed)
                await finishXrplSubmission(item,stored:stored); return
            }
            response = AnyCodable(signed.response)
        case .stellar(let input, let review):
            let db = try await session.vault.database(), id = durableSendID(item.request)
            if input.broadcasts, let stored = try await db.walletConnectStellarSubmission(id) {
                guard stored.fingerprint == input.fingerprint, stored.walletID == item.walletID else { throw StellarSendError.changed }
                await finishStellarSubmission(item,stored:stored); return
            }
            try await stellarClient(input.network).walletConnectPreflight(review)
            try validateTransactionAuthorization(operationID:item.operationID)
            let signed = try await session.vault.signWalletConnectStellar(walletID:item.walletID,accountID:record.id,
                request:input,review:review,digits:digits,reason:reason)
            try validateTransactionAuthorization(operationID:item.operationID)
            try Task.checkCancellation()
            if input.broadcasts {
                let stored = try await db.journalWalletConnectStellar(id:id,walletID:item.walletID,accountID:record.id,plan:review,signed:signed)
                await finishStellarSubmission(item,stored:stored); return
            }
            response = AnyCodable(signed.response)
        case .near(let input, let review):
            let key = try await session.vault.nearPublicKey(walletID:item.walletID,accountID:record.id)
            try await nearClient(input.network).walletConnectPreflight(review,publicKey:key)
            try validateTransactionAuthorization(operationID:item.operationID)
            let signed = try await session.vault.signWalletConnectNear(walletID:item.walletID,accountID:record.id,
                request:input,review:review,digits:digits,reason:reason)
            try validateTransactionAuthorization(operationID:item.operationID)
            response = AnyCodable(signed)
        case .sui(let input, let review):
            let db = try await session.vault.database(), id = durableSendID(item.request)
            if input.broadcasts, let stored = try await db.walletConnectSuiSubmission(id) {
                guard stored.fingerprint == input.fingerprint, stored.walletID == item.walletID else { throw SuiSendError.changed }
                await finishSuiSubmission(item,stored:stored); return
            }
            if let review {
                do { try await suiClient(input.network).walletConnectPreflight(review) }
                catch {
                    // diagnostics: walletconnect-signing-propagation. The sheet records other signing errors; changed previews require fresh consent.
                    if error as? SuiSendError == .changed || error as? SuiSendError == .expired {
                        let updated = try await suiClient(input.network).walletConnectReview(input)
                        try validateTransactionAuthorization(operationID:item.operationID)
                        pendingRequest?.payload = .sui(input,updated); throw ReviewFailure.updated
                    }
                    throw error
                }
            }
            try validateTransactionAuthorization(operationID:item.operationID)
            let signed = try await session.vault.signWalletConnectSui(walletID:item.walletID,accountID:record.id,
                request:input,review:review,digits:digits,reason:reason)
            try validateTransactionAuthorization(operationID:item.operationID)
            try Task.checkCancellation()
            if input.broadcasts, let review, let transaction = signed.transaction {
                let stored = try await db.journalWalletConnectSui(id:id,walletID:item.walletID,accountID:record.id,plan:review,signed:transaction)
                await finishSuiSubmission(item,stored:stored); return
            }
            response = AnyCodable(signed.response)
        case .polkadot(let input, let review):
            if let review { try await PolkadotConnectClient(network:input.network).preflight(review) }
            try validateTransactionAuthorization(operationID:item.operationID)
            let signed = try await session.vault.signWalletConnectPolkadot(walletID:item.walletID, accountID:record.id,
                request:input, review:review, digits:digits, reason:reason)
            try validateTransactionAuthorization(operationID:item.operationID)
            response = AnyCodable(signed)
        case .tron(let input, let review):
            if let review { try await tronClient(input.network).walletConnectPreflight(review) }
            try validateTransactionAuthorization(operationID:item.operationID)
            let signed = try await session.vault.signWalletConnectTron(walletID:item.walletID, accountID:record.id,
                request:input, review:review, digits:digits, reason:reason)
            try validateTransactionAuthorization(operationID:item.operationID)
            response = AnyCodable(signed)
        case .ton(let input, let plan):
            let db = try await session.vault.database(), sendID = durableSendID(item.request)
            if input.broadcasts, let stored = try await db.walletConnectTonSubmission(sendID) {
                guard stored.fingerprint == input.fingerprint, stored.walletID == item.walletID else { throw TonSendError.changed }
                await finishTonSubmission(item, stored: stored); return
            }
            if let plan {
                do { try await tonClient(input.network).walletConnectPreflight(plan) }
                catch {
                    // diagnostics: walletconnect-signing-propagation. A stale
                    // unsigned review is refreshed; the sheet records other failures.
                    if [.expired, .changed, .feeTooHigh].contains(where: { $0 == error as? TonSendError }) {
                        let updated = try await tonClient(input.network).walletConnectReview(input, publicKey: plan.publicKey)
                        try validateTransactionAuthorization(operationID: item.operationID)
                        pendingRequest?.payload = .ton(input, updated)
                        throw ReviewFailure.quoteUpdated
                    }
                    throw error
                }
            }
            try validateTransactionAuthorization(operationID: item.operationID)
            let signed = try await session.vault.signWalletConnectTon(walletID: item.walletID, accountID: record.id,
                request: input, plan: plan, digits: digits, reason: reason)
            try validateTransactionAuthorization(operationID: item.operationID)
            try Task.checkCancellation()
            switch signed {
            case .transaction(let bytes):
                guard let plan else { throw TonSendError.changed }
                let stored = try await db.journalWalletConnectTon(id: sendID, walletID: item.walletID, accountID: record.id, plan: plan, signed: bytes)
                await finishTonSubmission(item, stored: stored); return
            case .data(let data): response = AnyCodable(data)
            }
        case .solana(let input, let reviews):
            do {
                let client = try solanaClient(input.network)
                let db = try await session.vault.database(), sendID = durableSendID(item.request)
                if input.broadcasts, let stored = try await db.walletConnectSolanaSubmission(sendID) {
                    guard stored.fingerprint == input.fingerprint, stored.walletID == item.walletID else { throw SolanaSendError.changed }
                    await finishSolanaSubmission(item, stored: stored); return
                }
                let latest = try await client.walletConnectReview(input)
                guard authorized(item.request, walletID: item.walletID, account: item.account), pendingRequest?.operationID == item.operationID else { throw CancellationError() }
                guard zip(latest, reviews).allSatisfy({ $0.fee == $1.fee && $0.changes == $1.changes && $0.programs == $1.programs }), latest.count == reviews.count else {
                    pendingRequest?.payload = .solana(input, latest); throw ReviewFailure.updated
                }
                let signed = try await session.vault.signWalletConnectSolana(walletID: item.walletID, accountID: record.id, request: input, digits: digits, reason: reason)
                try validateTransactionAuthorization(operationID: item.operationID)
                try Task.checkCancellation()
                if input.broadcasts {
                    // Persistence is the commit boundary. From here the exact signed
                    // bytes are recoverable even if the relay, UI or app is interrupted.
                    let stored = try await db.journalWalletConnectSolana(id: sendID, walletID: item.walletID, accountID: record.id, request: input, signed: signed.transactions[0])
                    await finishSolanaSubmission(item, stored: stored); return
                }
                response = AnyCodable(signed.response)
            } catch {
                // diagnostics: walletconnect-signing-propagation. The sheet records
                // the original error; cancellation, PIN fallback and refreshed
                // consent are expected there. Before the journal commit, dismissal
                // is an unsigned rejection. Committed sends return above.
                if input.broadcasts, pendingRequest?.operationID != item.operationID { respondError(item.request, code: 4001) }
                throw error
            }
        case .message(let message, let signIn):
            try signIn?.validateTime()
            response = AnyCodable(try await session.vault.signWalletConnectMessage(walletID: item.walletID, accountID: record.id,
                message: message, digits: digits, reason: reason))
        case .typedData(let data):
            guard data.chainID == nil || data.chainID == item.request.chainId.reference else { throw WalletConnectTypedData.Failure.wrongChain }
            response = AnyCodable(try await session.vault.signWalletConnectTypedData(walletID: item.walletID, accountID: record.id,
                data: data, digits: digits, reason: reason))
        case .thorchain(let request, let review):
            let latest = try await Self.thorchainReview(request, approvedQuote: review.swap)
            guard latest.fee == review.fee, latest.decimals == review.decimals,
                  authorized(item.request, walletID: item.walletID, account: item.account) else { throw ThorchainSendError.changed }
            if let previous = review.swap {
                guard let current = latest.swap, previous.expires > .now,
                      current.expectedOutput == previous.expectedOutput,
                      current.outboundFee == previous.outboundFee, current.liquidityFee == previous.liquidityFee,
                      current.affiliateFee == previous.affiliateFee else {
                    pendingRequest?.payload = .thorchain(request, latest)
                    throw ReviewFailure.updated
                }
            }
            let signature = try await session.vault.signThorchainWalletConnect(walletID: item.walletID, accountID: record.id,
                request: request, digits: digits, reason: reason)
            response = AnyCodable(signature)
        }
        guard pendingRequest?.id == item.id, pendingRequest?.request.topic == item.request.topic, session.isUnlocked,
              requestDeadline(item.request) > Date.now.timeIntervalSince1970,
              walletMapping[item.request.topic] == item.walletID,
              Sign.instance.getSessions().contains(where: { $0.topic == item.request.topic && $0.expiryDate > .now }) else { throw CancellationError() }
        try Task.checkCancellation()
        guard authorized(item.request, walletID: item.walletID, account: item.account) else { throw CancellationError() }
        if case .message(_, let signIn) = item.payload { try signIn?.validateTime() }
        if case .typedData(let data) = item.payload { try data.validatePermissionTime() }
        try await Sign.instance.respond(topic: item.request.topic, requestId: item.request.id, response: .response(response))
        // Relay completion can race a lock or dismissal. Never restore stale UI.
        if pendingRequest?.id == item.id, session.isUnlocked {
            completion = .init(peer: item.peer, walletID: item.walletID, account: item.account, isTransaction: item.isTransaction, transaction: transaction)
        }
        pendingRequest = nil; pruneRequestDeadlines(); OathHaptics.shared.play(.success)
    }
    private func validateTransactionAuthorization(operationID: UUID) throws {
        guard let item = pendingRequest, item.operationID == operationID,
              authorized(item.request, walletID: item.walletID, account: item.account) else { throw CancellationError() }
    }
    private func refreshEVMReview(_ item: PendingRequest, input: WalletConnectEVMRequest, quote: OathEVMQuote) async throws {
        do {
            try validateTransactionAuthorization(operationID: item.operationID)
            guard let session else { throw CancellationError() }
            let db = try await session.vault.database()
            let id = durableSendID(item.request)
            guard try await db.send(id)?.signedPayload == nil else { throw EVMSendError.changed }
            async let swapWork = Self.evmThorchainReview(input)
            async let quoteWork = OathEVMSendService.shared.walletConnectQuote(input, requestID: id,
                walletID: item.walletID, accountID: quote.accountID, vault: session.vault)
            let (updated, swap) = try await (quoteWork, swapWork)
            try Task.checkCancellation()
            try validateTransactionAuthorization(operationID: item.operationID)
            guard input.matches(updated.plan), try await db.send(id)?.signedPayload == nil else { throw EVMSendError.changed }
            pendingRequest?.payload = .evm(input, updated)
            pendingRequest?.thorchainSwap = swap
        } catch {
            OathDiagnostics.record(error, component: "walletconnect", operation: "refresh_transaction_review")
            throw error
        }
    }
    private func approveNetworkSwitch(_ item: PendingRequest, target: UInt64) async throws {
        guard session != nil, let chain = Blockchain("eip155:\(target)"),
              pendingRequest?.operationID == item.operationID,
              authorized(item.request, walletID: item.walletID, account: item.account),
              let peer = Sign.instance.getSessions().first(where: { $0.topic == item.request.topic }),
              let account = peer.accounts.first(where: { $0.blockchain == chain }),
              let network = OathImportChain.allCases.first(where: { Self.blockchain($0) == chain }) else { throw ConfigurationFailure.invalid }
        let owned = await accounts(walletID: item.walletID)
        guard pendingRequest?.operationID == item.operationID,
              authorized(item.request, walletID: item.walletID, account: item.account),
              owned.contains(where: { $0.networkID == network.id && $0.address.lowercased() == account.address.lowercased() }) else { throw CancellationError() }
        connections.selectChain(target, for: item.request.topic)
        // Cancel old-chain prompts. A change of default network must not leave
        // an earlier confirmation waiting behind the newly selected network.
        for queued in Sign.instance.getPendingRequests() where queued.request.topic == item.request.topic && queued.request != item.request && queued.request.chainId != chain {
            respondError(queued.request, code: 4100)
        }
        pendingRequest = nil
        completion = .init(peer: peer, walletID: item.walletID, account: account.address, isTransaction: false, selectedChain: target)
        respond(item.request, .response(AnyCodable(nil as String?)))
        // Events are only sent if negotiated. Response delivery and the locally
        // committed selection survive a view dismissal independently.
        let events = peer.namespaces["eip155"]?.events ?? peer.namespaces[chain.absoluteString]?.events ?? []
        Task {
            do {
                if events.contains("chainChanged") {
                    try await Sign.instance.emit(topic: item.request.topic, event: .init(name: "chainChanged", data: AnyCodable("0x" + String(target, radix: 16))), chainId: chain)
                }
                if events.contains("accountsChanged"), account.address.lowercased() != item.account.lowercased() {
                    try await Sign.instance.emit(topic: item.request.topic, event: .init(name: "accountsChanged", data: AnyCodable([account.address])), chainId: chain)
                }
            } catch { OathDiagnostics.record(error, component: "walletconnect", operation: "network_changed_event") }
        }
    }
    func trackTransactionCompletion(presentationID: UUID) async {
        guard let transaction = completion?.transaction, let session else { return }
        func isCurrent() -> Bool {
            !Task.isCancelled && presentationOpen && self.presentationID == presentationID && session.isUnlocked
                && completion?.transaction?.sendID == transaction.sendID
        }
        await OathDiagnostics.$chain.withValue(transaction.plan.network.rawValue) {
            await OathDiagnostics.$operationID.withValue(UUID()) {
                // No timer or age limit on UI observation. The app-lifetime
                // worker owns RPC checks, retries, suspension and relaunch.
                while isCurrent() {
                    do {
                        let db = try await session.vault.database()
                        for try await progress in db.observeSendProgress(sendID: transaction.sendID) {
                            guard isCurrent(), let progress else { return }
                            let confirmed = completion?.transaction?.progress.update(progress) == true
                            if confirmed { OathHaptics.shared.play(.success) }
                        }
                        return
                    } catch is CancellationError { return } // Screen/foreground subscription ended.
                    catch {
                        guard isCurrent() else { return }
                        OathDiagnostics.record(error, component: "walletconnect", operation: "completion_state")
                        // A read failure leaves the last known state intact and
                        // retries at a bounded rate; it is not a failed send.
                        do { try await Task.sleep(for: .seconds(15)) }
                        catch { return } // Canceled retry, not an app failure.
                    }
                }
            }
        }
    }
    func invalidateRequest(_ issue: PresentationIssue) {
        rejectRequest(); presentationIssue = issue
    }
    func declineRequest() {
        guard pendingRequest != nil, !signingRequest else { return }
        rejectRequest(); presentationIssue = .declined
    }
    var needsPresentation: Bool { pendingRequest != nil || preparingRequest || presentationIssue != nil }
    private func canHandoffCompletion(_ id: UUID, presentationID: UUID) -> Bool {
        guard OathWalletConnectPolicy.CompletionHandoff.canReplace(owner: presentationOwner,
                  presentationID: presentationID, completionID: completion?.id,
                  expectedID: id, requestedID: completionHandoffRequested),
              session?.isUnlocked == true, !working, !signingRequest, pendingRequest == nil,
              !preparingRequest, proposal == nil, presentationIssue == nil else { return false }
        return true
    }
    func handoffCompletion(_ id: UUID, presentationID: UUID) {
        guard canHandoffCompletion(id, presentationID: presentationID),
              let topic = completion?.peer.topic else { return }
        // No suspension between checking ownership and entering receive().
        // Invalid/expired requests cannot erase the receipt; a valid request
        // still requires its own review and signing authorization.
        for item in Sign.instance.getPendingRequests().prefix(8) where
            item.request.topic == topic && OathWalletConnectPolicy.approvalMethods.contains(item.request.method) {
            receive(item.request, context: item.context, replacingCompletion: id)
            if completion?.id != id || pendingRequest != nil || preparingRequest || presentationIssue != nil { return }
        }
        completionHandoffRequested = nil
    }
    @discardableResult func presentationDidOpen(_ id: UUID) -> Bool {
        presentationOwner.claim(id)
    }
    func presentationWillDismiss(_ id: UUID) {
        presentationOwner.beginDismissal(id)
    }
    func presentationDidDismiss(_ id: UUID) {
        guard presentationOwner.id == id else { return }
        rejectRequest()
        // Clear pairing state synchronously, before resuming another request.
        // The relay response may finish later without touching the next sheet.
        let rejected = cancelPairing()
        completionHandoffRequested = nil
        completion = nil; presentationIssue = nil; connectionFailure = nil; connectedTopic = nil; failed = false
        _ = presentationOwner.release(id)
        Task { await rejectProposal(rejected) }
        resumeRequests()
    }
    func rejectRequest() {
        if let preparingItem { cancelPreparation(); respondError(preparingItem, code: 4001) }
        guard let pendingRequest else { return }
        self.pendingRequest = nil
        if signingRequest, pendingRequest.broadcasts {
            // Invalidate pre-commit authorization immediately, but let sign()
            // report either the committed hash or an unsigned rejection.
            return
        }
        respondError(pendingRequest.request, code: 4001)
    }
    private func pruneRequestDeadlines() {
        let pending = Set(Sign.instance.getPendingRequests().map { item in
            Data(SHA256.hash(data: Data((item.request.topic + ":" + item.request.id.string).utf8))).map { String(format: "%02x", $0) }.joined()
        })
        let deadlines = UserDefaults.standard.dictionary(forKey: "walletconnect.requestDeadlines") as? [String: Double] ?? [:]
        UserDefaults.standard.set(deadlines.filter { pending.contains($0.key) }, forKey: "walletconnect.requestDeadlines")
    }
    private func respondError(_ request: Request, code: Int) {
        let code = request.chainId.namespace == "ton" ? (code == 4001 ? 300 : code == 4200 ? 400 : code < 0 || code == 4100 ? 1 : code) : code
        respond(request, .error(.init(code: code, message: code == 4200 ? "Unsupported method" : "Request rejected")))
    }
    private func requestKey(_ request: Request) -> String { request.topic + ":" + request.id.string }
    private func respond(_ request: Request, _ response: RPCResult) {
        let key = requestKey(request)
        guard responsesInFlight.insert(key).inserted else { return }
        Task {
            defer {
                responsesInFlight.remove(key)
            }
            do { try await Sign.instance.respond(topic: request.topic, requestId: request.id, response: response)
                pruneRequestDeadlines()
                responsesInFlight.remove(key)
                // Read requests may precede sign-in in the same open sheet.
                // The presentation gate preserves any active consent/result.
                resumeRequests()
            }
            catch { OathDiagnostics.$operationID.withValue(operation) { OathDiagnostics.record(error, component: "walletconnect", operation: "respond") } }
        }
    }
}

extension OathWalletConnectService {
    private func tonClient(_ network: TonSendNetwork) throws -> TonSendClient {
        if let client = tonClients[network.rawValue] { return client }
        let client = try OathTokenRPCConfiguration.bundled().makeTonSendClient(network: network)
        tonClients[network.rawValue] = client
        return client
    }
    @concurrent nonisolated private static func decodeTon(method: String, chain: String, account: String, domain: String, params: Data, now: Date = .now) async throws -> WalletConnectTonRequest {
        try WalletConnectTonRequest(method: method, chain: chain, account: account, domain: domain, params: params, now: now)
    }
    private func prepareTon(_ request: Request, peer: Session, walletID: String, account: String, generation: UUID) async {
        defer { if preparationGeneration == generation { preparationTask = nil; preparingItem = nil; preparingRequest = false } }
        await OathDiagnostics.$chain.withValue("ton") {
            await OathDiagnostics.$operationID.withValue(generation) {
                do {
                    guard let session, let domain = OathWalletConnectPolicy.safeHost(peer.peer.url) else { throw TonSendError.malformed }
                    let db = try await session.vault.database()
                    let stored = try await db.walletConnectTonSubmission(durableSendID(request))
                    let input = try await Self.decodeTon(method: request.method, chain: request.chainId.absoluteString, account: account,
                        domain: domain, params: JSONEncoder().encode(request.params), now: stored.map { Date(timeIntervalSince1970: $0.createdAt) } ?? .now)
                    if let stored {
                        guard stored.fingerprint == input.fingerprint, stored.walletID == walletID,
                              preparationGeneration == generation, authorized(request, walletID: walletID, account: account) else { throw TonSendError.changed }
                        await finishTonSubmission(.init(request:request, peer:peer, walletID:walletID, account:account, payload:.ton(input,nil)), stored:stored)
                        return
                    }
                    var plan: WalletConnectTonPlan?
                    if input.broadcasts {
                        let records = await accounts(walletID: walletID)
                        guard let record = records.first(where: { $0.networkID == "ton" && Self.accountMatches($0.address, account, chain:request.chainId) }) else { throw TonSendError.wrongOwner }
                        let key = try await session.vault.tonPublicKey(walletID:walletID, accountID:record.id)
                        plan = try await tonClient(input.network).walletConnectReview(input, publicKey:key)
                    }
                    guard preparationGeneration == generation, !Task.isCancelled,
                          authorized(request, walletID:walletID, account:account), pendingRequest == nil else { return }
                    completion = nil; presentationIssue = nil
                    pendingRequest = .init(request:request, peer:peer, walletID:walletID, account:account, payload:.ton(input,plan))
                } catch is CancellationError { }
                catch {
                    guard preparationGeneration == generation, !Task.isCancelled, authorized(request, walletID:walletID, account:account) else { return }
                    // Peer validation and elapsed requests are expected rejections.
                    if !(error is WalletConnectJSON.Failure), !([TonSendError.malformed,.wrongOwner,.wrongNetwork,.expired].contains { $0 == error as? TonSendError }) {
                        OathDiagnostics.record(error, component:"walletconnect", operation:"prepare_ton", context:["chain":"ton"])
                    }
                    respondError(request, code:1)
                    presentationIssue = error is SendFeeFundingError ? .gas(network:request.chainId.absoluteString == "ton:-3" ? "ton:-3" : "ton",address:account) : error as? TonSendError == .expired ? .expired : error as? TonSendError == .simulationFailed ? .simulation : .invalid
                }
            }
        }
    }
    private func finishTonSubmission(_ item: PendingRequest, stored: WalletConnectTonSubmission) async {
        var current = stored
        do {
            let (plan, signed) = try stored.decoded(), db = try await session?.vault.database()
            if ["signed","unknown"].contains(stored.state) {
                let outcome = try await tonClient(plan.request.network).walletConnectSubmit(signed, plan:plan)
                try await db?.settleWalletConnectTon(stored.id, outcome:outcome)
                current.state = outcome.rawValue
            }
            if session?.isUnlocked == true, pendingRequest == nil || pendingRequest?.operationID == item.operationID {
                completion = .init(peer:item.peer, walletID:item.walletID, account:item.account, isTransaction:true, ton:current)
            }
            if pendingRequest?.operationID == item.operationID { pendingRequest = nil }
            // TON Connect's WalletConnect adapter expects the external-message
            // BOC itself as the JSON-RPC result, not a nested {boc: ...} object.
            if current.state == "expired" || current.state == "failed" { respondError(item.request, code:0) }
            else { respond(item.request, .response(AnyCodable(signed.bytes.base64EncodedString()))) }
        } catch {
            OathDiagnostics.record(error, component:"walletconnect", operation:"submit_ton", context:["chain":"ton"])
            // A committed message stays recoverable. Never sign a new sequence
            // because delivery or the response was interrupted.
            if session?.isUnlocked == true {
                completion = .init(peer:item.peer, walletID:item.walletID, account:item.account, isTransaction:true, ton:current)
            }
            if pendingRequest?.operationID == item.operationID { pendingRequest = nil }
        }
        resumeTonSubmissions()
    }
    private func resumeTonSubmissions() {
        guard tonRecovery == nil, let session, session.isUnlocked else { return }
        tonRecovery = Task {
            defer { tonRecovery = nil }
            await OathDiagnostics.$chain.withValue("ton") {
                await OathDiagnostics.$operationID.withValue(UUID()) {
                    do {
                        let db = try await session.vault.database()
                        for _ in 0..<120 {
                            guard session.isUnlocked, !Task.isCancelled else { return }
                            let rows = try await db.pendingWalletConnectTonSubmissions()
                            if rows.isEmpty { return }
                            for row in rows {
                                guard session.wallets.contains(where: { $0.id == row.walletID }) else { continue }
                                do {
                                    let (plan, signed) = try row.decoded(), client = try tonClient(plan.request.network)
                                    var outcome = try await client.walletConnectStatus(signed, plan:plan)
                                    if outcome == .unknown { outcome = try await client.walletConnectSubmit(signed, plan:plan) }
                                    try await db.settleWalletConnectTon(row.id, outcome:outcome)
                                    if outcome == .confirmed && row.state != "confirmed" && plan.request.network == .mainnet {
                                        await OathPostSendBalanceRefresh.shared.submitted(walletID:row.walletID, networkID:"ton")
                                    }
                                    if completion?.ton?.id == row.id, let updated = try await db.walletConnectTonSubmission(row.id) {
                                        let changed = completion?.ton?.state != updated.state
                                        completion?.ton = updated
                                        if changed && updated.state == "confirmed" {
                                            OathHaptics.shared.play(.success)
                                        }
                                    }
                                } catch is CancellationError { return }
                                catch { OathDiagnostics.record(error, component:"walletconnect", operation:"recover_ton", context:["chain":"ton"]) }
                            }
                            try await Task.sleep(for:.seconds(5))
                        }
                    } catch is CancellationError { }
                    catch { OathDiagnostics.record(error, component:"walletconnect", operation:"ton_journal", context:["chain":"ton"]) }
                }
            }
        }
    }
}

extension OathWalletConnectService {
    private func approveTonProofs(_ proposal: Session.Proposal, namespaces: [String: SessionNamespace], accounts: [AccountRecord], walletID: String, digits: [UInt8]?, reason: String) async throws -> Data? {
        guard let requests = proposal.requests?.authentication, !requests.isEmpty else { return nil }
        guard requests.count == 1, let auth = requests.first, auth.aud == "ton_proof", auth.version == "1",
              auth.domain == OathWalletConnectPolicy.safeHost(proposal.proposer.url),
              let payload = auth.statement, auth.resources?.isEmpty != false,
              auth.chains.count == 1, let chain = auth.chains.first,
              let network = TonSendNetwork(walletConnectChain:chain),
              let approved = namespaces["ton"]?.accounts.first(where: { $0.blockchain.absoluteString == chain }),
              let account = accounts.first(where: { $0.networkID == "ton" }), let session else { throw TonSendError.malformed }
        let request = try WalletConnectTonProofRequest(chain:chain, account:approved.address, domain:auth.domain, payload:payload)
        guard try network.address(account.address) == request.account else { throw TonSendError.wrongOwner }
        let timestamp = UInt64(Date.now.timeIntervalSince1970)
        let signature = try await session.vault.signWalletConnectTonProof(walletID:walletID, accountID:account.id, request:request, timestamp:timestamp, digits:digits, reason:reason)
        let date = ISO8601DateFormatter().string(from:Date(timeIntervalSince1970:Double(timestamp)))
        let cacao = Cacao(h:CacaoHeader(t:"ton_proof"), p:CacaoPayload(iss:"did:pkh:" + chain + ":" + approved.address,
            domain:auth.domain, aud:auth.aud, version:auth.version, nonce:auth.nonce, iat:date, nbf:nil, exp:nil,
            statement:payload, requestId:auth.requestId, resources:nil), s:CacaoSignature(t:.ed25519,s:signature.base64EncodedString()))
        return try JSONEncoder().encode(ProposalRequestsResponses(authentication:[cacao]))
    }
}


extension OathWalletConnectService {
    private func prepareBitcoin(_ request: Request, peer: Session, walletID: String, account: String, generation: UUID) async {
        defer { if preparationGeneration == generation { preparationTask = nil; preparingItem = nil; preparingRequest = false } }
        await OathDiagnostics.$chain.withValue("bitcoin") {
            await OathDiagnostics.$operationID.withValue(generation) {
                do {
                    guard let session, let record = await accounts(walletID:walletID).first(where: {
                        $0.networkID == "bitcoin" && Self.accountMatches($0.address,account,chain:request.chainId)
                    }) else { throw BitcoinConnectError.wrongAccount }
                    let input = try BitcoinConnectRequest(method:request.method,chain:request.chainId.absoluteString,account:account,params:JSONEncoder().encode(request.params))
                    let db = try await session.vault.database()
                    if let stored = try await db.walletConnectBitcoinSubmission(durableSendID(request)) {
                        guard stored.fingerprint == input.fingerprint, stored.walletID == walletID,
                              authorized(request,walletID:walletID,account:account), preparationGeneration == generation else { throw BitcoinConnectError.changed }
                        await finishBitcoinSubmission(.init(request:request,peer:peer,walletID:walletID,account:account,payload:.bitcoin(input,nil,nil)),stored:stored)
                        return
                    }
                    let addresses = try await db.walletConnectBitcoinAddresses(accountID:record.id)
                    let plan: BitcoinConnectPlan?, address: BitcoinDerivedAddress?
                    if input.method == "getAccountAddresses" {
                        let values = try addresses.map { try BitcoinConnectAddress($0,network:input.network) }
                            .filter { input.intentions == nil || input.intentions!.contains($0.intention) }
                        guard preparationGeneration == generation, authorized(request,walletID:walletID,account:account), !Task.isCancelled else { return }
                        respond(request,.response(AnyCodable(values)))
                        return
                    } else if input.method == "signMessage" {
                        let script = try input.network.script(input.address ?? input.account)
                        guard let matched = addresses.first(where:{ $0.script == script.map { String(format:"%02x",$0) }.joined() }) else { throw BitcoinConnectError.wrongAccount }
                        guard matched.multisigInputWeight == nil,
                              input.protocol == "bip322" ? [.nativeSegwit,.taproot].contains(matched.type) : matched.type != .taproot else { throw BitcoinConnectError.unsupported }
                        address = matched; plan = nil
                    } else {
                        let change = try await db.bitcoinChangeAddress(accountID:record.id)
                        plan = try await BitcoinConnectClient().review(input,addresses:addresses,change:change); address = nil
                    }
                    guard preparationGeneration == generation, !Task.isCancelled, authorized(request,walletID:walletID,account:account), pendingRequest == nil else { return }
                    completion = nil; presentationIssue = nil
                    pendingRequest = .init(request:request,peer:peer,walletID:walletID,account:account,payload:.bitcoin(input,plan,address))
                } catch is CancellationError { }
                catch {
                    guard preparationGeneration == generation, !Task.isCancelled, authorized(request,walletID:walletID,account:account) else { return }
                    let failure = error as? BitcoinConnectError
                    // Invalid peer requests are expected protocol rejection, not app failures.
                    if failure == nil || failure == .unavailable {
                        OathDiagnostics.record(error,component:"walletconnect",operation:"prepare_bitcoin",context:["chain":"bitcoin"])
                    }
                    respondError(request,code:failure == .unsupported ? 4200 : -32602)
                    presentationIssue = failure == .unsupported ? .unsupported : failure == .unavailable ? .unavailable : failure == .insufficientFunds ? .bitcoinFunds : .invalid
                }
            }
        }
    }
    private func bitcoinResponse(_ row: WalletConnectBitcoinSubmission) throws -> AnyCodable {
        let (plan,signed) = try row.decoded()
        return plan.request.method == "sendTransfer" ? AnyCodable(["txid":row.hash]) : AnyCodable(["psbt":signed.psbt,"txid":row.hash])
    }
    private func finishBitcoinSubmission(_ item: PendingRequest, stored: WalletConnectBitcoinSubmission) async {
        var row = stored
        do {
            let (plan,signed) = try row.decoded()
            if ["signed","unknown"].contains(row.state) {
                let state = try await BitcoinConnectClient().broadcast(signed,network:plan.request.network)
                try await session?.vault.database().settleWalletConnectBitcoin(row.id,status:state)
                row.state = state.rawValue
            }
            if row.state == "accepted" || row.state == "confirmed" { respond(item.request,.response(try bitcoinResponse(row))) }
        } catch is CancellationError {
            // The durable submission remains recoverable after dismissal or lock.
        } catch {
            OathDiagnostics.record(error,component:"walletconnect",operation:"submit_bitcoin",context:["chain":"bitcoin"])
        }
        if session?.isUnlocked == true { completion = .init(peer:item.peer,walletID:item.walletID,account:item.account,isTransaction:true,bitcoin:row) }
        if pendingRequest?.operationID == item.operationID { pendingRequest = nil }
        resumeBitcoinSubmissions()
    }
    private func resumeBitcoinSubmissions() {
        guard bitcoinRecovery == nil, let session, session.isUnlocked else { return }
        bitcoinRecovery = Task {
            defer { bitcoinRecovery = nil }
            await OathDiagnostics.$chain.withValue("bitcoin") {
                await OathDiagnostics.$operationID.withValue(UUID()) {
                    do {
                        let db = try await session.vault.database(), client = BitcoinConnectClient()
                        for iteration in 0..<120 {
                            guard session.isUnlocked, !Task.isCancelled else { return }
                            let rows = try await db.pendingWalletConnectBitcoinSubmissions()
                            if rows.isEmpty { return }
                            for row in rows {
                                guard session.wallets.contains(where: { $0.id == row.walletID }) else { continue }
                                do {
                                    let (plan,signed) = try row.decoded()
                                    var status = try await client.status(hash:row.hash,network:plan.request.network)
                                    if status == .unknown && iteration % 6 == 0 { status = try await client.broadcast(signed,network:plan.request.network) }
                                    try await db.settleWalletConnectBitcoin(row.id,status:status)
                                    if let updated = try await db.walletConnectBitcoinSubmission(row.id) {
                                        if completion?.bitcoin?.id == row.id { completion?.bitcoin = updated }
                                        if updated.state == "accepted" || updated.state == "confirmed" {
                                            for pending in Sign.instance.getPendingRequests() where durableSendID(pending.request) == row.id {
                                                guard walletMapping[pending.request.topic] == row.walletID else { continue }
                                                respond(pending.request,.response(try bitcoinResponse(updated)))
                                            }
                                        }
                                    }
                                    if status == .confirmed && plan.request.network == .mainnet {
                                        await OathPostSendBalanceRefresh.shared.submitted(walletID:row.walletID,networkID:"bitcoin")
                                    }
                                } catch is CancellationError { return }
                                catch { OathDiagnostics.record(error,component:"walletconnect",operation:"recover_bitcoin",context:["chain":"bitcoin"]) }
                            }
                            try await Task.sleep(for:.seconds(5))
                        }
                    } catch is CancellationError { }
                    catch { OathDiagnostics.record(error,component:"walletconnect",operation:"bitcoin_journal",context:["chain":"bitcoin"]) }
                }
            }
        }
    }

    private func resumeBitcoinAddressEvents() {
        guard bitcoinAddressEvents == nil, configured, let session, session.isUnlocked else { return }
        bitcoinAddressEvents = Task {
            defer { bitcoinAddressEvents = nil }
            await OathDiagnostics.$chain.withValue("bitcoin") {
                await OathDiagnostics.$operationID.withValue(UUID()) {
                    while session.isUnlocked && !Task.isCancelled {
                        let peers = sessions.filter { walletMapping[$0.topic] != nil && $0.namespaces.values.contains(where: {
                            $0.events.contains("bip122_addressesChanged") && $0.accounts.contains(where: { $0.blockchain.namespace == "bip122" })
                        }) }
                        let liveTopics = Set(peers.map(\.topic))
                        bitcoinAddressSnapshots = bitcoinAddressSnapshots.filter { key, _ in liveTopics.contains(String(key.prefix(while: { $0 != "|" }))) }
                        if peers.isEmpty { return }
                        for peer in peers {
                            do {
                                guard let walletID = walletMapping[peer.topic],
                                      let account = await accounts(walletID:walletID).first(where: { $0.networkID == "bitcoin" }) else { continue }
                                let db = try await session.vault.database()
                                let addresses = try await db.walletConnectBitcoinAddresses(accountID:account.id)
                                let chains = Set(peer.namespaces.values.filter { $0.events.contains("bip122_addressesChanged") }.flatMap(\.accounts).map(\.blockchain))
                                for chain in chains {
                                    guard let network = BitcoinConnectNetwork(chain:chain.absoluteString) else { continue }
                                    guard peer.namespaces.values.flatMap(\.accounts).contains(where: {
                                        $0.blockchain == chain && Self.accountMatches(account.address,$0.address,chain:chain)
                                    }) else { continue }
                                    let rows = try addresses.map { try BitcoinConnectAddress($0,network:network) }
                                    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                                    let revision: Data
                                    if network == .mainnet {
                                        revision = try await db.walletConnectBitcoinUTXORevision(accountID:account.id)
                                    } else {
                                        // Test networks have separate UTXO sets from the mainnet ledger.
                                        let coins = try await BitcoinConnectClient().coins(addresses:addresses,network:network)
                                        revision = Data(coins.map { $0.txid + ":" + String($0.vout) + ":" + String($0.value) }.sorted().joined(separator:"\n").utf8)
                                    }
                                    let snapshot = try encoder.encode(rows) + revision, key = peer.topic + "|" + chain.absoluteString
                                    guard bitcoinAddressSnapshots[key] != snapshot, session.isUnlocked,
                                          walletMapping[peer.topic] == walletID, !connections.isRevoked(peer.topic),
                                          peer.expiryDate > .now else { continue }
                                    try await Sign.instance.emit(topic:peer.topic,event:.init(name:"bip122_addressesChanged",data:AnyCodable(rows)),chainId:chain)
                                    bitcoinAddressSnapshots[key] = snapshot
                                }
                            } catch is CancellationError { return }
                            catch { OathDiagnostics.record(error,component:"walletconnect",operation:"bitcoin_addresses_event",context:["chain":"bitcoin"]) }
                        }
                        do { try await Task.sleep(for:.seconds(15)) } catch { return }
                    }
                }
            }
        }
    }
}

extension OathWalletConnectService {
    @concurrent nonisolated private static func decodePolkadot(method:String, chain:String, account:String, params:Data) async throws -> WalletConnectPolkadotRequest {
        try WalletConnectPolkadotRequest(method:method, chain:chain, account:account, params:params)
    }
    private func preparePolkadot(_ request:Request, peer:Session, walletID:String, account:String, generation:UUID) async {
        defer { if preparationGeneration == generation { preparationTask = nil; preparingItem = nil; preparingRequest = false } }
        await OathDiagnostics.$chain.withValue("polkadot") {
            await OathDiagnostics.$operationID.withValue(generation) {
                do {
                    let input = try await Self.decodePolkadot(method:request.method, chain:request.chainId.absoluteString, account:account, params:JSONEncoder().encode(request.params))
                    let review = input.message == nil ? try await PolkadotConnectClient(network:input.network).review(input) : nil
                    guard preparationGeneration == generation, !Task.isCancelled,
                          authorized(request, walletID:walletID, account:account), pendingRequest == nil else { return }
                    completion = nil; presentationIssue = nil
                    pendingRequest = .init(request:request, peer:peer, walletID:walletID, account:account, payload:.polkadot(input,review))
                } catch is CancellationError { }
                catch {
                    guard preparationGeneration == generation, !Task.isCancelled, authorized(request, walletID:walletID, account:account) else { return }
                    // Invalid peer requests and expired reviews are expected rejections.
                    if !(error is WalletConnectJSON.Failure),
                       !([PolkadotSendError.malformed,.wrongOwner,.wrongNetwork,.expired,.changed].contains { $0 == error as? PolkadotSendError }) {
                        OathDiagnostics.record(error, component:"walletconnect", operation:"prepare_polkadot", context:["chain":"polkadot"])
                    }
                    respondError(request, code:-32602)
                    switch error as? PolkadotSendError {
                    case .expired: presentationIssue = .expired
                    case .runtimeUnsupported: presentationIssue = .unsupported
                    default: presentationIssue = .invalid
                    }
                }
            }
        }
    }
    private func tronClient(_ network: TronSendNetwork) throws -> TronSendClient {
        if network == .mainnet { return try OathTokenRPCConfiguration.bundled().makeTronSendClient() }
        return try TronSendClient(network:network)
    }
    @concurrent nonisolated private static func decodeTron(method:String, chain:String, account:String, params:Data) async throws -> WalletConnectTronRequest {
        try WalletConnectTronRequest(method:method, chain:chain, account:account, params:params)
    }
    private func prepareTron(_ request:Request, peer:Session, walletID:String, account:String, generation:UUID) async {
        defer { if preparationGeneration == generation { preparationTask = nil; preparingItem = nil; preparingRequest = false } }
        await OathDiagnostics.$chain.withValue("tron") {
            await OathDiagnostics.$operationID.withValue(generation) {
                do {
                    let input = try await Self.decodeTron(method:request.method, chain:request.chainId.absoluteString, account:account, params:JSONEncoder().encode(request.params))
                    let review = input.message == nil ? try await tronClient(input.network).walletConnectReview(input) : nil
                    guard preparationGeneration == generation, !Task.isCancelled,
                          authorized(request, walletID:walletID, account:account), pendingRequest == nil else { return }
                    completion = nil; presentationIssue = nil
                    pendingRequest = .init(request:request, peer:peer, walletID:walletID, account:account, payload:.tron(input,review))
                } catch is CancellationError { }
                catch {
                    guard preparationGeneration == generation, !Task.isCancelled, authorized(request, walletID:walletID, account:account) else { return }
                    // Malformed peer requests, mismatched owners and elapsed requests are expected rejections.
                    if !(error is WalletConnectJSON.Failure), !(error is TronError),
                       !([TronSendError.malformed,.wrongOwner,.wrongNetwork,.expired,.changed,.unsupportedAccount,.amount].contains { $0 == error as? TronSendError }) {
                        OathDiagnostics.record(error, component:"walletconnect", operation:"prepare_tron", context:["chain":"tron"])
                    }
                    respondError(request, code:-32602)
                    switch error as? TronSendError {
                    case .expired: presentationIssue = .expired
                    case .unsupportedAccount: presentationIssue = .unsupported
                    case .insufficientFunds, .senderInactive: presentationIssue = .gas(network:inputNetwork(request.chainId),address:account)
                    case .simulation: presentationIssue = .simulation
                    default: presentationIssue = .invalid
                    }
                }
            }
        }
    }
    private func inputNetwork(_ chain: Blockchain) -> String { chain.absoluteString == TronSendNetwork.nile.walletConnectChain ? "tron:0xcd8690dc" : "tron" }
}

extension OathWalletConnectService {
    private func suiClient(_ network:SuiSendNetwork) throws -> SuiSendClient {
        if network == .mainnet { return try OathTokenRPCConfiguration.bundled().makeSuiSendClient() }
        return try SuiSendClient(network:network)
    }
    @concurrent nonisolated private static func decodeSui(method:String,chain:String,account:String,params:Data) async throws -> WalletConnectSuiRequest {
        try WalletConnectSuiRequest(method:method,chain:chain,account:account,params:params)
    }
    private func prepareSui(_ request:Request,peer:Session,walletID:String,account:String,generation:UUID) async {
        defer { if preparationGeneration == generation { preparationTask = nil; preparingItem = nil; preparingRequest = false } }
        await OathDiagnostics.$chain.withValue("sui") {
            await OathDiagnostics.$operationID.withValue(generation) {
                do {
                    let input = try await Self.decodeSui(method:request.method,chain:request.chainId.absoluteString,account:account,params:JSONEncoder().encode(request.params))
                    guard let session else { throw CancellationError() }
                    let db = try await session.vault.database()
                    if input.broadcasts, let stored = try await db.walletConnectSuiSubmission(durableSendID(request)) {
                        guard stored.fingerprint == input.fingerprint, stored.walletID == walletID else { throw SuiSendError.changed }
                        guard preparationGeneration == generation, !Task.isCancelled, authorized(request,walletID:walletID,account:account) else { return }
                        await finishSuiSubmission(.init(request:request,peer:peer,walletID:walletID,account:account,payload:.sui(input,nil)),stored:stored); return
                    }
                    if request.method == "sui_getAccounts" {
                        guard let record = try await db.accounts(walletID:walletID).first(where:{$0.networkID == "sui" && Self.accountMatches($0.address,account,chain:request.chainId)}) else { throw SuiSendError.wrongOwner }
                        let key = try await session.vault.suiPublicKey(walletID:walletID,accountID:record.id)
                        guard preparationGeneration == generation, !Task.isCancelled, authorized(request,walletID:walletID,account:account) else { return }
                        respond(request,.response(AnyCodable(try WalletConnectSuiRequest.accountResponse(publicKey:key)))); return
                    }
                    let review = input.transaction == nil ? nil : try await suiClient(input.network).walletConnectReview(input)
                    guard preparationGeneration == generation, !Task.isCancelled, authorized(request,walletID:walletID,account:account), pendingRequest == nil else { return }
                    completion = nil; presentationIssue = nil
                    pendingRequest = .init(request:request,peer:peer,walletID:walletID,account:account,payload:.sui(input,review))
                } catch is CancellationError { }
                catch {
                    guard preparationGeneration == generation, !Task.isCancelled, authorized(request,walletID:walletID,account:account) else { return }
                    // Invalid peer envelopes are expected rejections; transport/simulation failures retain their diagnostics.
                    if !(error is WalletConnectJSON.Failure), !([SuiSendError.malformed,.wrongOwner,.wrongNetwork,.expired,.changed].contains {$0 == error as? SuiSendError}) {
                        OathDiagnostics.record(error,component:"walletconnect",operation:"prepare_sui",context:["chain":"sui"])
                    }
                    respondError(request,code:-32602)
                    presentationIssue = error as? SuiSendError == .simulationFailed ? .simulation : error as? SuiSendError == .expired ? .expired : .invalid
                }
            }
        }
    }
    private func finishSuiSubmission(_ item:PendingRequest,stored:WalletConnectSuiSubmission) async {
        var current = stored
        do {
            let (plan,signed) = try stored.decoded()
            if ["signed","unknown"].contains(stored.state) {
                let receipt = try await suiClient(plan.request.network).submit(signed,sender:plan.request.account)
                try await session?.vault.database().settleWalletConnectSui(stored.id,outcome:receipt.outcome)
                current.state = receipt.outcome.rawValue
                if receipt.outcome == .confirmed && plan.request.network == .mainnet {
                    await OathPostSendBalanceRefresh.shared.submitted(walletID:stored.walletID,networkID:"sui")
                }
            }
            if session?.isUnlocked == true, pendingRequest == nil || pendingRequest?.operationID == item.operationID {
                completion = .init(peer:item.peer,walletID:item.walletID,account:item.account,isTransaction:true,sui:current)
            }
            if pendingRequest?.operationID == item.operationID { pendingRequest = nil }
            if ["confirmed","failed"].contains(current.state) {
                respond(item.request,.response(AnyCodable(["digest":signed.digest])))
            }
        } catch {
            OathDiagnostics.record(error,component:"walletconnect",operation:"submit_sui",context:["chain":"sui"])
            if session?.isUnlocked == true { completion = .init(peer:item.peer,walletID:item.walletID,account:item.account,isTransaction:true,sui:current) }
            if pendingRequest?.operationID == item.operationID { pendingRequest = nil }
        }
        resumeSuiSubmissions()
    }
    private func resumeSuiSubmissions() {
        guard suiRecovery == nil, let session, session.isUnlocked else { return }
        suiRecovery = Task {
            defer { suiRecovery = nil }
            await OathDiagnostics.$chain.withValue("sui") {
                await OathDiagnostics.$operationID.withValue(UUID()) {
                    do {
                        let db = try await session.vault.database()
                        for _ in 0..<120 {
                            guard session.isUnlocked, !Task.isCancelled else { return }
                            let rows = try await db.pendingWalletConnectSuiSubmissions()
                            if rows.isEmpty { return }
                            for row in rows {
                                guard session.wallets.contains(where:{$0.id == row.walletID}) else { continue }
                                do {
                                    let (plan,signed) = try row.decoded(), client = try suiClient(plan.request.network)
                                    var result = try await client.status(digest:signed.digest)
                                    if result.outcome == .unknown { result = try await client.submit(signed,sender:plan.request.account) }
                                    try await db.settleWalletConnectSui(row.id,outcome:result.outcome)
                                    if result.outcome == .confirmed && plan.request.network == .mainnet {
                                        await OathPostSendBalanceRefresh.shared.submitted(walletID:row.walletID,networkID:"sui")
                                    }
                                    if completion?.sui?.id == row.id { completion?.sui = try await db.walletConnectSuiSubmission(row.id) }
                                    if result.outcome != .unknown {
                                        for pending in Sign.instance.getPendingRequests().prefix(8) where durableSendID(pending.request) == row.id {
                                            if authorized(pending.request,walletID:row.walletID,account:row.owner) { respond(pending.request,.response(AnyCodable(["digest":signed.digest]))) }
                                        }
                                    }
                                } catch is CancellationError { return }
                                catch { OathDiagnostics.record(error,component:"walletconnect",operation:"recover_sui",context:["chain":"sui"]) }
                            }
                            try await Task.sleep(for:.seconds(5))
                        }
                    } catch is CancellationError { }
                    catch { OathDiagnostics.record(error,component:"walletconnect",operation:"sui_journal",context:["chain":"sui"]) }
                }
            }
        }
    }
}


extension OathWalletConnectService {
    private func nearClient(_ network:NearSendNetwork) throws -> NearSendClient {
        if network == .mainnet { return try OathTokenRPCConfiguration.bundled().makeNearSendClient() }
        return try NearSendClient(network:network)
    }
    @concurrent nonisolated private static func decodeNear(method:String,chain:String,account:String,params:Data) async throws -> WalletConnectNearRequest {
        try WalletConnectNearRequest(method:method,chain:chain,account:account,params:params)
    }
    private func prepareNear(_ request:Request,peer:Session,walletID:String,account:String,generation:UUID) async {
        defer { if preparationGeneration == generation { preparationTask = nil; preparingItem = nil; preparingRequest = false } }
        await OathDiagnostics.$chain.withValue("near") {
            await OathDiagnostics.$operationID.withValue(generation) {
                do {
                    guard let session else { throw CancellationError() }
                    let db = try await session.vault.database()
                    guard let record = try await db.accounts(walletID:walletID).first(where:{$0.networkID == "near" && $0.address == account}) else { throw NearSendError.wrongOwner }
                    let key = try await session.vault.nearPublicKey(walletID:walletID,accountID:record.id)
                    if WalletConnectNearAccess.methods.contains(request.method) {
                        let access = try WalletConnectNearAccess(method:request.method,chain:request.chainId.absoluteString,account:account,params:JSONEncoder().encode(request.params))
                        if let stored = try await db.walletConnectNearSubmission(durableSendID(request)) {
                            guard stored.fingerprint == access.fingerprint, stored.walletID == walletID, stored.topic == request.topic else { throw NearSendError.changed }
                            let (_,plan,_) = try stored.decoded()
                            guard preparationGeneration == generation, !Task.isCancelled, authorized(request,walletID:walletID,account:account) else { return }
                            await finishNearSubmission(.init(request:request,peer:peer,walletID:walletID,account:account,payload:.nearAccess(access,plan)),stored:stored); return
                        }
                        let grants = try await db.walletConnectNearGrants(walletID:walletID,accountID:record.id,topic:request.topic,chain:access.network.walletConnectChain)
                        let review = try await nearClient(access.network).walletConnectAccessReview(access,publicKey:key,grants:grants)
                        guard preparationGeneration == generation, !Task.isCancelled, authorized(request,walletID:walletID,account:account), pendingRequest == nil else { return }
                        completion = nil; presentationIssue = nil
                        pendingRequest = .init(request:request,peer:peer,walletID:walletID,account:account,payload:.nearAccess(access,review)); return
                    }
                    let input = try await Self.decodeNear(method:request.method,chain:request.chainId.absoluteString,account:account,params:JSONEncoder().encode(request.params))
                    let client = try nearClient(input.network)
                    if request.method == "near_getAccounts" {
                        let result = try await client.walletConnectAccounts(account:account,publicKey:key)
                        guard preparationGeneration == generation, !Task.isCancelled, authorized(request,walletID:walletID,account:account) else { return }
                        respond(request,.response(AnyCodable(result))); return
                    }
                    let review = try await client.walletConnectReview(input,publicKey:key)
                    guard preparationGeneration == generation, !Task.isCancelled, authorized(request,walletID:walletID,account:account), pendingRequest == nil else { return }
                    completion = nil; presentationIssue = nil
                    pendingRequest = .init(request:request,peer:peer,walletID:walletID,account:account,payload:.near(input,review))
                } catch is CancellationError { }
                catch {
                    guard preparationGeneration == generation, !Task.isCancelled, authorized(request,walletID:walletID,account:account) else { return }
                    // Invalid peer input is an expected rejection; provider failures retain diagnostics.
                    if !(error is WalletConnectJSON.Failure), !(error is NearError), !([NearSendError.malformed,.wrongOwner,.wrongNetwork,.expired,.changed,.unsupportedAccount].contains {$0 == error as? NearSendError}) {
                        OathDiagnostics.record(error,component:"walletconnect",operation:"prepare_near",context:["chain":"near"])
                    }
                    respondError(request,code:-32602)
                    presentationIssue = error as? NearSendError == .expired ? .expired : .invalid
                }
            }
        }
    }
}


extension OathWalletConnectService {
    private func answerNearSubmission(_ request:Request,state:String) {
        if state == "confirmed" { respond(request,.response(AnyCodable(NearJSON.null))) }
        else if ["failed","expired"].contains(state) { respondError(request,code:-32000) }
    }
    private func finishNearSubmission(_ item:PendingRequest,stored:WalletConnectNearSubmission) async {
        var current = stored
        do {
            let (_,plan,signed) = try stored.decoded()
            if ["signed","unknown","accepted"].contains(stored.state) {
                let outcome = try await nearClient(plan.request.network).walletConnectAccessSubmit(signed,review:plan)
                let db = try await session?.vault.database()
                try await db?.settleWalletConnectNear(stored.id,outcome:outcome)
                current.state = outcome.rawValue
            }
            answerNearSubmission(item.request,state:current.state)
        } catch is CancellationError { }
        catch { OathDiagnostics.record(error,component:"walletconnect",operation:"submit_near",context:["chain":"near"]) }
        if session?.isUnlocked == true, pendingRequest == nil || pendingRequest?.operationID == item.operationID {
            completion = .init(peer:item.peer,walletID:item.walletID,account:item.account,isTransaction:true,near:current)
        }
        if pendingRequest?.operationID == item.operationID { pendingRequest = nil }
        resumeNearSubmissions()
    }
    private func resumeNearSubmissions() {
        guard nearRecovery == nil, let session, session.isUnlocked else { return }
        nearRecovery = Task {
            defer { nearRecovery = nil }
            await OathDiagnostics.$chain.withValue("near") {
                await OathDiagnostics.$operationID.withValue(UUID()) {
                    do {
                        let db = try await session.vault.database()
                        for _ in 0..<120 {
                            guard session.isUnlocked, !Task.isCancelled else { return }
                            let rows = try await db.pendingWalletConnectNearSubmissions()
                            if rows.isEmpty { return }
                            for row in rows {
                                guard session.wallets.contains(where:{$0.id == row.walletID}) else { continue }
                                do {
                                    let (_,plan,signed) = try row.decoded()
                                    let outcome = try await nearClient(plan.request.network).walletConnectAccessSubmit(signed,review:plan)
                                    try await db.settleWalletConnectNear(row.id,outcome:outcome)
                                    if completion?.near?.id == row.id { completion?.near = try await db.walletConnectNearSubmission(row.id) }
                                    if [.confirmed,.failed,.expired].contains(outcome) {
                                        for pending in Sign.instance.getPendingRequests().prefix(8) where durableSendID(pending.request) == row.id {
                                            if authorized(pending.request,walletID:row.walletID,account:row.owner) { answerNearSubmission(pending.request,state:outcome.rawValue) }
                                        }
                                    }
                                } catch is CancellationError { return }
                                catch { OathDiagnostics.record(error,component:"walletconnect",operation:"recover_near",context:["chain":"near"]) }
                            }
                            try await Task.sleep(for:.seconds(5))
                        }
                    } catch is CancellationError { }
                    catch { OathDiagnostics.record(error,component:"walletconnect",operation:"near_journal",context:["chain":"near"]) }
                }
            }
        }
    }
}

extension OathWalletConnectService {
    private func answerStellarSubmission(_ request:Request,state:String) {
        if state == "confirmed" { respond(request,.response(AnyCodable(StellarJSON.object(["status":.string("success")])))) }
        else if ["failed","expired"].contains(state) { respondError(request,code:-32000) }
    }
    private func finishStellarSubmission(_ item:PendingRequest,stored:WalletConnectStellarSubmission) async {
        var current = stored
        do {
            let (plan,signed) = try stored.decoded()
            if ["signed","unknown","accepted"].contains(stored.state) {
                let outcome = try await stellarClient(plan.request.network).walletConnectSubmit(signed,review:plan)
                let db = try await session?.vault.database()
                try await db?.settleWalletConnectStellar(stored.id,outcome:outcome)
                current = try await db?.walletConnectStellarSubmission(stored.id) ?? stored
            }
            answerStellarSubmission(item.request,state:current.state)
        } catch is CancellationError { }
        catch { OathDiagnostics.record(error,component:"walletconnect",operation:"submit_stellar",context:["chain":"stellar"]) }
        if session?.isUnlocked == true, pendingRequest == nil || pendingRequest?.operationID == item.operationID {
            completion = .init(peer:item.peer,walletID:item.walletID,account:item.account,isTransaction:true,stellar:current)
        }
        if pendingRequest?.operationID == item.operationID { pendingRequest = nil }
        resumeStellarSubmissions()
    }
    private func resumeStellarSubmissions() {
        guard stellarRecovery == nil, let session, session.isUnlocked else { return }
        stellarRecovery = Task {
            defer { stellarRecovery = nil }
            await OathDiagnostics.$chain.withValue("stellar") {
                await OathDiagnostics.$operationID.withValue(UUID()) {
                    do {
                        let db = try await session.vault.database()
                        for _ in 0..<120 {
                            guard session.isUnlocked, !Task.isCancelled else { return }
                            let rows = try await db.pendingWalletConnectStellarSubmissions()
                            if rows.isEmpty { return }
                            for row in rows {
                                guard session.wallets.contains(where:{$0.id == row.walletID}) else { continue }
                                do {
                                    let (plan,signed) = try row.decoded()
                                    let outcome = try await stellarClient(plan.request.network).walletConnectSubmit(signed,review:plan)
                                    try await db.settleWalletConnectStellar(row.id,outcome:outcome)
                                    if completion?.stellar?.id == row.id { completion?.stellar = try await db.walletConnectStellarSubmission(row.id) }
                                    if [.confirmed,.failed,.expired].contains(outcome) {
                                        for pending in Sign.instance.getPendingRequests().prefix(8) where durableSendID(pending.request) == row.id {
                                            if authorized(pending.request,walletID:row.walletID,account:row.owner) { answerStellarSubmission(pending.request,state:outcome.rawValue) }
                                        }
                                    }
                                } catch is CancellationError { return }
                                catch { OathDiagnostics.record(error,component:"walletconnect",operation:"recover_stellar",context:["chain":"stellar"]) }
                            }
                            try await Task.sleep(for:.seconds(5))
                        }
                    } catch is CancellationError { }
                    catch { OathDiagnostics.record(error,component:"walletconnect",operation:"stellar_journal",context:["chain":"stellar"]) }
                }
            }
        }
    }
}

extension OathWalletConnectService {
    private func stellarClient(_ network: StellarSendNetwork) throws -> StellarSendClient {
        if network == .mainnet { return try OathTokenRPCConfiguration.bundled().makeStellarSendClient() }
        return try StellarSendClient(network: network)
    }
    @concurrent nonisolated private static func decodeStellar(method: String, chain: String, account: String, params: Data) async throws -> WalletConnectStellarRequest {
        try WalletConnectStellarRequest(method: method, chain: chain, account: account, params: params)
    }
    private func prepareStellar(_ request: Request, peer: Session, walletID: String, account: String, generation: UUID) async {
        defer { if preparationGeneration == generation { preparationTask = nil; preparingItem = nil; preparingRequest = false } }
        await OathDiagnostics.$chain.withValue("stellar") {
            await OathDiagnostics.$operationID.withValue(generation) {
                do {
                    guard let session else { throw CancellationError() }
                    let db = try await session.vault.database()
                    let input = try await Self.decodeStellar(method: request.method, chain: request.chainId.absoluteString, account: account, params: JSONEncoder().encode(request.params))
                    if input.broadcasts, let stored = try await db.walletConnectStellarSubmission(durableSendID(request)) {
                        guard stored.fingerprint == input.fingerprint, stored.walletID == walletID else { throw StellarSendError.changed }
                        let (review, _) = try stored.decoded()
                        guard preparationGeneration == generation, !Task.isCancelled, authorized(request,walletID:walletID,account:account) else { return }
                        await finishStellarSubmission(.init(request:request,peer:peer,walletID:walletID,account:account,payload:.stellar(input,review)),stored:stored); return
                    }
                    let review = try await stellarClient(input.network).walletConnectReview(input)
                    guard preparationGeneration == generation, !Task.isCancelled, authorized(request,walletID:walletID,account:account), pendingRequest == nil else { return }
                    completion = nil; presentationIssue = nil
                    pendingRequest = .init(request:request,peer:peer,walletID:walletID,account:account,payload:.stellar(input,review))
                } catch is CancellationError { }
                catch {
                    guard preparationGeneration == generation, !Task.isCancelled, authorized(request,walletID:walletID,account:account) else { return }
                    OathDiagnostics.record(error,component:"walletconnect",operation:"prepare_stellar",context:["chain":"stellar"])
                    respondError(request,code:-32602)
                    presentationIssue = error as? StellarSendError == .expired ? .expired : .invalid
                }
            }
        }
    }
}

extension OathWalletConnectService {
    private func answerXrplSubmission(_ request:Request,state:String,signed:WalletConnectXrplSigned) {
        if state == "confirmed" { respond(request,.response(AnyCodable(signed.response))) }
        else if ["failed","expired"].contains(state) { respondError(request,code:-32000) }
    }
    private func finishXrplSubmission(_ item:PendingRequest,stored:WalletConnectXrplSubmission) async {
        var current = stored
        do {
            let (plan,signed) = try await Self.decodeXrplSubmission(stored)
            if ["signed","unknown","accepted"].contains(stored.state) {
                let outcome = try await xrplClient(plan.request.network).walletConnectSubmit(signed,review:plan)
                let db = try await session?.vault.database()
                try await db?.settleWalletConnectXrpl(stored.id,outcome:outcome)
                current = try await db?.walletConnectXrplSubmission(stored.id) ?? stored
            }
            answerXrplSubmission(item.request,state:current.state,signed:signed)
        } catch is CancellationError { }
        catch { OathDiagnostics.record(error,component:"walletconnect",operation:"submit_xrpl",context:["chain":"xrpl"]) }
        if session?.isUnlocked == true, pendingRequest == nil || pendingRequest?.operationID == item.operationID {
            completion = .init(peer:item.peer,walletID:item.walletID,account:item.account,isTransaction:true,xrpl:current)
        }
        if pendingRequest?.operationID == item.operationID { pendingRequest = nil }
        resumeXrplSubmissions()
    }
    private func resumeXrplSubmissions() {
        guard xrplRecovery == nil, let session, session.isUnlocked else { return }
        xrplRecovery = Task {
            defer { xrplRecovery = nil }
            await OathDiagnostics.$chain.withValue("xrpl") {
                await OathDiagnostics.$operationID.withValue(UUID()) {
                    do {
                        let db = try await session.vault.database()
                        for _ in 0..<120 {
                            guard session.isUnlocked, !Task.isCancelled else { return }
                            let rows = try await db.pendingWalletConnectXrplSubmissions()
                            if rows.isEmpty { return }
                            for row in rows {
                                guard session.wallets.contains(where:{$0.id == row.walletID}) else { continue }
                                do {
                                    let (plan,signed) = try await Self.decodeXrplSubmission(row)
                                    let outcome = try await xrplClient(plan.request.network).walletConnectSubmit(signed,review:plan)
                                    try await db.settleWalletConnectXrpl(row.id,outcome:outcome)
                                    if completion?.xrpl?.id == row.id { completion?.xrpl = try await db.walletConnectXrplSubmission(row.id) }
                                    if [.confirmed,.failed,.expired].contains(outcome) {
                                        for pending in Sign.instance.getPendingRequests().prefix(8) where durableSendID(pending.request) == row.id {
                                            if authorized(pending.request,walletID:row.walletID,account:row.owner) { answerXrplSubmission(pending.request,state:outcome.rawValue,signed:signed) }
                                        }
                                    }
                                } catch is CancellationError { return }
                                catch { OathDiagnostics.record(error,component:"walletconnect",operation:"recover_xrpl",context:["chain":"xrpl"]) }
                            }
                            try await Task.sleep(for:.seconds(5))
                        }
                    } catch is CancellationError { }
                    catch { OathDiagnostics.record(error,component:"walletconnect",operation:"xrpl_journal",context:["chain":"xrpl"]) }
                }
            }
        }
    }
}

extension OathWalletConnectService {
    @concurrent nonisolated private static func decodeXrplSubmission(_ record: WalletConnectXrplSubmission) async throws -> (WalletConnectXrplReview, WalletConnectXrplSigned) {
        try record.decoded()
    }
    private func xrplClient(_ network: XrplSendNetwork) throws -> XrplSendClient {
        if network == .mainnet { return try OathTokenRPCConfiguration.bundled().makeXrplSendClient() }
        return try XrplSendClient(network: network)
    }
    @concurrent nonisolated private static func decodeXrpl(method: String, chain: String, account: String, params: Data) async throws -> WalletConnectXrplRequest {
        try WalletConnectXrplRequest(method: method, chain: chain, account: account, params: params)
    }
    private func prepareXrpl(_ request: Request, peer: Session, walletID: String, account: String, generation: UUID) async {
        defer { if preparationGeneration == generation { preparationTask = nil; preparingItem = nil; preparingRequest = false } }
        await OathDiagnostics.$chain.withValue("xrpl") {
            await OathDiagnostics.$operationID.withValue(generation) {
                do {
                    guard let session else { throw CancellationError() }
                    let db = try await session.vault.database()
                    let input = try await Self.decodeXrpl(method: request.method, chain: request.chainId.absoluteString, account: account, params: JSONEncoder().encode(request.params))
                    if input.broadcasts, let stored = try await db.walletConnectXrplSubmission(durableSendID(request)) {
                        guard stored.fingerprint == input.fingerprint, stored.walletID == walletID else { throw XrplSendError.changed }
                        let (review, _) = try await Self.decodeXrplSubmission(stored)
                        guard preparationGeneration == generation, !Task.isCancelled, authorized(request,walletID:walletID,account:account) else { return }
                        await finishXrplSubmission(.init(request:request,peer:peer,walletID:walletID,account:account,payload:.xrpl(input,review)),stored:stored); return
                    }
                    let review = try await xrplClient(input.network).walletConnectReview(input)
                    guard preparationGeneration == generation, !Task.isCancelled, authorized(request,walletID:walletID,account:account), pendingRequest == nil else { return }
                    completion = nil; presentationIssue = nil
                    pendingRequest = .init(request:request,peer:peer,walletID:walletID,account:account,payload:.xrpl(input,review))
                } catch is CancellationError { }
                catch {
                    guard preparationGeneration == generation, !Task.isCancelled, authorized(request,walletID:walletID,account:account) else { return }
                    OathDiagnostics.record(error,component:"walletconnect",operation:"prepare_xrpl",context:["chain":"xrpl"])
                    respondError(request,code:-32602)
                    presentationIssue = error as? XrplSendError == .expired ? .expired : .invalid
                }
            }
        }
    }
}
