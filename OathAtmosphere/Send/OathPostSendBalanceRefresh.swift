import Foundation
import OathAnkr
import OathBitcoin
import OathDatabase
import OathDiagnostics

/// Application lifetime, independent of the send sheet and selected wallet.
/// New send adapters use the same durable journal/worker and add their balance
/// refresh + observation check here; no screen-owned retry tasks are needed.
actor OathPostSendBalanceRefresh {
    static let shared = OathPostSendBalanceRefresh()
    private var worker: PostSendBalanceRefresher?
    private var generation = UUID()

    func resume(vault: OathWalletVault) async {
        let ticket = generation
        do {
            if worker == nil {
                let database = try await vault.database()
                guard ticket == generation else { return }
                // Foreground and unlock can arrive together while the vault
                // awaits its database. Preserve the worker created meanwhile.
                if let worker { await worker.resume(); return }
                worker = PostSendBalanceRefresher(database: database) { target, sends in
                    if target.networkID == "sui" {
                        let accounts = try await database.accounts(walletID:target.walletID).filter { $0.networkID == "sui" }
                        guard !accounts.isEmpty else { throw StoreError.missingRecord }
                        for account in accounts { try await OathAnkrSync.shared.refreshSui(accountID:account.id) }
                        var observed = Set<String>()
                        for send in sends where try await database.suiSendBalanceIsCurrent(send) { observed.insert(send.id) }
                        return observed
                    }
                    if target.networkID == "xrpl" {
                        let accounts = try await database.accounts(walletID:target.walletID).filter { $0.networkID == "xrpl" }
                        guard !accounts.isEmpty else { throw StoreError.missingRecord }
                        for account in accounts { try await OathAnkrSync.shared.refreshXrpl(accountID:account.id) }
                        var observed = Set<String>()
                        for send in sends where try await database.xrplSendBalanceIsCurrent(send) { observed.insert(send.id) }
                        return observed
                    }
                    if target.networkID == "stellar" {
                        let accounts = try await database.accounts(walletID:target.walletID).filter { $0.networkID == "stellar" }
                        guard !accounts.isEmpty else { throw StoreError.missingRecord }
                        for account in accounts { try await OathAnkrSync.shared.refreshStellar(accountID:account.id) }
                        var observed = Set<String>()
                        for send in sends where try await database.stellarSendBalanceIsCurrent(send) { observed.insert(send.id) }
                        return observed
                    }
                    if target.networkID == "tron" {
                        let accounts = try await database.accounts(walletID:target.walletID).filter { $0.networkID == "tron" }
                        guard !accounts.isEmpty else { throw StoreError.missingRecord }
                        for account in accounts { try await OathAnkrSync.shared.refreshTron(accountID:account.id) }
                        var observed = Set<String>()
                        for send in sends where try await database.tronSendBalanceIsCurrent(send) { observed.insert(send.id) }
                        return observed
                    }
                    if target.networkID == "near" {
                        let accounts = try await database.accounts(walletID:target.walletID).filter { $0.networkID == "near" }
                        guard !accounts.isEmpty else { throw StoreError.missingRecord }
                        for account in accounts { try await OathAnkrSync.shared.refreshNear(accountID:account.id) }
                        var observed = Set<String>()
                        for send in sends where try await database.nearSendBalanceIsCurrent(send) { observed.insert(send.id) }
                        return observed
                    }
                    if target.networkID == "polkadot" {
                        let accounts = try await database.accounts(walletID:target.walletID).filter { $0.networkID == "polkadot" }
                        guard !accounts.isEmpty else { throw StoreError.missingRecord }
                        for account in accounts { try await OathAnkrSync.shared.refreshPolkadot(accountID:account.id) }
                        var observed = Set<String>()
                        for send in sends where try await database.polkadotSendBalanceIsCurrent(send) { observed.insert(send.id) }
                        return observed
                    }
                    if target.networkID == "solana" {
                        let accounts = try await database.accounts(walletID:target.walletID).filter { $0.networkID == "solana" }
                        guard !accounts.isEmpty else { throw StoreError.missingRecord }
                        for account in accounts { try await OathAnkrSync.shared.refreshSolana(accountID:account.id) }
                        var observed = Set<String>()
                        for send in sends where try await database.solanaSendBalanceIsCurrent(send) { observed.insert(send.id) }
                        return observed
                    }
                    if let network=EVMSendNetwork(rawValue:target.networkID),!network.isTestnet, network != .arc {
                        let client=try await OathEVMSendService.shared.connection(network)
                        var observed=Set<String>()
                        for send in sends where try await database.refreshEVMSendBalance(send,client:client) { observed.insert(send.id) }
                        return observed
                    }
                    if target.networkID == "arc" {
                        var observed = Set<String>()
                        var legacy = [SendRecord]()
                        for send in sends {
                            if try await database.evmSendPlan(sendID: send.id) != nil {
                                let client = try await OathEVMSendService.shared.connection(.arc)
                                if try await database.refreshEVMSendBalance(send, client: client) { observed.insert(send.id) }
                            } else { legacy.append(send) }
                        }
                        if legacy.isEmpty { return observed }
                        let accounts = try await database.accounts(walletID:target.walletID).filter { $0.networkID == "arc" }
                        guard !accounts.isEmpty else { throw StoreError.missingRecord }
                        for account in accounts { try await OathAnkrSync.shared.refreshArc(accountID:account.id) }
                        for send in legacy where try await database.arcSendBalanceIsCurrent(send) { observed.insert(send.id) }
                        return observed
                    }
                    if target.networkID == "aptos" {
                        let accounts = try await database.accounts(walletID:target.walletID).filter { $0.networkID == "aptos" }
                        guard !accounts.isEmpty else { throw StoreError.missingRecord }
                        for account in accounts { try await OathAnkrSync.shared.refreshAptos(accountID:account.id) }
                        var observed = Set<String>()
                        for send in sends where try await database.aptosSendBalanceIsCurrent(send) { observed.insert(send.id) }
                        return observed
                    }
                    if target.networkID == "thorchain" {
                        let accounts = try await database.accounts(walletID:target.walletID).filter { $0.networkID == "thorchain" }
                        guard !accounts.isEmpty else { throw StoreError.missingRecord }
                        for account in accounts { try await OathAnkrSync.shared.refreshThorchain(accountID:account.id) }
                        var observed = Set<String>()
                        for send in sends where try await database.thorchainSendBalanceIsCurrent(send) { observed.insert(send.id) }
                        return observed
                    }
                    if target.networkID == "ton" {
                        let accounts = try await database.accounts(walletID:target.walletID).filter { $0.networkID == "ton" }
                        guard !accounts.isEmpty else { throw StoreError.missingRecord }
                        for account in accounts { try await OathAnkrSync.shared.refreshTon(accountID:account.id) }
                        var observed = Set<String>()
                        for send in sends where try await database.tonSendBalanceIsCurrent(send) { observed.insert(send.id) }
                        return observed
                    }
                    guard UTXONetwork(rawValue: target.networkID) != nil else {
                        throw StoreError.invalidValue("missing post-send balance adapter")
                    }
                    let accounts = try await database.accounts(walletID: target.walletID)
                        .filter { $0.networkID == target.networkID }
                    guard !accounts.isEmpty else { throw StoreError.missingRecord }
                    // Include every HD account of the original wallet/chain:
                    // a spend may combine receive/change outputs across types.
                    try await withThrowingTaskGroup(of: Void.self) { group in
                        for account in accounts {
                            group.addTask {
                                try await OathBitcoinSync.shared.refresh(accountID: account.id, vault: vault, includeHistory: false)
                            }
                        }
                        try await group.waitForAll()
                    }
                    try Task.checkCancellation()
                    var observed: Set<String> = []
                    for send in sends where try await database.bitcoinSendBalanceIsCurrent(send) {
                        observed.insert(send.id)
                    }
                    return observed
                }
            }
            await worker?.resume()
        } catch { OathDiagnostics.record(error, component: "send", operation: "balance_refresh_start") }
    }

    func submitted(walletID: String, networkID: String) async {
        await worker?.request(.init(walletID: walletID, networkID: networkID))
    }
    func pause() async { generation = UUID(); await worker?.pause() }
    func reset() async {
        generation = UUID()
        await worker?.pause()
        worker = nil
    }
}
