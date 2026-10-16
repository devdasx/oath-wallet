import Foundation
import OathDiagnostics

/// Indexers discover candidates only. Every active permission is read again from
/// the chain; an event or explorer label alone never authorizes a removal.
public struct PermissionDiscovery: Sendable {
    private let ankr:URL
    private let transport:any AnkrTransport
    public init(apiKey:String,transport:any AnkrTransport = AnkrHTTPTransport()) throws {
        guard !apiKey.isEmpty,apiKey.count<=256,apiKey.utf8.allSatisfy({(48...57).contains($0)||(65...90).contains($0)||(97...122).contains($0)}) else { throw AnkrError.configurationMissing }
        ankr=URL(string:"https://rpc.ankr.com/multichain")!.appendingPathComponent(apiKey);self.transport=transport
    }
    static func topic(_ signature:String)->String { "0x"+TronSendCrypto.hex(TronSendCrypto.keccak(Data(signature.utf8))) }
    static let approval=topic("Approval(address,address,uint256)")
    static let all=topic("ApprovalForAll(address,address,bool)")
    static let permitApproval=topic("Approval(address,address,address,uint160,uint48)")
    static let permit=topic("Permit(address,address,address,uint160,uint48,uint48)")
    private func json(_ request:URLRequest) async throws -> SolanaJSON {
        let (data,status)=try await transport.send(request)
        DiagnosticHTTP.response(data,status:status,request:request)
        guard status==200 else { throw AnkrError.http(status) }
        guard data.count<=8_388_608 else { throw AnkrError.responseTooLarge }
        return try JSONDecoder().decode(SolanaJSON.self,from:data)
    }
    public func evm(network:EVMSendNetwork,owner:String,client:EVMSendClient) async throws -> PermissionScan {
        let owner=try EVMSendIdentity.address(owner)
        guard client.network==network else { throw PermissionError.changed }
        guard let alias=AnkrChain(networkID:network.rawValue)?.rawValue else {
            return .init(network:network.rawValue,owner:owner,permissions:[],coverage:.unsupported)
        }
        var candidates=[String:WalletPermission](),cursor:String?,seen=Set<String>(),complete=false
        for _ in 0..<20 {
            try Task.checkCancellation()
            var params:[String:SolanaJSON] = ["blockchain":.array([.string(alias)]),"fromBlock":.string("earliest"),"toBlock":.string("latest"),
                "topics":.array([.array([Self.approval,Self.all,Self.permitApproval,Self.permit].map(SolanaJSON.string)),.array([.string("0x"+TronSendCrypto.hex(try EVMPermissionRemoval.word(owner)))])]),"pageSize":.number("500")]
            if let cursor { params["pageToken"] = .string(cursor) }
            var request=URLRequest(url:ankr);request.httpMethod="POST";request.timeoutInterval=15
            request.setValue("application/json",forHTTPHeaderField:"Content-Type")
            request.httpBody=try JSONEncoder().encode(SolanaJSON.object(["jsonrpc":.string("2.0"),"id":.number("1"),"method":.string("ankr_getLogs"),"params":.object(params)]))
            do {
                let j=try await json(request)
                guard j["id"].integer==1,j["jsonrpc"].string=="2.0",j["error"].isNull else {
                    if case .number(let code)=j["error"]["code"],let n=Int(code) { throw AnkrError.rpc(n) };throw AnkrError.invalidResponse
                }
                let result=j["result"]
                guard let logs=result["logs"].array,logs.count<=500 else { throw PermissionError.malformed }
                for log in logs {
                    guard log["blockchain"].string==alias else { throw AnkrError.wrongChain }
                    if log["removed"] == .bool(true) { continue }
                    if let p=try Self.candidate(log,network:network.rawValue,owner:owner) { candidates[p.id]=p }
                }
                if candidates.count>=500 {complete=false;break}
                cursor=result["nextPageToken"].string
                if cursor==nil || cursor=="" {
                    complete=result["syncStatus"]["status"].string=="synced" && result["syncStatus"]["timestamp"].integer.map{abs(Double($0)-Date.now.timeIntervalSince1970)<120}==true;break
                }
                guard let cursor,cursor.utf8.count<=8192,seen.insert(cursor).inserted else { throw AnkrError.paginationLoop }
            } catch {
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                OathDiagnostics.record(error,component:"permissions",operation:"discover_evm",context:["chain":network.rawValue]);complete=false
                if candidates.isEmpty { throw error };break
            }
        }
        var active=[WalletPermission]()
        let values=Array(candidates.values)
        for start in stride(from:0,to:values.count,by:4) {
            let results=await withTaskGroup(of:(WalletPermission?,Bool).self) { group in
                for p in values[start..<min(start+4,values.count)] {
                    group.addTask {
                        do {
                            guard let r=p.evmRemoval else { throw PermissionError.malformed }
                            let current=try await client.permissionState(owner:owner,removal:r)
                            let enabled:Bool
                            switch p.kind {
                            case .collectible: enabled=current==p.spender
                            case .permit2: enabled=current.split(separator:":").first != "0" && (UInt64(current.split(separator:":").dropFirst().first ?? "") ?? 0)>UInt64(Date.now.timeIntervalSince1970)
                            default:enabled=current != "0"
                            }
                            return (enabled ? .init(network:p.network,owner:owner,contract:p.contract,spender:p.spender,kind:p.kind,amount:current,tokenID:p.tokenID):nil,true)
                        } catch {
                            OathDiagnostics.record(error,component:"permissions",operation:"read_allowance",context:["chain":network.rawValue]);return(nil,false)
                        }
                    }
                }
                var result=[(WalletPermission?,Bool)]();for await r in group { result.append(r) };return result
            }
            for (p,ok) in results { if let p { active.append(p) };if !ok { complete=false } }
        }
        try Task.checkCancellation()
        return .init(network:network.rawValue,owner:owner,permissions:active.sorted{$0.id<$1.id},coverage:complete ? .checked:.partial)
    }
    static func candidate(_ log:SolanaJSON,network:String,owner:String) throws -> WalletPermission? {
        guard let topics=log["topics"].array,topics.count>=3,let signature=topics[0].string,
              topics[1].string?.lowercased()=="0x"+TronSendCrypto.hex(try EVMPermissionRemoval.word(owner)),
              let raw=log["address"].string else { throw PermissionError.malformed }
        let contract=try EVMSendIdentity.address(raw)
        func address(_ i:Int) throws -> String {
            guard topics.count>i,let raw=topics[i].string else { throw PermissionError.malformed }
            let bytes=try TronIdentity.hex(raw);guard bytes.count==32,bytes.prefix(12).allSatisfy({$0==0}) else { throw PermissionError.malformed }
            return "0x"+TronSendCrypto.hex(bytes.suffix(20))
        }
        if signature==Self.approval {
            let spender=try address(2);if spender==EVMPermissionRemoval.zero { return nil }
            guard topics.count==3 || topics.count==4 else { throw PermissionError.malformed }
            if topics.count==4 {guard let word=topics[3].string,try TronIdentity.hex(word).count==32 else {throw PermissionError.malformed}}
            let id=try topics.count==4 ? AnkrQuantity.decimal(topics[3].string ?? ""):nil
            return .init(network:network,owner:owner,contract:contract,spender:spender,kind:id==nil ? .token:.collectible,amount:id==nil ? "1":spender,tokenID:id)
        }
        if signature==Self.all { return try .init(network:network,owner:owner,contract:contract,spender:address(2),kind:.collection,amount:"1") }
        if [Self.permitApproval,Self.permit].contains(signature),contract==EVMPermissionRemoval.permit2 {
            return try .init(network:network,owner:owner,contract:contract,spender:address(3),kind:.permit2,amount:"1:0:0",tokenID:address(2))
        }
        return nil
    }
    public func tron(owner:String,client:TronSendClient) async throws -> PermissionScan {
        guard TronIdentity.isAddress(owner),client.network == .mainnet else { throw PermissionError.malformed }
        var values=[String:WalletPermission](),complete=false
        for start in stride(from:0,to:1000,by:50) {
            var url=URLComponents(string:"https://apilist.tronscanapi.com/api/account/approve/list")!
            url.queryItems=[.init(name:"address",value:owner),.init(name:"limit",value:"50"),.init(name:"start",value:String(start)),.init(name:"type",value:"project")]
            var request=URLRequest(url:url.url!);request.timeoutInterval=15
            let j=try await json(request)
            guard let rows=j["data"].array,rows.count<=50,let total=j["total"].integer else { throw PermissionError.malformed }
            for row in rows {
                guard row["from_address"].string==owner,let contract=row["contract_address"].string,let spender=row["to_address"].string,
                      TronIdentity.isAddress(contract),TronIdentity.isAddress(spender) else { throw PermissionError.malformed }
                guard row["tokenInfo"]["tokenType"].string=="trc20" else { continue }
                let amount=try await client.permissionAllowance(owner:owner,contract:contract,spender:spender)
                if amount != "0" { let p=WalletPermission(network:"tron",owner:owner,contract:contract,spender:spender,kind:.token,amount:amount);values[p.id]=p }
            }
            if UInt64(start+rows.count)>=total { complete=true;break }
            guard !rows.isEmpty else { throw PermissionError.incomplete }
        }
        return .init(network:"tron",owner:owner,permissions:Array(values.values).sorted{$0.id<$1.id},coverage:complete ? .checked:.partial)
    }
}
