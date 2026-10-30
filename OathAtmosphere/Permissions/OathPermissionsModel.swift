import Foundation
import Observation
import OathAnkr
import OathDatabase
import OathDiagnostics

@MainActor @Observable final class OathPermissionsModel {
    var walletID=""
    var accounts=[AccountRecord]()
    var scans=[String:PermissionScan]()
    var holdings=[Holding]()
    var history=[PermissionRemovalHistory]()
    var scanning=Set<String>()
    var failure=false
    var currency="USD"
    private var generation=UUID()
    var identities = [String: ContractIdentity]()
    var permissions:[WalletPermission] { scans.values.flatMap(\.permissions).sorted{$0.id<$1.id} }
    func holding(_ p:WalletPermission)->Holding? { holdings.first{$0.networkID==p.network && (EVMSendNetwork(rawValue:p.network) != nil ? $0.reference.lowercased()==p.identityAddress.lowercased():$0.reference==p.identityAddress)} }
    func identity(_ p: WalletPermission) -> ContractIdentity? { identities[p.identityKey] }
    func name(_ p: WalletPermission) -> String? { identity(p)?.name ?? holding(p)?.name }
    func spenderName(_ p: WalletPermission) -> String? { identities[p.spenderIdentityKey]?.name }
    var identityRequestKey: [String] { [walletID] + permissions.map(\.id) }
    func resolveIdentities(session: OathWalletSession, items: [WalletPermission]? = nil) async {
        let token = generation, wallet = walletID, items = items ?? permissions
        guard session.isUnlocked, !items.isEmpty else { return }
        struct Target: Sendable { let network: String, address: String, asset: Bool; var key: String { WalletPermission.identityKey(network: network, address: address) } }
        var targets = [String: Target]()
        for p in items {
            let spender = Target(network: p.network, address: p.spender, asset: false)
            if targets[spender.key] == nil { targets[spender.key] = spender }
            let asset = Target(network: p.network, address: p.identityAddress, asset: ![.accountControl, .delegation].contains(p.kind))
            if targets[asset.key]?.asset != true { targets[asset.key] = asset }
        }
        do {
            let db = try await session.vault.database()
            for (network, group) in Dictionary(grouping: targets.values, by: \.network) {
                for start in stride(from: 0, to: group.count, by: 1_000) {
                    let cached = try await db.contractIdentities(network: network, addresses: group[start..<min(start+1_000, group.count)].map(\.address))
                    guard generation == token, walletID == wallet, session.isUnlocked, !Task.isCancelled else { return }
                    for identity in cached { identities[identity.id] = identity }
                }
            }
            let missing = targets.values.filter { target in
                guard let cached = identities[target.key] else { return true }
                // A generic verified source name (for example a proxy class)
                // must not prevent a later token-name lookup after an outage.
                let lifetime: TimeInterval = target.asset && cached.source == .sourcify ? 300 : 7 * 86_400
                return Date.now.timeIntervalSince(cached.checkedAt) >= lifetime
            }.sorted { $0.key < $1.key }
            // At most four unique contracts resolve concurrently across every chain.
            // Apply each result as it arrives, independently of the permission scan.
            await withTaskGroup(of: ContractIdentity?.self) { group in
                var next = 0
                func enqueue() {
                    guard next < missing.count, !Task.isCancelled else { return }
                    let target = missing[next]; next += 1
                    group.addTask {
                        do { return try await OathPermissionService.shared.identity(network: target.network, address: target.address, asset: target.asset) }
                        catch {
                            if !Task.isCancelled, !(error is CancellationError) { OathDiagnostics.record(error, component: "permissions", operation: "resolve_identity", context: ["chain": target.network]) }
                            return nil
                        }
                    }
                }
                for _ in 0..<min(4, missing.count) { enqueue() }
                for await identity in group {
                    guard generation == token, walletID == wallet, session.isUnlocked, !Task.isCancelled else { group.cancelAll(); return }
                    if let identity {
                        identities[identity.id] = identity
                        do { try await db.saveContractIdentities([identity]) }
                        catch { OathDiagnostics.record(error, component: "permissions", operation: "cache_identity") }
                    }
                    enqueue()
                }
            }
        } catch { if !Task.isCancelled { OathDiagnostics.record(error, component: "permissions", operation: "load_identities") } }
    }
    func account(_ p:WalletPermission)->AccountRecord? { accounts.first{$0.networkID==p.network} }
    func load(session:OathWalletSession) async {
        let token=UUID();generation=token;failure=false;scans=[:];accounts=[];history=[];holdings=[];scanning=[];identities=[:]
        do {
            let db=try await session.vault.database(),wallet=walletID
            async let a=db.accounts(walletID:wallet)
            async let s=db.permissionScans(walletID:wallet)
            async let h=db.permissionHistory(walletID:wallet)
            async let p=db.snapshot(walletID:wallet,currency:session.portfolio?.currency ?? "USD")
            let (loaded,cached,history,snapshot)=try await(a,s,h,p)
            guard generation==token,!Task.isCancelled else { return }
            accounts=loaded.filter{EVMSendNetwork(rawValue:$0.networkID) != nil || ["tron","solana","arc"].contains($0.networkID)}
            var owners=Dictionary(accounts.map{($0.networkID,$0.address)},uniquingKeysWith:{first,_ in first})
            for account in accounts where account.networkID=="solana" { owners["solana"]=try await db.solanaSigningAccount(accountID:account.id).address }
            guard generation==token,!Task.isCancelled else { return }
            let current=cached.filter { scan in
                guard let owner=owners[scan.network] else { return false }
                return EVMSendNetwork(rawValue:scan.network) != nil ? owner.lowercased()==scan.owner.lowercased():owner==scan.owner
            }
            scans=Dictionary(current.map{($0.network,$0)},uniquingKeysWith:{$0.checkedAt>$1.checkedAt ? $0:$1})
            self.history=history;holdings=snapshot.holdings;currency=snapshot.currency
            await refresh(database:db,token:token)
        } catch { if !Task.isCancelled { if generation==token {failure=true};OathDiagnostics.record(error,component:"permissions",operation:"load") } }
    }
    func refresh(session:OathWalletSession) async {
        guard scanning.isEmpty else { return }
        do { await refresh(database:try await session.vault.database(),token:generation) }
        catch { failure=true;OathDiagnostics.record(error,component:"permissions",operation:"refresh") }
    }
    private func refresh(database:OathDatabase,token:UUID) async {
        let pending=accounts;scanning=Set(pending.map(\.networkID))
        await withTaskGroup(of:(String,PermissionScan?).self) { group in
            var next=0
            func enqueue() { guard next<pending.count else { return };let a=pending[next];next+=1
                group.addTask {
                    do { return (a.networkID,try await OathPermissionService.shared.scan(account:a,database:database)) }
                    catch { if !Task.isCancelled { OathDiagnostics.record(error,component:"permissions",operation:"scan_network",context:["chain":a.networkID]) };return(a.networkID,nil) }
                }
            }
            for _ in 0..<min(3,pending.count) { enqueue() }
            for await (network,result) in group {
                guard generation==token,!Task.isCancelled else { group.cancelAll();return }
                scanning.remove(network)
                if let result { scans[network]=result }
                else if let previous=scans[network] { scans[network] = .init(network:network,owner:previous.owner,permissions:previous.permissions,coverage:.unavailable,checkedAt:previous.checkedAt) }
                else if let account=accounts.first(where:{$0.networkID==network}) { scans[network] = .init(network:network,owner:account.address,permissions:[],coverage:.unavailable) }
                enqueue()
            }
        }
        if generation==token { scanning=[] }
    }
    func reloadHistory(session:OathWalletSession) async {
        do { let result=try await session.vault.database().permissionHistory(walletID:walletID);if !Task.isCancelled { history=result } }
        catch { if !Task.isCancelled { OathDiagnostics.record(error,component:"permissions",operation:"history") } }
    }
}
