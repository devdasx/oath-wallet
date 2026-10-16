import Foundation
import OathDatabase
import OathAnkr

actor OathAnkrSync {
    static let shared = OathAnkrSync()
    private var service: AnkrSynchronizer?
    private var tron: TronSynchronizer?
    private var ton: TonSynchronizer?
    private var aptos: AptosSynchronizer?
    private var sui: SuiSynchronizer?
    private var thorchain: ThorchainSynchronizer?
    private var near: NearSynchronizer?
    private var xrpl: XrplSynchronizer?
    private var stellar: StellarSynchronizer?
    private var arc: ArcSynchronizer?
    private var indexedEVM: [IndexedEVMChain: IndexedEVMSynchronizer] = [:]
    private var hyperevm: HyperEVMSynchronizer?
    private var robinhood: RobinhoodSynchronizer?
    private var solana: SolanaSynchronizer?
    private var epoch = UUID()
    private func synchronizer() async throws -> AnkrSynchronizer {
        if let service { return service }
        let ticket = epoch
        let db = try await OathDataEnvironment.shared.database()
        guard ticket == epoch, !Task.isCancelled else { throw CancellationError() }
        if let service { return service }
        let created = try OathTokenRPCConfiguration.bundled().makeAccountSynchronizer(database: db)
        service = created
        return created
    }
    func refresh(walletID: String) async throws {
        let ticket = epoch
        let service = try await synchronizer()
        guard ticket == epoch, !Task.isCancelled else { throw CancellationError() }
        let results = try await service.refresh(walletID: walletID)
        guard ticket == epoch, !Task.isCancelled else { throw CancellationError() }
        guard results.allSatisfy(\.success) else { throw OathWalletError.unavailable }
    }
    func refreshBalances(walletID: String) async throws {
        let ticket = epoch
        let service = try await synchronizer()
        guard ticket == epoch, !Task.isCancelled else { throw CancellationError() }
        let results = try await service.refreshBalances(walletID: walletID)
        guard ticket == epoch, !Task.isCancelled else { throw CancellationError() }
        guard results.allSatisfy(\.success) else { throw OathWalletError.unavailable }
    }
    func refreshSolana(accountID: String) async throws {
        let ticket = epoch
        let db = try await OathDataEnvironment.shared.database()
        guard ticket == epoch, !Task.isCancelled else { throw CancellationError() }
        if solana == nil { solana = try OathTokenRPCConfiguration.bundled().makeSolanaSynchronizer(database: db) }
        try await solana!.refresh(accountID: accountID)
    }
    func refreshTron(accountID: String) async throws {
        let ticket = epoch
        let db = try await OathDataEnvironment.shared.database()
        guard ticket == epoch, !Task.isCancelled else { throw CancellationError() }
        if tron == nil { tron = try OathTokenRPCConfiguration.bundled().makeTronSynchronizer(database: db) }
        try await tron!.refresh(accountID: accountID)
    }
    func refreshTon(accountID: String) async throws {
        let ticket = epoch
        let db = try await OathDataEnvironment.shared.database()
        guard ticket == epoch, !Task.isCancelled else { throw CancellationError() }
        if ton == nil { ton = try OathTokenRPCConfiguration.bundled().makeTonSynchronizer(database: db) }
        try await ton!.refresh(accountID: accountID)
    }
    func refreshAptos(accountID: String) async throws {
        let ticket = epoch
        let db = try await OathDataEnvironment.shared.database()
        guard ticket == epoch, !Task.isCancelled else { throw CancellationError() }
        if aptos == nil { aptos = try OathTokenRPCConfiguration.bundled().makeAptosSynchronizer(database: db) }
        try await aptos!.refresh(accountID: accountID)
    }
    func refreshSui(accountID: String) async throws {
        let ticket = epoch
        let db = try await OathDataEnvironment.shared.database()
        guard ticket == epoch, !Task.isCancelled else { throw CancellationError() }
        if sui == nil { sui = try OathTokenRPCConfiguration.bundled().makeSuiSynchronizer(database: db) }
        try await sui!.refresh(accountID: accountID)
    }
    func refreshThorchain(accountID: String) async throws {
        let ticket = epoch
        let db = try await OathDataEnvironment.shared.database()
        guard ticket == epoch, !Task.isCancelled else { throw CancellationError() }
        if thorchain == nil { thorchain = ThorchainSynchronizer(database: db) }
        try await thorchain!.refresh(accountID: accountID)
    }
    func refreshNear(accountID: String) async throws {
        let ticket = epoch
        let db = try await OathDataEnvironment.shared.database()
        guard ticket == epoch, !Task.isCancelled else { throw CancellationError() }
        if near == nil { near = try OathTokenRPCConfiguration.bundled().makeNearSynchronizer(database: db) }
        try await near!.refresh(accountID: accountID)
    }
    func refreshXrpl(accountID: String) async throws {
        let ticket = epoch
        let db = try await OathDataEnvironment.shared.database()
        guard ticket == epoch, !Task.isCancelled else { throw CancellationError() }
        if xrpl == nil { xrpl = try OathTokenRPCConfiguration.bundled().makeXrplSynchronizer(database: db) }
        try await xrpl!.refresh(accountID: accountID)
    }
    func refreshStellar(accountID: String) async throws {
        let ticket = epoch
        let db = try await OathDataEnvironment.shared.database()
        guard ticket == epoch, !Task.isCancelled else { throw CancellationError() }
        if stellar == nil { stellar = try OathTokenRPCConfiguration.bundled().makeStellarSynchronizer(database: db) }
        try await stellar!.refresh(accountID: accountID)
    }
    private func cancelIndexedEVM() async {
        await withTaskGroup(of: Void.self) { group in
            for service in indexedEVM.values { group.addTask { await service.cancel() } }
            await group.waitForAll()
        }
    }
    func refreshIndexedEVM(accountID: String, chain: IndexedEVMChain) async throws {
        let ticket = epoch
        let db = try await OathDataEnvironment.shared.database()
        guard ticket == epoch, !Task.isCancelled else { throw CancellationError() }
        if indexedEVM[chain] == nil { indexedEVM[chain] = try OathTokenRPCConfiguration.bundled().makeIndexedEVMSynchronizer(database: db, chain: chain) }
        try await indexedEVM[chain]!.refresh(accountID: accountID)
    }
    func refreshHyperEVM(accountID: String) async throws {
        let ticket = epoch
        let db = try await OathDataEnvironment.shared.database()
        guard ticket == epoch, !Task.isCancelled else { throw CancellationError() }
        if hyperevm == nil { hyperevm = try OathTokenRPCConfiguration.bundled().makeHyperEVMSynchronizer(database: db) }
        try await hyperevm!.refresh(accountID: accountID)
    }
    func refreshRobinhood(accountID: String) async throws {
        let ticket = epoch
        let db = try await OathDataEnvironment.shared.database()
        guard ticket == epoch, !Task.isCancelled else { throw CancellationError() }
        if robinhood == nil { robinhood = try OathTokenRPCConfiguration.bundled().makeRobinhoodSynchronizer(database: db) }
        try await robinhood!.refresh(accountID: accountID)
    }
    func refreshArc(accountID: String) async throws {
        let ticket = epoch
        let db = try await OathDataEnvironment.shared.database()
        guard ticket == epoch, !Task.isCancelled else { throw CancellationError() }
        if arc == nil { arc = try OathTokenRPCConfiguration.bundled().makeArcSynchronizer(database: db) }
        try await arc!.refresh(accountID: accountID)
    }
    func cancel() async {
        epoch = UUID()
        async let evm: () = service?.cancel() ?? ()
        async let sol: () = solana?.cancel() ?? ()
        async let trx: () = tron?.cancel() ?? ()
        async let gram: () = ton?.cancel() ?? ()
        async let apt: () = aptos?.cancel() ?? ()
        async let suiResult: () = sui?.cancel() ?? ()
        async let thorchainResult: () = thorchain?.cancel() ?? ()
        async let nearResult: () = near?.cancel() ?? ()
        async let xrplResult: () = xrpl?.cancel() ?? ()
        async let stellarResult: () = stellar?.cancel() ?? ()
        async let robinhoodResult: () = robinhood?.cancel() ?? ()
        async let indexedResult: () = cancelIndexedEVM()
        async let hyperResult: () = hyperevm?.cancel() ?? ()
        async let arcResult: () = arc?.cancel() ?? ()
        _ = await (thorchainResult, indexedResult, hyperResult, arcResult, evm, sol, trx, gram, apt, suiResult, nearResult, xrplResult, stellarResult, robinhoodResult)
    }
}
