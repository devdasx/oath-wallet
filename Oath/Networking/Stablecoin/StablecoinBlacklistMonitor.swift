import Foundation

actor StablecoinBlacklistMonitor {
    static let shared = StablecoinBlacklistMonitor()
    private static let client = StablecoinBlacklistClient()
    typealias Loader = @Sendable (StablecoinBlacklistTarget, String) async throws -> Bool
    private let loader: Loader
    private var inFlight: Set<String> = []

    init(loader: @escaping Loader = { target, address in
        try await client.check(target: target, address: address)
    }) { self.loader = loader }

    /// Public account reads only. Import and UI never await this work.
    /// At most four requests run concurrently; successes are saved individually.
    func check(database: WalletDatabase, walletID: String,
               targets: [StablecoinBlacklistTarget] = StablecoinBlacklistRegistry.all) async -> Bool {
        guard inFlight.insert(walletID).inserted else { return false }
        defer { inFlight.remove(walletID) }
        do {
            var accountReady = true
            if targets.contains(where: { $0.networkID == "tron" }),
               try await database.walletCapabilities(walletID: walletID).permits(networkID: "tron") {
                do { _ = try await database.ensureTronAccount(walletID: walletID) }
                catch { accountReady = false }
            }
            let plan = try await database.stablecoinCheckPlan(walletID: walletID, targets: targets)
            let jobs = plan.jobs
            let loader = self.loader
            let accountsComplete = accountReady && plan.accountsComplete
            return await withTaskGroup(of: Bool.self) { group in
                var pending = jobs.makeIterator()
                func enqueue(_ job: StablecoinCheckJob) {
                    group.addTask {
                        do {
                            try Task.checkCancellation()
                            let value = try await loader(job.target, job.address)
                            try Task.checkCancellation()
                            try await database.storeStablecoinCheck(.init(
                                walletID: job.walletID, accountID: job.accountID,
                                networkID: job.target.networkID, contract: job.target.contract,
                                address: job.address, symbol: job.target.symbol,
                                isBlacklisted: value, checkedAt: Date().timeIntervalSince1970
                            ))
                            return true
                        } catch { return false } // Unknown is not persisted as false.
                    }
                }
                for _ in 0..<4 { if let job = pending.next() { enqueue(job) } }
                var complete = accountsComplete
                while let success = await group.next() {
                    complete = complete && success
                    if !Task.isCancelled, let job = pending.next() { enqueue(job) }
                }
                return complete && !Task.isCancelled
            }
        } catch { return false }
    }
}
