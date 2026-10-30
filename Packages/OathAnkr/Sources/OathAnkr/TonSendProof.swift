import Foundation

/// Verify the message graph, not the indexer's high-level event description.
/// Sender acceptance alone cannot confirm a Jetton transfer or a bounced payment.
struct TonSendProof {
    let complete:Bool,success:Bool,fee:UInt64,hash:String,lt:Int64,timestamp:Double
    static func decode(_ trace:TonJSON,plan:TonSendPlan,bodyHash:String,messageHash:String,emulated:Bool) throws -> Self {
        let root=trace["transaction"]
        guard let incoming=try messages(root).incoming,TronSendCrypto.hex(incoming.hash)==messageHash else { throw TonSendError.changed }
        let rootMessage=try TonMessage(incoming)
        guard try address(root["account"])==plan.sender,rootMessage.source==nil,
              rootMessage.destination==plan.sender,try rootMessage.body.hash == TronIdentity.hex(bodyHash) else { throw TonSendError.changed }
        let hash=try TonIdentity.hash(root["hash"].string ?? ""),lt=try TonIdentity.lt(root["lt"]),timestamp=Double(try TonSendClient.uint(root["utime"]))
        guard timestamp>0 else { throw TonSendError.malformed }
        var nodes=[TonJSON](),seen=Set<String>(),fee:UInt64=0,complete=true
        func walk(_ t:TonJSON,_ depth:Int) throws {
            guard depth<=16,nodes.count<128,emulated || t["emulated"] != .bool(true) else { throw TonSendError.malformed }
            let tx=t["transaction"],id=try TonIdentity.hash(tx["hash"].string ?? "")
            guard seen.insert(id).inserted,let outgoing=tx["out_msgs"].array,outgoing.count<=64 else { throw TonSendError.malformed }
            let cost=try TonSendClient.uint(tx["total_fees"]),sum=fee.addingReportingOverflow(cost)
            guard !sum.overflow else { throw TonSendError.malformed };fee=sum.partialValue;nodes.append(tx)
            let children=t["children"].array ?? []
            let messagesCell=try Self.messages(tx)
            let internalCells=messagesCell.outgoing.filter { $0.bits.first==0 }
            let internalHashes=Set(internalCells.map { TronSendCrypto.hex($0.hash) })
            for cell in internalCells {
                var r=TonReader(cell);try r.skip(4);_ = try r.address();_ = try r.address();_ = try r.coins()
                guard try r.uint(1)==0 else { throw TonSendError.malformed }
                let ihr=try r.coins(),forward=try r.coins()
                for value in [ihr,forward] { let sum=fee.addingReportingOverflow(value);guard !sum.overflow else { throw TonSendError.malformed };fee=sum.partialValue }
            }
            guard children.count<=internalHashes.count else { throw TonSendError.malformed }
            var messages=Set<String>()
            for child in children {
                let incoming=child["transaction"]["in_msg"],h=try TonIdentity.hash(incoming["hash"].string ?? "")
                guard let rawIncoming=try Self.messages(child["transaction"]).incoming,
                      TronSendCrypto.hex(rawIncoming.hash)==h else { throw TonSendError.changed }
                let parsed=try TonMessage(rawIncoming)
                guard messages.insert(h).inserted,internalHashes.contains(h),
                      try parsed.destination==address(child["transaction"]["account"]),
                      try parsed.source==address(tx["account"]) else { throw TonSendError.changed }
                try walk(child,depth+1)
            }
            if children.count != internalHashes.count { complete=false }
        }
        try walk(trace,0)
        let rootOK=root["success"] == .bool(true) && root["aborted"] == .bool(false)
        var delivered=false,receiptTransaction=root
        if plan.reference=="native" {
            for tx in nodes.dropFirst() where try address(tx["account"])==plan.recipient {
                let incoming=try message(tx)
                guard incoming.source==plan.sender,!incoming.bounced,TonAmount(incoming.value)==plan.amount,
                      try incoming.body.hash==TonSendCrypto.transferBody(plan).hash else { continue }
                // An uninitialized ordinary account can receive a non-bounceable
                // payment without executing code. Its credit phase is the proof.
                let credited=tx["credit_phase"]["credit"].text.flatMap(UInt64.init)
                delivered=tx["success"] == .bool(true) || (!plan.bounce && credited.map { TonAmount($0) }==plan.amount && tx["out_msgs"].array?.isEmpty==true)
            }
        } else {
            let senderWallet=nodes.first { (try? address($0["account"]))==plan.jettonWallet }
            if let senderWallet,senderWallet["success"] == .bool(true),senderWallet["aborted"] == .bool(false),
               try message(senderWallet).source==plan.sender,
               try message(senderWallet).body.hash==TonSendCrypto.transferBody(plan).hash {
                for tx in nodes where (try? address(tx["account"]))==plan.recipientJettonWallet {
                    let msg=try message(tx)
                    guard tx["success"] == .bool(true),tx["aborted"] == .bool(false),!msg.bounced,
                          msg.source==plan.jettonWallet else { continue }
                    var slice=TonReader(msg.body)
                    guard try slice.uint(32)==0x178d4519,try slice.uint(64)==plan.queryID,
                          try slice.jettonCoins()==plan.amount,try slice.address()==plan.sender else { continue }
                    delivered=true;receiptTransaction=tx
                }
            }
        }
        // Jetton history identifies the recipient Jetton-wallet transaction,
        // not the initiating wallet transaction. Persist that same identity so
        // later history cannot duplicate the local transfer.
        if rootOK && delivered && plan.reference != "native" {
            return .init(complete:complete,success:true,fee:fee,hash:try TonIdentity.hash(receiptTransaction["hash"].string ?? ""),lt:try TonIdentity.lt(receiptTransaction["lt"]),timestamp:Double(try TonSendClient.uint(receiptTransaction["utime"])))
        }
        return .init(complete:complete,success:rootOK && delivered,fee:fee,hash:hash,lt:lt,timestamp:timestamp)
    }
    /// Trace endpoints intentionally omit out_msgs. Recover message identities
    /// from the hash-checked transaction BOC so a partial trace stays pending.
    static func messages(_ tx:TonJSON) throws -> (incoming:TonCell?,outgoing:[TonCell]) {
        guard let raw=tx["raw"].string else { throw TonSendError.malformed }
        let c=try TonCell.parse(TronIdentity.hex(raw))
        guard TronSendCrypto.hex(c.hash)==(try TonIdentity.hash(tx["hash"].string ?? "")),c.refs.count>=1 else { throw TonSendError.changed }
        var header=TonReader(c);guard try header.uint(4)==7 else { throw TonSendError.malformed }
        try header.skip(256+64+256+64+32);let count=Int(try header.uint(15))
        guard count<=64 else { throw TonSendError.malformed }
        var r=TonReader(c.refs[0]);let incoming=try r.uint(1)==1 ? r.ref():nil
        let has=try r.uint(1)==1;var out=[TonCell]()
        func dict(_ cell:TonCell,_ remaining:Int) throws {
            var s=TonReader(cell);let first=try s.uint(1);var label=0
            let width=remaining==0 ? 0:Int.bitWidth-remaining.leadingZeroBitCount
            if first==0 { while try s.uint(1)==1 { label+=1;guard label<=remaining else { throw TonSendError.malformed } };try s.skip(label) }
            else if try s.uint(1)==0 { label=Int(try s.uint(width));try s.skip(label) }
            else { _ = try s.uint(1);label=Int(try s.uint(width)) }
            guard label<=remaining else { throw TonSendError.malformed }
            if label==remaining { guard out.count<64 else { throw TonSendError.malformed };out.append(try s.ref()) }
            else { try dict(s.ref(),remaining-label-1);try dict(s.ref(),remaining-label-1) }
        }
        if has { try dict(r.ref(),15) }
        guard out.count==count else { throw TonSendError.malformed };return (incoming,out)
    }
    static func address(_ j:TonJSON) throws -> String { try TonIdentity.raw(j["address"].string ?? j.string ?? "") }
    static func message(_ tx:TonJSON) throws -> TonMessage {
        guard let cell=try messages(tx).incoming else { throw TonSendError.malformed };return try TonMessage(cell)
    }
}
struct TonReader {
    let cell:TonCell;var offset=0;var refOffset=0
    init(_ cell:TonCell) { self.cell=cell }
    mutating func uint(_ width:Int) throws -> UInt64 {
        guard (0...64).contains(width),offset+width<=cell.bits.count else { throw TonSendError.malformed }
        defer { offset+=width };return cell.bits[offset..<offset+width].reduce(0){($0<<1)|UInt64($1)}
    }
    mutating func skip(_ n:Int) throws { guard n>=0,offset+n<=cell.bits.count else { throw TonSendError.malformed };offset+=n }
    mutating func ref() throws -> TonCell { guard refOffset<cell.refs.count else { throw TonSendError.malformed };defer {refOffset+=1};return cell.refs[refOffset] }
    mutating func jettonCoins() throws -> TonAmount {
        let count=Int(try uint(4));var bytes=[UInt8]()
        for _ in 0..<count { bytes.append(UInt8(try uint(8))) };return TonAmount(bytes:bytes)
    }
    mutating func coins() throws -> UInt64 { let bytes=Int(try uint(4));guard bytes<=8 else { throw TonSendError.amount };return try uint(bytes*8) }
    mutating func address() throws -> String {
        guard try uint(3)==4 else { throw TonSendError.malformed };let wc=Int8(bitPattern:UInt8(try uint(8)))
        var data=Data();for _ in 0..<32 { data.append(UInt8(try uint(8))) };return String(wc)+":"+TronSendCrypto.hex(data)
    }
}

/// Decode bodies from the hash-checked message. Index APIs may flatten text
/// comments into raw bytes while returning BOCs for other bodies.
struct TonMessage {
    let source:String?,destination:String,value:UInt64,bounce:Bool,bounced:Bool,body:TonCell
    init(_ cell:TonCell) throws {
        var r=TonReader(cell)
        if try r.uint(1)==0 {
            try r.skip(1);bounce=try r.uint(1)==1;bounced=try r.uint(1)==1;source=try r.address();destination=try r.address();value=try r.coins()
            // No extra currencies are present in the messages this sender emits.
            if try r.uint(1)==1 { _ = try r.ref() }
            _ = try r.coins();_ = try r.coins();try r.skip(64+32)
        } else {
            guard try r.uint(1)==0,try r.uint(2)==0 else { throw TonSendError.malformed }
            source=nil;destination=try r.address();value=0;bounce=false;bounced=false;_ = try r.coins()
        }
        if try r.uint(1)==1 {
            if try r.uint(1)==1 { _ = try r.ref() }
            else {
                if try r.uint(1)==1 { try r.skip(5) }
                if try r.uint(1)==1 { try r.skip(2) }
                for _ in 0..<3 { if try r.uint(1)==1 { _ = try r.ref() } }
            }
        }
        if try r.uint(1)==1 { body=try r.ref() }
        else { body=try TonCell(Array(cell.bits.dropFirst(r.offset)),Array(cell.refs.dropFirst(r.refOffset))) }
    }
}
