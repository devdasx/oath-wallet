import Foundation

/// Full configuration is preserved. The only permitted edit removes one external
/// key, and only when the local owner's key still independently meets its threshold.
public struct TronPermissionControl:Codable,Sendable,Equatable {
    public struct Key:Codable,Sendable,Equatable { public let address:String,weight:UInt64 }
    public struct Permission:Codable,Sendable,Equatable {
        public let type:UInt64,id:UInt64,name:String,threshold:UInt64,operations:String,keys:[Key]
        func validate() throws {
            guard type<=2,id<=9,threshold>0,threshold<=UInt64(Int64.max),name.utf8.count<=32,!keys.isEmpty,keys.count<=5,
                  Set(keys.map(\.address)).count==keys.count,keys.allSatisfy({TronIdentity.isAddress($0.address) && $0.weight>0 && $0.weight<=UInt64(Int64.max)}) else {throw PermissionError.malformed}
            let total=try keys.reduce(UInt64(0)){partial,key in let value=partial.addingReportingOverflow(key.weight);guard !value.overflow,value.partialValue<=UInt64(Int64.max) else {throw PermissionError.malformed};return value.partialValue}
            guard total>=threshold, (type==2 ? (try TronIdentity.hex(operations).count==32):operations.isEmpty) else {throw PermissionError.malformed}
        }
        func bytes() throws -> Data {
            try validate()
            var result=TronSendCrypto.number(1,type)+TronSendCrypto.number(2,id)+TronSendCrypto.field(3,Data(name.utf8))+TronSendCrypto.number(4,threshold)
            if !operations.isEmpty {result+=TronSendCrypto.field(6,try TronIdentity.hex(operations))}
            for key in keys {result+=TronSendCrypto.field(7,TronSendCrypto.field(1,try TronIdentity.bytes(key.address))+TronSendCrypto.number(2,key.weight))}
            return result
        }
        static func decode(_ j:TronJSON,type:UInt64,id:UInt64) throws -> Self {
            guard j["type"].isNull || j["type"].integer != nil || ["Owner","Active","Witness"].contains(j["type"].string ?? ""),
                  let name=j["permission_name"].string,let threshold=j["threshold"].integer,let keys=j["keys"].array,
                  (j["type"].integer ?? (j["type"].string=="Active" ? 2:j["type"].string=="Witness" ? 1:0))==type,(j["id"].integer ?? 0)==id,(j["parent_id"].integer ?? 0)==0 else {throw PermissionError.malformed}
            let result=try Self(type:type,id:id,name:name,threshold:threshold,operations:j["operations"].string ?? "",keys:keys.map{key in guard let a=key["address"].string,let w=key["weight"].integer else {throw PermissionError.malformed};return .init(address:try TronIdentity.address(a),weight:w)})
            try result.validate();return result
        }
        func removing(_ address:String)->Self { .init(type:type,id:id,name:name,threshold:threshold,operations:operations,keys:keys.filter{$0.address != address}) }
    }
    public let owner:Permission,witness:Permission?,actives:[Permission],permissionID:UInt64,delegate:String
    public init(configuration:TronJSON,permissionID:UInt64,delegate:String) throws {
        owner=try Permission.decode(configuration["owner_permission"],type:0,id:0)
        witness=configuration["witness_permission"].isNull ? nil:try Permission.decode(configuration["witness_permission"],type:1,id:1)
        guard let values=configuration["active_permission"].array,values.count<=8 else {throw PermissionError.malformed}
        actives=try values.enumerated().map{try Permission.decode($0.element,type:2,id:UInt64($0.offset+2))}
        self.permissionID=permissionID;self.delegate=try TronIdentity.address(delegate)
    }
    public func validate(signer:String) throws {
        try owner.validate();try witness?.validate();for p in actives {try p.validate()}
        guard owner.type==0,owner.id==0,!actives.isEmpty,actives.count<=8,
              witness==nil || (witness!.type==1 && witness!.id==1 && witness!.keys.count==1),
              actives.enumerated().allSatisfy({$0.element.type==2 && $0.element.id==UInt64($0.offset+2)}),
              owner.keys.first(where:{$0.address==signer}).map({$0.weight>=owner.threshold})==true,
              delegate != signer,permissionID==0 || (2...9).contains(permissionID),
              let target=([owner]+actives).first(where:{$0.id==permissionID}),target.keys.contains(where:{$0.address==delegate}) else {throw TronSendError.unsupportedAccount}
        // Removing a key must not make any threshold unreachable. We never lower
        // thresholds, replace owners, change operations, or drop a permission.
        try target.removing(delegate).validate()
    }
    func contract(signer:String) throws -> Data {
        try validate(signer:signer)
        let owner=permissionID==0 ? owner.removing(delegate):owner
        var result=TronSendCrypto.field(1,try TronIdentity.bytes(signer))+TronSendCrypto.field(2,try owner.bytes())
        if let witness {result+=TronSendCrypto.field(3,try witness.bytes())}
        for p in actives {result+=TronSendCrypto.field(4,try (p.id==permissionID ? p.removing(delegate):p).bytes())}
        return result
    }
    public func matches(_ configuration:TronJSON) throws -> Bool { try Self(configuration:configuration,permissionID:permissionID,delegate:delegate)==self }
    public func isRemoved(_ configuration:TronJSON) throws -> Bool {
        let current=try Self(configuration:configuration,permissionID:permissionID,delegate:delegate)
        return !([current.owner]+current.actives).contains{$0.id==permissionID && $0.keys.contains{$0.address==delegate}}
    }
}
