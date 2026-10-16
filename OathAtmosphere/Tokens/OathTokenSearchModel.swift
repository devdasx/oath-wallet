import OathDiagnostics
import Foundation
import Observation
import OathDatabase

@Observable @MainActor final class OathTokenSearchModel {
    private(set) var results: [OathTokenDefinition] = []
    private(set) var failedNetworks: [OathTokenNetwork] = []
    private(set) var isSearching = false
    private(set) var isAddress = false
    private(set) var unavailableForWallet = false
    private(set) var invalidAddress = false
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private let service: any OathTokenLookingUp

    init(service: any OathTokenLookingUp = OathTokenService.shared) { self.service = service }

    func reset() {
        generation = UUID(); results = []; failedNetworks = []
        isSearching = false; isAddress = false; unavailableForWallet = false; invalidAddress = false
    }

    func search(_ raw: String, available: Set<OathImportChain>, savedNetworks: Set<String> = []) async {
        reset()
        let request = generation
        let query = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidates = OathTokenAddress.networks(for: query)
        guard !candidates.isEmpty else {
            invalidAddress = query.lowercased().hasPrefix("0x") && query.count >= 42
                || (query.count == 34 && query.hasPrefix("T"))
            return
        }
        isAddress = true
        let enabled = candidates.filter { available.contains($0.chain) }
        unavailableForWallet = enabled.isEmpty
        let networks = enabled.filter { !savedNetworks.contains($0.id) }
        guard !networks.isEmpty else { return }
        isSearching = true
        defer { if generation == request { isSearching = false } }
        do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
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
