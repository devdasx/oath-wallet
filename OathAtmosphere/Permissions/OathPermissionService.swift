import Foundation
import OathAnkr
import OathDatabase
import OathDiagnostics

/// Uses the same chain-checked clients, vault authentication, resource reservation,
/// signed-byte journal and background status jobs as ordinary sends.
actor OathPermissionService {
    static let shared=OathPermissionService()
    private let identityRegistry = ContractIdentityClient()
    private var identityMisses = [String: Date]()

    func identity(network: String, address: String, asset: Bool) async throws -> ContractIdentity? {
        let address = try ContractIdentity.canonical(address, network: network)
        let key = network + ":" + address
        if let date = identityMisses[key], Date.now.timeIntervalSince(date) < 60 { return nil }
        return try await OathDiagnostics.$chain.withValue(network) {
            try await OathDiagnostics.$operationID.withValue(UUID()) {
                var value: ContractIdentity?
                if let chain = EVMSendNetwork(rawValue: network) {
                    if asset {
                        value = try await Self.read(operation: "identity_onchain", chain: network) {
                            try await OathEVMSendService.shared.connection(chain).permissionIdentity(address: address)
                        } ?? nil
                    }
                    if value == nil {
                        value = try await Self.read(operation: "identity_registry", chain: network) {
                            try await self.identityRegistry.verifiedContract(network: chain, address: address)
                        } ?? nil
                    }
                } else if asset, let chain = OathImportChain(rawValue: network), let tokenNetwork = OathTokenNetwork.find(chain) {
                    do {
                        let token = try await OathTokenService.shared.lookup(address: address, network: tokenNetwork)
                        value = try ContractIdentity(network: network, address: token.reference, name: token.name,
                            symbol: token.symbol, decimals: token.decimals, source: .onChain)
                    } catch {
                        if error is CancellationError || Task.isCancelled { throw CancellationError() }
                        // Optional names can be absent; unavailable providers are failures.
                        if ![OathTokenLookupError.notToken, .metadataUnavailable].contains(error as? OathTokenLookupError ?? .unavailable) {
                            OathDiagnostics.record(error, component: "permissions", operation: "identity_token", context: ["chain": network])
                        }
                    }
                }
                try Task.checkCancellation()
                if value == nil {
                    if identityMisses.count >= 2_000 { identityMisses.removeAll(keepingCapacity: true) }
                    identityMisses[key] = .now
                } else { identityMisses.removeValue(forKey: key) }
                return value
            }
        }
    }
    enum Quote:Sendable {
        case evm(OathEVMQuote),tron(OathTronQuote),solana(OathSolanaQuote)
        var fee:UInt64 { switch self { case .evm(let q):q.plan.fee;case .tron(let q):q.plan.fee;case .solana(let q):q.plan.fee } }
        var network:String { switch self { case .evm(let q):q.plan.network.rawValue;case .tron:"tron";case .solana:"solana" } }
        var decimals:Int { network=="tron" ? 6:network=="solana" ? 9:18 }
        func scope(sendID: String) throws -> PermissionBatchScope {
            switch self {
            case .evm(let q): try .evm(sendID:sendID,walletID:q.walletID,accountID:q.accountID,plan:q.plan)
            case .tron(let q): try .tron(sendID:sendID,walletID:q.walletID,accountID:q.accountID,plan:q.plan)
            case .solana(let q): try .solana(sendID:sendID,walletID:q.walletID,accountID:q.accountID,plan:q.plan)
            }
        }
    }
    private func configuration()->OathTokenRPCConfiguration { .bundled() }
    func scan(account:AccountRecord,database:OathDatabase) async throws -> PermissionScan {
        try await OathDiagnostics.$chain.withValue(account.networkID) {
            try await OathDiagnostics.$operationID.withValue(UUID()) {
                do {
                    let config=configuration()
                    var scan:PermissionScan
                    var controlUnavailable=false
                    if let network=EVMSendNetwork(rawValue:account.networkID) {
                        let client=try await OathEVMSendService.shared.connection(network)
                        async let indexed=Self.read(operation:"discover_evm",chain:network.rawValue) {try await config.makePermissionDiscovery().evm(network:network,owner:account.address,client:client)}
                        async let delegated=Self.read(operation:"read_delegation",chain:network.rawValue) {try await client.accountDelegation(owner:account.address)}
                        let (result,delegate)=try await(indexed,delegated)
                        let owner=try EVMSendIdentity.address(account.address)
                        var items=result?.permissions ?? []
                        if let delegate=delegate ?? nil {items.append(.init(network:network.rawValue,owner:owner,contract:owner,spender:delegate,kind:.delegation,amount:delegate))}
                        scan = .init(network:network.rawValue,owner:owner,permissions:items,coverage:result==nil ? .unavailable:delegate==nil ? .partial:result!.coverage)
                    } else if account.networkID=="solana" {
                        let source=try await database.solanaSigningAccount(accountID:account.id)
                        scan=try await config.makeSolanaSendClient().permissions(owner:source.address)
                    } else if account.networkID=="tron" {
                        let client=try config.makeTronSendClient()
                        async let indexed=Self.read(operation:"discover_tron",chain:"tron") {try await config.makePermissionDiscovery().tron(owner:account.address,client:client)}
                        async let accountControl=Self.read(operation:"read_control",chain:"tron") {try await client.accountPermissions(owner:account.address)}
                        let (result,control)=try await(indexed,accountControl)
                        controlUnavailable=control==nil
                        var keys=[WalletPermission]()
                        if let control {
                            for permission in (control["active_permission"].array ?? [])+[control["owner_permission"]] {
                                for key in permission["keys"].array ?? [] {
                                    if let rawAddress=key["address"].string {
                                        let address=try TronIdentity.address(rawAddress)
                                        guard address != account.address else {continue}
                                        keys.append(.init(network:"tron",owner:account.address,contract:account.address,spender:address,kind:.accountControl,amount:key["weight"].integer.map(String.init) ?? "0",tokenID:permission["id"].integer.map(String.init) ?? "0"))
                                    }
                                }
                            }
                        }
                        scan = .init(network:"tron",owner:account.address,permissions:(result?.permissions ?? [])+keys,coverage:result==nil ? .unavailable:control==nil ? .partial:result!.coverage)
                    } else { scan = .init(network:account.networkID,owner:account.address,permissions:[],coverage:.unsupported) }
                    // Cached/manual candidates are re-read even if the event index is partial
                    // or no longer lists a zero-balance token. A failed read stays unknown.
                    if let network=EVMSendNetwork(rawValue:account.networkID) {
                        let client=try await OathEVMSendService.shared.connection(network)
                        let prior=try await database.permissionScans(walletID:account.walletID).filter{$0.network==scan.network && $0.owner==scan.owner}.flatMap(\.permissions)
                        var merged=Dictionary(scan.permissions.map{($0.id,$0)},uniquingKeysWith:{a,_ in a}),coverage=scan.coverage
                        for (index,p) in prior.enumerated() where merged[p.id]==nil {
                            if index>=500 {merged[p.id]=p;coverage = .partial;continue}
                            try Task.checkCancellation()
                            guard let removal=p.evmRemoval else { continue }
                            do {
                                let value=try await client.permissionState(owner:scan.owner,removal:removal)
                                if Self.active(value,removal:removal) {
                                    merged[p.id] = .init(network:p.network,owner:p.owner,contract:p.contract,spender:p.spender,kind:p.kind,amount:value,tokenID:p.tokenID)
                                }
                            } catch {
                                if Task.isCancelled { throw CancellationError() }
                                OathDiagnostics.record(error,component:"permissions",operation:"refresh_candidate",context:["chain":account.networkID])
                                merged[p.id]=p;coverage = .partial
                            }
                        }
                        scan = .init(network:scan.network,owner:scan.owner,permissions:Array(merged.values),coverage:coverage)
                    }
                    if account.networkID=="tron" {
                        let prior=try await database.permissionScans(walletID:account.walletID).filter{$0.network==scan.network && $0.owner==scan.owner}.flatMap(\.permissions)
                        var merged=Dictionary(scan.permissions.map{($0.id,$0)},uniquingKeysWith:{a,_ in a}),coverage=scan.coverage
                        let client=try config.makeTronSendClient()
                        for (index,p) in prior.enumerated() where merged[p.id]==nil {
                            if index>=500 {merged[p.id]=p;coverage = .partial;continue}
                            try Task.checkCancellation()
                            if p.kind == .accountControl {if controlUnavailable {merged[p.id]=p};continue}
                            guard p.kind == .token else {continue}
                            if let amount=try await Self.read(operation:"refresh_candidate",chain:"tron",work:{try await client.permissionAllowance(owner:account.address,contract:p.contract,spender:p.spender)}) {
                                if amount != "0" {merged[p.id] = .init(network:p.network,owner:p.owner,contract:p.contract,spender:p.spender,kind:p.kind,amount:amount)}
                            } else {merged[p.id]=p;coverage = .partial}
                        }
                        scan = .init(network:scan.network,owner:scan.owner,permissions:Array(merged.values),coverage:coverage)
                    }
                    try Task.checkCancellation()
                    try await database.savePermissionScan(walletID:account.walletID,accountID:account.id,scan:scan)
                    return scan
                } catch { OathDiagnostics.record(error,component:"permissions",operation:"scan",context:["chain":account.networkID]);throw error }
            }
        }
    }
    private static func read<T:Sendable>(operation:String,chain:String,work:@Sendable () async throws -> T) async throws -> T? {
        do {return try await work()}
        catch {
            if error is CancellationError || Task.isCancelled {throw CancellationError()}
            OathDiagnostics.record(error,component:"permissions",operation:operation,context:["chain":chain]);return nil
        }
    }
    private static func active(_ amount:String,removal r:EVMPermissionRemoval)->Bool {
        switch r.kind {
        case .collectible,.delegation:return amount==r.spender
        case .permit2Nonce:
            let words=amount.split(separator:":")
            return words.count==3 && (UInt64(words[2]) ?? UInt64.max)<(1<<48)-1
        case .permit2:
            let words=amount.split(separator:":")
            return words.count==3 && words[0] != "0" && (UInt64(words[1]) ?? 0)>UInt64(Date.now.timeIntervalSince1970)
        default:return amount != "0"
        }
    }
    func checkContract(account:AccountRecord,contract:String,spender:String,kind:EVMPermissionRemoval.Kind,tokenID:String?) async throws -> WalletPermission {
        if let network=EVMSendNetwork(rawValue:account.networkID) {
            let client=try await OathEVMSendService.shared.connection(network),owner=try EVMSendIdentity.address(account.address)
            let contract=try EVMSendIdentity.address(contract),spender=try EVMSendIdentity.address(spender)
            let r=EVMPermissionRemoval(kind:kind,contract:contract,spender:spender,tokenID:tokenID,expected:"1")
            let amount=try await client.permissionState(owner:owner,removal:r)
            guard Self.active(amount,removal:r) else { throw PermissionError.alreadyRemoved }
            return .init(network:network.rawValue,owner:owner,contract:contract,spender:spender,kind:WalletPermission.Kind(rawValue:kind.rawValue) ?? .token,amount:amount,tokenID:tokenID)
        }
        if account.networkID=="tron",kind == .token {
            let value=try await configuration().makeTronSendClient().permissionAllowance(owner:account.address,contract:contract,spender:spender)
            guard value != "0" else { throw PermissionError.alreadyRemoved }
            return .init(network:"tron",owner:account.address,contract:contract,spender:spender,kind:.token,amount:value)
        }
        throw PermissionError.unsupported
    }
    func quote(_ permission:WalletPermission,account:AccountRecord,database:OathDatabase) async throws -> Quote {
        guard account.networkID==permission.network,let asset=try await database.asset(networkID:account.networkID,reference:"native") else { throw PermissionError.changed }
        if let network=EVMSendNetwork(rawValue:account.networkID),var removal=permission.evmRemoval {
            guard try EVMSendIdentity.address(account.address)==permission.owner else { throw PermissionError.changed }
            let client=try await OathEVMSendService.shared.connection(network)
            if removal.kind == .permit2Nonce {
                let current=try await client.permissionState(owner:permission.owner,removal:removal)
                removal = .init(kind:.permit2Nonce,contract:removal.contract,spender:removal.spender,tokenID:removal.tokenID,expected:current)
            }
            let plan=try await client.quote(sender:permission.owner,recipient:removal.contract,reference:"native",decimals:18,amount:"0",removal:removal)
            return .evm(.init(walletID:account.walletID,accountID:account.id,assetID:asset.id,plan:plan))
        }
        if account.networkID=="tron",[.token,.accountControl].contains(permission.kind) {
            guard account.address==permission.owner else { throw PermissionError.changed }
            let config=try configuration().makeTronSendClient()
            let control:TronPermissionControl?
            if permission.kind == .accountControl {
                guard let id=permission.tokenID.flatMap(UInt64.init) else {throw PermissionError.malformed}
                control=try await TronPermissionControl(configuration:config.accountPermissions(owner:permission.owner),permissionID:id,delegate:permission.spender)
            } else {control=nil}
            let removal=TronPermissionRemoval(contract:permission.contract,spender:permission.spender,expected:permission.amount,control:control)
            let plan=try await configuration().makeTronSendClient().quote(sender:permission.owner,recipient:permission.contract,reference:"native",decimals:6,amount:"0",removal:removal)
            return .tron(.init(walletID:account.walletID,accountID:account.id,assetID:asset.id,plan:plan))
        }
        if account.networkID=="solana",permission.kind == .delegate,let address=permission.tokenAccount,let program=permission.program,let amount=UInt64(permission.amount) {
            let source=try await database.solanaSigningAccount(accountID:account.id)
            guard source.address==permission.owner else { throw PermissionError.changed }
            let removal=SolanaPermissionRemoval(account:address,mint:permission.contract,program:program,delegate:permission.spender,amount:amount)
            let plan=try await configuration().makeSolanaSendClient().quoteRemoval(owner:source.address,removal:removal)
            return .solana(.init(walletID:account.walletID,accountID:account.id,assetID:asset.id,plan:plan))
        }
        throw PermissionError.unsupported
    }
    func submit(_ quote:Quote,vault:OathWalletVault,digits:[UInt8]?,reason:String, permissionSendID:String? = nil, authorization:UUID? = nil) async throws -> OathBitcoinSubmission {
        switch quote {
        case .evm(let q):try await OathEVMSendService.shared.submit(q,vault:vault,digits:digits,reason:reason,permissionSendID:permissionSendID,permissionAuthorization:authorization)
        case .tron(let q):try await OathTronSendService.shared.submit(q,vault:vault,digits:digits,reason:reason,permissionSendID:permissionSendID,permissionAuthorization:authorization)
        case .solana(let q):try await OathSolanaSendService.shared.submit(q,vault:vault,digits:digits,reason:reason,permissionSendID:permissionSendID,permissionAuthorization:authorization)
        }
    }
    func recheck(_ record:PermissionRemovalRecord,database:OathDatabase) async throws {
        guard let send=try await database.send(record.sendID),send.state=="confirmed",let id=send.transactionID,
              let transaction=try await database.transaction(id),let height=transaction.blockHeight,height>=0 else {throw PermissionError.unavailable}
        let removed:Bool
        switch try record.operation {
        case .evm(let r):
            guard let network=EVMSendNetwork(rawValue:record.networkID) else { throw PermissionError.malformed }
            removed=try await OathEVMSendService.shared.connection(network).permissionRemoved(owner:record.owner,removal:r,atBlock:UInt64(height))
        case .tron(let r):
            let client=try configuration().makeTronSendClient()
            if let control=r.control {removed=try await control.isRemoved(client.accountPermissions(owner:record.owner))}
            else {removed=try await client.permissionAllowance(owner:record.owner,contract:r.contract,spender:r.spender)=="0"}
        case .solana(let r):removed=try await configuration().makeSolanaSendClient().permissionRemoved(owner:record.owner,removal:r,minimumSlot:UInt64(height))
        }
        try await database.completePermissionRemoval(sendID:record.sendID,removed:removed)
    }
}
