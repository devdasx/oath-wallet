@preconcurrency import WalletConnectSign
@preconcurrency import WalletConnectNetworking
import Foundation
import CryptoKit
import Combine
import Observation
import OathDatabase
import OathDiagnostics
import OathAnkr

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
            case networkSwitch(UInt64)
        }
        let request: Request
        let peer: Session
        let walletID: String
        let account: String
        var payload: Payload
        var approvalToken: WalletConnectApprovalToken? = nil
        let operationID = UUID()
        var broadcasts: Bool { switch payload { case .evm: true; case .solana(let request, _): request.broadcasts; default: false } }
        var isTransaction: Bool { switch payload { case .thorchain, .evm: true; case .solana(let request, _): request.message == nil; default: false } }
        var id: String { request.id.string }
        var display: String {
            guard case .message(let message, _) = payload else { return "" }
            if let text = String(data: message, encoding: .utf8), !text.unicodeScalars.contains(where: {
                $0.properties.isBidiControl || ($0.value < 32 && $0.value != 10 && $0.value != 9)
            }) { return text }
            return "0x" + message.map { String(format: "%02x", $0) }.joined()
        }
    }
    enum PresentationIssue { case expired, unsupported, invalid, disconnected, unavailable, changed, gas(network: String, address: String), simulation, declined }
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
        let peer: Session
        let walletID: String
        let account: String
        let isTransaction: Bool
        var transaction: TransactionCompletion? = nil
        var selectedChain: UInt64? = nil
        var solana: WalletConnectSolanaSubmission? = nil
    }
    private(set) var completion: Completion?
    private(set) var presentationIssue: PresentationIssue?
    private(set) var configured = false
    private(set) var sessions = [Session]()
    private(set) var proposal: Proposal?
    private(set) var pendingRequest: PendingRequest?
    private(set) var working = false
    private(set) var preparingRequest = false
    private(set) var revisingTransaction = false
    var failed = false
    private(set) var requiresFreshPairing = false
    private(set) var connectedTopic: String?
    private(set) var connections = OathWalletConnectConnections()
    private(set) var disconnecting = Set<String>()
    @ObservationIgnored private weak var session: OathWalletSession?
    @ObservationIgnored private var observers = Set<AnyCancellable>()
    @ObservationIgnored private var timeout: Task<Void, Never>?
    @ObservationIgnored private var pairingTopic: String?
    @ObservationIgnored private var operation = UUID()
    @ObservationIgnored private var retryingDisconnections = false
    @ObservationIgnored private var solanaRecovery: Task<Void, Never>?
    @ObservationIgnored private var solanaClients: [String: SolanaSendClient] = [:]
    @ObservationIgnored private var signingRequest = false
    @ObservationIgnored private var preparationTask: Task<Void, Never>?
    @ObservationIgnored private var preparingItem: Request?
    @ObservationIgnored private var preparationGeneration = UUID()
    @ObservationIgnored private var presentationOpen = false
    @ObservationIgnored private var presentationID: UUID?
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
                    guard let self, session.isUnlocked, item.proposal.pairingTopic == self.pairingTopic else { return }
                    self.timeout?.cancel(); self.working = false; self.proposal = .init(value: item.proposal, verify: item.context)
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
            failed = true
        }
    }
    enum ConfigurationFailure: Error { case missing, invalid }
    func pair(_ raw: String) async {
        guard configured, session?.isUnlocked == true, !working, sessions.count < 32,
              case .walletConnect = OathScanParser.walletConnect(raw, now: .now),
              let uri = try? WalletConnectURI(uriString: raw) else { failed = true; return }
        operation = UUID(); let token = operation
        failed = false; completion = nil; presentationIssue = nil; requiresFreshPairing = false; proposal = nil; connectedTopic = nil; working = true; pairingTopic = uri.topic
        timeout?.cancel()
        // Re-scanning a consumed URI must not replay Pair.pair forever. The SDK
        // can already have the proposal (its topic argument currently does not
        // filter results) or an approved session associated with this pairing.
        if let pending = Sign.instance.getPendingProposals().first(where: { $0.proposal.pairingTopic == uri.topic }) {
            proposal = .init(value: pending.proposal, verify: pending.context); working = false; return
        }
        if let existing = Sign.instance.getSessions().first(where: { connections.isAssociated($0.topic, with: uri.topic) && $0.expiryDate > .now && walletMapping[$0.topic] != nil }) {
            refreshSessions(); connectedTopic = existing.topic; working = false
            resumeRequests()
            return
        }
        timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(30)) } catch is CancellationError { return } catch { OathDiagnostics.$operationID.withValue(token) { OathDiagnostics.record(error, component: "walletconnect", operation: "pair_timeout") }; return }
            guard let self, operation == token, working else { return }
            working = false; failed = true
        }
        do { try await Pair.instance.pair(uri: uri) }
        catch {
            OathDiagnostics.$operationID.withValue(token) { OathDiagnostics.record(error, component: "walletconnect", operation: "pair") }
            guard token == operation else { return }; timeout?.cancel(); working = false
            // A queued proposal may arrive while pair() returns its old-pairing
            // error. Do not replace that actionable proposal with an error page.
            guard proposal == nil else { return }
            requiresFreshPairing = OathWalletConnectPolicy.requiresFreshPairing(error)
            failed = true
        }
    }
    func accounts(walletID: String) async -> [AccountRecord] {
        guard let session, session.isUnlocked, session.wallets.contains(where: { $0.id == walletID }) else { return [] }
        do { let db = try await session.vault.database(); var records = try await db.accounts(walletID: walletID)
            for index in records.indices where records[index].networkID == "solana" {
                records[index] = try await db.solanaSigningAccount(accountID: records[index].id)
            }
            guard session.isUnlocked, session.wallets.contains(where: { $0.id == walletID }) else { return [] }
            // The consent page displays one address per network. Negotiate exactly those addresses.
            var seen = Set<String>()
            return records.sorted { $0.accountIndex == $1.accountIndex ? $0.id < $1.id : $0.accountIndex < $1.accountIndex }
                .filter {
                    guard let blockchain = OathImportChain(rawValue: $0.networkID).flatMap(Self.blockchain),
                          OathWalletConnectPolicy.supportsConnection(blockchain.absoluteString) else { return false }
                    return seen.insert($0.networkID).inserted
                } }
        catch { OathDiagnostics.$operationID.withValue(operation) { OathDiagnostics.record(error, component: "walletconnect", operation: "load_accounts") }; failed = true; return [] }
    }
    static func blockchain(_ chain: OathImportChain) -> Blockchain? {
        if chain == .solana { return Blockchain(SolanaSendNetwork.mainnet.walletConnectChain) }
        if chain == .thorchain { return Blockchain(ThorchainWalletConnectRequest.blockchain) }
        guard chain.isEVM, let id = OathTokenNetwork.all.first(where: { $0.chain == chain })?.chainID else { return nil }
        return Blockchain("eip155:\(id)")
    }
    static func blockchains(networkID: String) -> [Blockchain] {
        if networkID == "solana" { return [SolanaSendNetwork.mainnet, .devnet, .testnet].compactMap { Blockchain($0.walletConnectChain) } }
        return OathImportChain(rawValue: networkID).flatMap(blockchain).map { [$0] } ?? []
    }
    private static func accountMatches(_ lhs: String, _ rhs: String, chain: Blockchain) -> Bool {
        chain.namespace == "eip155" ? lhs.lowercased() == rhs.lowercased() : lhs == rhs
    }
    static func requested(_ proposal: Session.Proposal, required: Bool) -> Set<String> {
        let namespaces = required ? proposal.requiredNamespaces : proposal.optionalNamespaces ?? [:]
        return Set(namespaces.flatMap { key, value in value.chains?.map(\.absoluteString) ?? (key.contains(":") ? [key] : []) })
    }
    func namespaces(for proposal: Session.Proposal, accounts: [AccountRecord], selected: Set<String>) throws -> [String: SessionNamespace] {
        // Builder validates every required chain, method, event and account.
        let approved = accounts.flatMap { record -> [Account] in
            Self.blockchains(networkID: record.networkID).filter { selected.contains($0.absoluteString) }
                .compactMap { Account(blockchain: $0, address: record.address) }
        }
        return try OathWalletConnectPolicy.namespaces(for: proposal, accounts: approved)
    }
    func approve(accounts: [AccountRecord], selected: Set<String>, walletID: String, acknowledged: Bool) async {
        guard let proposal, !proposal.blocked, !proposal.unverified || acknowledged,
              session?.isUnlocked == true, !working else { return }
        working = true; failed = false
        let token = operation
        do {
            // Reload ownership immediately before consent is committed.
            let current = await self.accounts(walletID: walletID)
            guard token == operation, session?.isUnlocked == true, self.proposal?.value.id == proposal.value.id,
                  !current.isEmpty, Set(accounts.map(\.id)) == Set(current.map(\.id)) else { throw ConfigurationFailure.invalid }
            let namespaces = try namespaces(for: proposal.value, accounts: current, selected: selected)
            // Transfer a detached value across the SDK's nonisolated async boundary.
            let encoded = try JSONEncoder().encode(namespaces)
            let result = try await Self.commitProposal(id: proposal.value.id, namespaces: encoded)
            guard token == operation, session?.isUnlocked == true, self.proposal?.value.id == proposal.value.id else {
                try await Sign.instance.disconnect(topic: result.topic)
                if token == operation { working = false }
                return
            }
            walletMapping[result.topic] = walletID
            connections.approve(result.topic, pairingTopic: proposal.value.pairingTopic)
            refreshSessions(); self.proposal = nil; connectedTopic = result.topic
            OathHaptics.shared.play(.success)
        } catch {
            OathDiagnostics.$operationID.withValue(token) { OathDiagnostics.record(error, component: "walletconnect", operation: "approve") }
            guard token == operation else { return }
            failed = true
        }
        if token == operation {
            working = false
            // Settlement can deliver the first account/sign-in request before
            // commitProposal returns. Now ownership is stored, replay it; the
            // SDK does not publish an already-pending request a second time.
            if self.proposal == nil { resumeRequests() }
        }
    }
    @concurrent nonisolated private static func commitProposal(id: String, namespaces: Data) async throws -> Session {
        let detached = try JSONDecoder().decode([String: SessionNamespace].self, from: namespaces)
        return try await Sign.instance.approve(proposalId: id, namespaces: detached)
    }
    func reject() async {
        timeout?.cancel(); operation = UUID(); working = false
        let rejected = proposal
        proposal = nil; pairingTopic = nil
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
        if working, proposal != nil { return .committingConnection }
        if working || proposal != nil || pendingRequest != nil || preparingRequest || presentationIssue != nil { return .reviewing }
        if completion != nil { return .completed }
        if presentationOpen, let connectedTopic { return .connected(topic: connectedTopic) }
        return .idle
    }
    private func receive(_ request: Request, context: VerifyContext?) {
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
            // review. A Connected page may hand off to that same peer's first
            // explicit approval, but another peer cannot take over this sheet.
            if Sign.instance.getPendingRequests().count > 8 { respondError(request, code: 4001) }
            return
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
            guard request.chainId.absoluteString == ThorchainWalletConnectRequest.blockchain,
                  pendingRequest == nil, !preparingRequest else { respondError(request, code: 4001); return }
            preparingRequest = true; preparingItem = request; preparationGeneration = UUID()
            let generation = preparationGeneration
            preparationTask = Task { await prepareThorchain(request, peer: peer, walletID: walletID, account: account, generation: generation) }
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
        guard configured, session?.isUnlocked == true, !working, proposal == nil,
              pendingRequest == nil, !preparingRequest, completion == nil, presentationIssue == nil else { return }
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
        let client = try network == .mainnet ? OathTokenRPCConfiguration.bundled().makeSolanaSendClient() : SolanaSendClient(network: network)
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
                    presentationIssue = error as? SolanaSendError == .expired ? .expired : error as? SolanaSendError == .simulationFailed ? .simulation : .invalid
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
                                            // Never replace the blockhash or sign again. After the
                                            // validity window, retain a clear expired outcome.
                                            if Date.now.timeIntervalSince1970 - row.createdAt > 600,
                                               try await client.walletConnectBlockhashValid(input.transactions[0].blockhash) == false {
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
                    async let tokenWork = OathDiagnostics.attemptOptional("walletconnect_approval_metadata") {
                        try await OathEVMSendService.shared.walletConnectApprovalToken(input)
                    }
                    let quote = try await OathEVMSendService.shared.walletConnectQuote(input, requestID: durableSendID(request),
                        walletID: walletID, accountID: record.id, vault: session.vault)
                    let token = await tokenWork
                    guard current(), pendingRequest == nil else { return }
                    completion = nil; presentationIssue = nil
                    // Recover the exact amount previously approved if this is
                    // a replay of an already journaled, edited approval.
                    let reviewed: WalletConnectEVMRequest
                    if input.matches(quote.plan) { reviewed = input }
                    else if input.matchesCommittedApproval(quote.plan), let call = quote.plan.call {
                        reviewed = try input.replacingApprovalAmount(AnkrQuantity.decimal("0x" + call.bytes.suffix(32).map { String(format: "%02x", $0) }.joined()))
                    } else { throw EVMSendError.changed }
                    pendingRequest = .init(request: request, peer: peer, walletID: walletID, account: account, payload: .evm(reviewed, quote), approvalToken: token)
                } catch is CancellationError { }
                catch {
                    guard current() else { return }
                    // Peer format errors are expected protocol validation, not app failures.
                    if !(error is WalletConnectEVMRequest.Failure) && !(error is WalletConnectJSON.Failure) {
                        OathDiagnostics.record(error, component: "walletconnect", operation: "prepare_transaction")
                    }
                    switch error as? EVMSendError {
                    case .insufficientFunds: presentationIssue = .gas(network: network?.rawValue ?? "", address: account)
                    case .simulationFailed: presentationIssue = .simulation
                    case .changed, .metadataChanged: presentationIssue = .changed
                    case .expired: presentationIssue = .expired
                    default: presentationIssue = error is WalletConnectEVMRequest.Failure ? .unsupported : .unavailable
                    }
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
            await OathDiagnostics.$operationID.withValue(UUID()) {
                do {
                    guard let session, current(),
                          let record = await accounts(walletID: walletID).first(where: { $0.networkID == "thorchain" && $0.address == account }) else { throw ConfigurationFailure.invalid }
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
                    if !(error is ThorchainWalletConnectRequest.Failure) && !(error is DecodingError) {
                        OathDiagnostics.record(error, component: "walletconnect", operation: "prepare_thorchain")
                    }
                    if current() { respondError(request, code: error is ThorchainWalletConnectRequest.Failure ? 4200 : 4001); failed = true }
                }
            }
        }
    }
    @concurrent nonisolated private static func decodeThorchain(method: String, data: Data, account: String, publicKey: Data) async throws -> ThorchainWalletConnectRequest {
        guard data.count <= 65_536 else { throw ThorchainWalletConnectRequest.Failure.invalidRequest }
        return try ThorchainWalletConnectRequest(method: method, params: JSONDecoder().decode(SolanaJSON.self, from: data), sender: account, publicKey: publicKey)
    }
    @concurrent nonisolated private static func thorchainReview(_ request: ThorchainWalletConnectRequest, approvedQuote: ThorchainSwapQuote? = nil) async throws -> ThorchainWalletConnectReview {
        // Only a concrete, checksum-valid destination receives a swap template.
        // Names and unsupported memo variants keep the exact protocol review.
        if request.recipient == nil, request.coins.count == 1, request.coins[0].reference == "native",
           let memo = ThorchainSwapMemo(request.memo) {
            guard let network = OathImportChain(rawValue: memo.networkID),
                  OathScanAddress.decode(memo.destination, chain: network) != nil else { throw ThorchainWalletConnectRequest.Failure.invalidRequest }
            // Keep the reviewed estimate through its stated lifetime. Refreshing
            // it after every PIN entry can create an endless re-review loop on
            // a moving pool. The exact signed minimum still protects execution.
            if let approvedQuote, approvedQuote.expires > .now, approvedQuote.memo == memo,
               approvedQuote.input == request.coins[0].amount {
                let review = try await ThorchainSendClient().walletConnectReview(request)
                return .init(fee: review.fee, decimals: review.decimals, checkedAt: review.checkedAt, swap: approvedQuote)
            }
            async let account = ThorchainSendClient().walletConnectReview(request)
            async let quote = ThorchainClient().walletConnectSwapQuote(request)
            let (review, swap) = try await (account, quote)
            return .init(fee: review.fee, decimals: review.decimals, checkedAt: review.checkedAt, swap: swap)
        }
        return try await ThorchainSendClient().walletConnectReview(request)
    }
    @concurrent nonisolated private static func decodeTypedData(_ data: Data, chainID: UInt64, account: String) async throws -> WalletConnectTypedData {
        try Task.checkCancellation()
        return try WalletConnectTypedData(json: data, chainID: chainID, account: account)
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
        signingRequest = true; defer { signingRequest = false }
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
            let updated = try await OathEVMSendService.shared.walletConnectQuote(input, requestID: id,
                walletID: item.walletID, accountID: quote.accountID, vault: session.vault)
            try Task.checkCancellation()
            try validateTransactionAuthorization(operationID: item.operationID)
            guard input.matches(updated.plan), try await db.send(id)?.signedPayload == nil else { throw EVMSendError.changed }
            pendingRequest?.payload = .evm(input, updated)
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
    @discardableResult func presentationDidOpen() -> UUID {
        let id = UUID(); presentationID = id; presentationOpen = true; return id
    }
    func presentationWillDisappear(_ id: UUID?) {
        guard let id, id == presentationID else { return }
        rejectRequest()
        if connectedTopic == nil { Task { await reject() } }
    }
    func presentationDidDismiss() {
        presentationID = nil; presentationOpen = false; completion = nil; presentationIssue = nil; connectedTopic = nil
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
