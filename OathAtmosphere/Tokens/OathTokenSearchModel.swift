import OathDiagnostics
import Foundation
import Observation
import OathDatabase
import OathAnkr

protocol OathTokenDiscovering: Sendable {
    func search(_ query: String, networks: Set<String>, excluding: Set<String>, limit: Int) async -> [TokenDiscoveryEntry]
    func refreshIfNeeded() async -> Bool
}
extension TokenDiscoveryCatalog: OathTokenDiscovering {}

/// All search entry points use the same wallet-scoped request. Balance/price
/// updates do not restart lookup; account, saved-token or query changes do.
struct OathTokenSearchRequest: Hashable {
    let query: String
    let walletID: String?
    let active: Bool
    let networks: Set<OathImportChain>
    let savedIDs: Set<String>
    let requiredReference: String?
    var attempt: Int = 0

    init(query: String, walletID: String?, active: Bool, snapshot: WalletSnapshot?,
         permittedNetworks: Set<OathImportChain>? = nil, requiredReference: String? = nil) {
        self.query = query
        self.walletID = walletID
        self.requiredReference = requiredReference
        let snapshot = snapshot?.wallet.id == walletID ? snapshot : nil
        let available = Set((snapshot?.accounts ?? []).compactMap { OathImportChain(rawValue: $0.networkID) })
        networks = permittedNetworks.map { available.intersection($0) } ?? available
        savedIDs = Set((snapshot?.holdings ?? []).map { $0.networkID + ":" + $0.reference })
        self.active = active && snapshot != nil && !networks.isEmpty
    }

    var hasQuery: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

@Observable @MainActor final class OathTokenSearchModel {
    private(set) var results: [OathTokenDefinition] = []
    private(set) var failedNetworks: [OathTokenNetwork] = []
    private(set) var isSearching = false
    private(set) var isAddress = false
    private(set) var isCatalogQuery = false
    private(set) var unavailableForWallet = false
    private(set) var invalidAddress = false
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private let service: any OathTokenLookingUp
    @ObservationIgnored private let catalog: any OathTokenDiscovering

    init(service: any OathTokenLookingUp = OathTokenService.shared,
         catalog: any OathTokenDiscovering = TokenDiscoveryCatalog.shared) {
        self.service = service; self.catalog = catalog
    }

    func reset() {
        generation = UUID(); results = []; failedNetworks = []
        isSearching = false; isAddress = false; isCatalogQuery = false; unavailableForWallet = false; invalidAddress = false
    }

    func search(_ request: OathTokenSearchRequest) async {
        guard request.active else { reset(); return }
        await search(request.query, available: request.networks, savedIDs: request.savedIDs,
                     requiredReference: request.requiredReference)
    }

    func search(_ raw: String, available: Set<OathImportChain>, savedNetworks: Set<String> = [], savedIDs: Set<String> = [],
                requiredReference: String? = nil) async {
        reset()
        let request = generation
        let query = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, query.utf8.count <= 4096 else { return }
        isCatalogQuery = true; isSearching = true
        defer { if generation == request { isSearching = false } }
        // A scanned native-coin payment must never turn into a token payment.
        // This is an expected search constraint, not a provider failure.
        guard requiredReference != "native" else { return }
        let matches: @Sendable (OathTokenDefinition) -> Bool = { token in
            // RPC lookup and catalog entries must use the same saved identity,
            // including native coins exposed through an ERC-20 interface.
            guard !savedIDs.contains(token.id) else { return false }
            guard let requiredReference else { return true }
            return token.network.chain.isEVM
                ? token.reference.lowercased() == requiredReference.lowercased()
                : token.reference == requiredReference
        }
        do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
        guard !Task.isCancelled, generation == request else { return }
        let networkIDs = Set(available.map(\.id))
        let found = await catalog.search(query, networks: networkIDs, excluding: savedIDs, limit: 200)
        let definitions = await Task.detached(priority: .userInitiated) {
            found.compactMap(OathTokenDefinition.discovery).filter(matches)
        }.value
        guard !Task.isCancelled, generation == request else { return }
        results = definitions
        let candidates = OathTokenAddress.networks(for: query)
        guard !candidates.isEmpty else {
            invalidAddress = query.lowercased().hasPrefix("0x") && query.count >= 42
                || (query.count == 34 && query.hasPrefix("T"))
            if !results.isEmpty { invalidAddress = false }
            // Cached rows are already visible. The shared refresh can outlive
            // this waiter; only this generation may publish its updated matches.
            isSearching = results.isEmpty
            if await catalog.refreshIfNeeded() {
                guard !Task.isCancelled, generation == request else { return }
                let updated = await catalog.search(query, networks: networkIDs, excluding: savedIDs, limit: 200)
                let definitions = await Task.detached(priority: .userInitiated) {
                    updated.compactMap(OathTokenDefinition.discovery).filter(matches)
                }.value
                guard !Task.isCancelled, generation == request else { return }
                results = definitions
                if !results.isEmpty { invalidAddress = false }
            }
            return
        }
        isAddress = true
        // An indexed exact address needs no speculative RPC fan-out. Search by
        // name still returns other networks using their distinct real contracts.
        if !results.isEmpty { return }
        let enabled = candidates.filter { available.contains($0.chain) }
        unavailableForWallet = enabled.isEmpty
        let networks = enabled.filter { !savedNetworks.contains($0.id) }
        guard !networks.isEmpty else { return }
        isSearching = true
        guard !Task.isCancelled, generation == request else { return }
        let service = service
        await withTaskGroup(of: (OathTokenNetwork, Result<OathTokenDefinition?, OathTokenLookupError>).self) { group in
            var next = 0
            func enqueue() {
                guard next < networks.count, !Task.isCancelled else { return }
                let network = networks[next]; next += 1
                group.addTask {
                    await OathDiagnostics.$chain.withValue(network.id) {
                        await OathDiagnostics.$operationID.withValue(UUID()) {
                            do { return (network, .success(try await service.lookup(address: query, network: network))) }
                            catch is CancellationError { return (network, .success(nil)) }
                            catch OathTokenLookupError.notToken {
                                // diagnostics: token-search-absence. Searching across
                                // networks normally finds no token on most of them.
                                return (network, .success(nil))
                            }
                            catch let error as OathTokenLookupError {
                                OathDiagnostics.record(error, component: "token_lookup", operation: "search")
                                return (network, .failure(error))
                            }
                            catch {
                                OathDiagnostics.record(error, component: "token_lookup", operation: "search")
                                return (network, .failure(.unavailable))
                            }
                        }
                    }
                }
            }
            for _ in 0..<min(4, networks.count) { enqueue() }
            for await (network, result) in group {
                guard !Task.isCancelled, generation == request else { group.cancelAll(); return }
                switch result {
                case .success(let token?):
                    guard matches(token), !savedIDs.contains(token.id) else { enqueue(); continue }
                    results.append(token)
                    results = AssetOrdering.sorted(results) { AssetSortKey(name: $0.name, identity: $0.id) }
                case .success(nil): break
                case .failure:
                    failedNetworks.append(network)
                    failedNetworks.sort { $0.chain.name < $1.chain.name }
                }
                enqueue()
            }
        }
    }
}

/// Session-owned background tracking. Navigation uses public catalog identity
/// immediately; only persisted holdings can supply spendable amounts/metadata.
@MainActor final class OathTokenSelectionModel {
    private struct Pending {
        let token: OathTokenDefinition
        let walletID: String
        let add: @MainActor (OathTokenDefinition, String) async throws -> WalletSnapshot
        var id: String { walletID + ":" + token.id }
    }
    private var generation = UUID()
    private var queue: [Pending] = []
    private var work: [String: Task<Void, Never>] = [:]
    var pendingCount: Int { queue.count + work.count }

    func select(_ token: OathTokenDefinition, walletID: String, snapshot: WalletSnapshot,
                add: @escaping @MainActor (OathTokenDefinition, String) async throws -> WalletSnapshot,
                onSelected: @MainActor (Holding, WalletSnapshot) -> Void) {
        guard snapshot.wallet.id == walletID,
              let account = snapshot.accounts.first(where: { $0.networkID == token.network.id }) else { return }
        let reference = token.isNativeRepresentation ? "native" : token.reference
        if let saved = snapshot.holdings.first(where: { $0.networkID == token.network.id && $0.reference == reference }) {
            onSelected(saved, snapshot)
            return
        }
        // Retain Solana's current receive path instead of an account's original
        // import address. No provider call or database write gates navigation.
        let address = snapshot.holdings.first { $0.accountID == account.id && $0.reference == "native" }?.address ?? account.address
        let preview = Holding.catalogPreview(account: account, address: address, assetID: token.id,
            reference: reference, name: token.name, symbol: token.symbol, logo: token.logoURL?.absoluteString)
        let pending = Pending(token: token, walletID: walletID, add: add)
        if work[pending.id] == nil && !queue.contains(where: { $0.id == pending.id }) {
            // Bound rapid background selections to the catalog's result limit.
            if pendingCount < 200 {
                queue.append(pending)
                startNext()
            } else {
                OathDiagnostics.record(DiagnosticFailure("token_selection_capacity"), component: "token_search",
                    operation: "queue_token", context: ["chain": token.network.id])
            }
        }
        onSelected(preview, snapshot)
    }

    private func startNext() {
        while work.count < 4, !queue.isEmpty {
            let pending = queue.removeFirst(), request = generation
            work[pending.id] = Task { [weak self] in
                await OathDiagnostics.$chain.withValue(pending.token.network.id) {
                    await OathDiagnostics.$operationID.withValue(UUID()) {
                        defer {
                            if let self, self.generation == request {
                                self.work.removeValue(forKey: pending.id)
                                self.startNext()
                            }
                        }
                        do {
                            let snapshot = try await pending.add(pending.token, pending.walletID)
                            try Task.checkCancellation()
                            guard self?.generation == request else { return }
                            guard snapshot.wallet.id == pending.walletID,
                                  snapshot.holdings.contains(where: {
                                      $0.networkID == pending.token.network.id && !$0.isCatalogPreview &&
                                      $0.reference == (pending.token.isNativeRepresentation ? "native" : pending.token.reference)
                                  }) else { throw StoreError.conflictingIdentity }
                            // The ordinary portfolio observer updates all screens.
                            // Completion never navigates, vibrates, or shows an alert.
                        } catch is CancellationError {
                            // Lock, wallet change and reset cancel this session's work.
                        } catch {
                            guard self?.generation == request, !Task.isCancelled else { return }
                            OathDiagnostics.record(error, component: "token_search", operation: "select_token")
                        }
                    }
                }
            }
        }
    }

    func cancel() {
        generation = UUID()
        queue.removeAll()
        for task in work.values { task.cancel() }
        work.removeAll()
    }
}
