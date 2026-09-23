import Combine
import Foundation

@MainActor
final class EVMAccessManagerModel: ObservableObject {
    enum RefreshState: Equatable {
        case idle
        case loading
        case loaded
        case partialFailure([String])
        case unavailable
    }

    @Published private(set) var approvals: [EVMOnChainApproval] = []
    @Published private(set) var refreshState: RefreshState = .idle
    @Published private(set) var isAvailable = true

    private let database: WalletDatabase
    private var context: EVMAccessWalletContext?
    private var hasLoaded = false

    init(database: WalletDatabase) {
        self.database = database
    }

    func load() async {
        guard !hasLoaded else { return }
        hasLoaded = true
        do {
            guard let context = try await database
                .selectedWalletEVMAccessContext() else {
                isAvailable = false
                return
            }
            self.context = context
            await loadCached(context: context)
            await refresh()
        } catch {
            isAvailable = false
        }
    }

    func refresh() async {
        guard let context else { return }
        refreshState = .loading
        do {
            let discovery = try EVMApprovalDiscoveryService.configured()
            let attempts = await withTaskGroup(
                of: ScanAttempt.self,
                returning: [ScanAttempt].self
            ) { group in
                for account in context.accounts {
                    group.addTask {
                        do {
                            return .success(
                                try await discovery.scan(account: account)
                            )
                        } catch {
                            return .failure(account.networkID)
                        }
                    }
                }
                var values: [ScanAttempt] = []
                for await attempt in group {
                    values.append(attempt)
                }
                return values
            }
            var failedNetworks = Set<String>()
            for attempt in attempts {
                switch attempt {
                case let .success(result):
                    try await database.reconcileEVMApprovals(
                        accountID: result.accountID,
                        networkID: result.networkID,
                        active: result.active,
                        inactiveIDs: result.inactiveIDs
                    )
                    if result.unresolvedCount > 0 {
                        failedNetworks.insert(result.networkID)
                    }
                case let .failure(networkID):
                    failedNetworks.insert(networkID)
                }
            }
            await loadCached(context: context)
            refreshState = failedNetworks.isEmpty
                ? .loaded
                : .partialFailure(failedNetworks.sorted())
        } catch {
            await loadCached(context: context)
            refreshState = .unavailable
        }
    }

    func markPending(_ outcome: EVMApprovalRevocationOutcome) async {
        guard let context else { return }
        await loadCached(context: context)
    }

    func reloadCached() async {
        guard let context else { return }
        await loadCached(context: context)
    }

    private func loadCached(context: EVMAccessWalletContext) async {
        let accountIDs = context.accounts.map(\.id)
        approvals = (try? await database.activeEVMApprovals(
            accountIDs: accountIDs
        )) ?? approvals
    }
}

private enum ScanAttempt: Sendable {
    case success(EVMApprovalScanResult)
    case failure(String)
}
