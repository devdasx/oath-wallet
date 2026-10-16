import Foundation

public enum PermissionError: Error, Sendable, Equatable {
    case malformed, unsupported, changed, alreadyRemoved, incomplete, unavailable
}

/// Removal-only instructions. Never accept arbitrary calldata from an indexer or dApp.
public struct EVMPermissionRemoval: Codable, Sendable, Equatable, Hashable {
    public enum Kind: String, Codable, Sendable, CaseIterable { case token, collectible, collection, permit2, permit2Nonce, delegation }
    public let kind:Kind, contract:String, spender:String, tokenID:String?, expected:String
    public static let permit2="0x000000000022d473030f116ddee9f6b43ac78ba3"
    public init(kind:Kind,contract:String,spender:String,tokenID:String?=nil,expected:String) {
        self.kind=kind;self.contract=contract;self.spender=spender;self.tokenID=tokenID;self.expected=expected
    }
    public func validate() throws {
        guard try EVMSendIdentity.address(contract)==contract,try EVMSendIdentity.address(spender)==spender,
              contract != Self.zero,spender != Self.zero,!expected.isEmpty,expected.count<=256 else { throw PermissionError.malformed }
        switch kind {
        case .delegation: guard tokenID==nil,expected==spender else {throw PermissionError.changed}
        case .token: guard tokenID==nil,try EVMSendAmount.checked(expected) != "0" else { throw PermissionError.alreadyRemoved }
        case .collection: guard tokenID==nil,expected=="1" else { throw PermissionError.alreadyRemoved }
        case .collectible:
            guard let tokenID,try EVMSendAmount.checked(tokenID)==tokenID,expected==spender else { throw PermissionError.changed }
        case .permit2,.permit2Nonce:
            guard contract==Self.permit2,let tokenID,try EVMSendIdentity.address(tokenID)==tokenID else { throw PermissionError.malformed }
            let words=expected.split(separator:":");guard words.count==3,let amount=words.first,try EVMSendAmount.checked(String(amount))==String(amount),
                  !EVMSendAmount.less("1461501637330902918203684832716283019655932542975",String(amount)),
                  let expiry=UInt64(words[1]),expiry<(1<<48),let nonce=UInt64(words[2]),nonce<(1<<48), (kind != .permit2Nonce || nonce<(1<<48)-1) else { throw PermissionError.malformed }
        }
    }
    public static let zero="0x"+String(repeating:"0",count:40)
    static func word(_ address:String) throws -> Data { Data(repeating:0,count:12)+(try TronIdentity.hex(EVMSendIdentity.address(address))) }
    static func selector(_ signature:String)->Data { Data(TronSendCrypto.keccak(Data(signature.utf8)).prefix(4)) }
    public func calldata() throws -> Data {
        try validate()
        switch kind {
        case .delegation: return Data()
        case .token: return try Self.selector("approve(address,uint256)")+Self.word(spender)+TronSendCrypto.uint256("0")
        case .collectible: return try Self.selector("approve(address,uint256)")+Self.word(Self.zero)+TronSendCrypto.uint256(tokenID!)
        case .collection: return try Self.selector("setApprovalForAll(address,bool)")+Self.word(spender)+TronSendCrypto.uint256("0")
        case .permit2: // Revokes the current on-chain allowance only. Nonce invalidation is a separately reviewed transaction.
            return try Self.selector("lockdown((address,address)[])")+TronSendCrypto.uint256("32")+TronSendCrypto.uint256("1")+Self.word(tokenID!)+Self.word(spender)
        case .permit2Nonce:
            let nonce=UInt64(expected.split(separator:":")[2])!
            return try Self.selector("invalidateNonces(address,address,uint48)")+Self.word(tokenID!)+Self.word(spender)+TronSendCrypto.uint256(String(nonce+1))
        }
    }
}

public struct SolanaPermissionRemoval: Codable, Sendable, Equatable {
    public let account:String,mint:String,program:String,delegate:String,amount:UInt64
    public init(account:String,mint:String,program:String,delegate:String,amount:UInt64) { self.account=account;self.mint=mint;self.program=program;self.delegate=delegate;self.amount=amount }
    public func validate() throws {
        guard [account,mint,delegate].allSatisfy(SolanaIdentity.isAddress),[SolanaIdentity.tokenProgram,SolanaIdentity.token2022Program].contains(program) else { throw PermissionError.malformed }
    }
}
public struct TronPermissionRemoval: Codable, Sendable, Equatable {
    public let contract:String,spender:String,expected:String
    public let control:TronPermissionControl?
    public init(contract:String,spender:String,expected:String,control:TronPermissionControl?=nil) { self.contract=contract;self.spender=spender;self.expected=expected;self.control=control }
    public func validate() throws {
        guard TronIdentity.isAddress(contract),TronIdentity.isAddress(spender),try EVMSendAmount.checked(expected) != "0" else { throw PermissionError.malformed }
        if let control { guard control.delegate==spender else {throw PermissionError.changed};try control.validate(signer:contract) }
    }
    func calldata() throws -> Data { try validate();guard control==nil else {throw PermissionError.unsupported};return try EVMPermissionRemoval.selector("approve(address,uint256)")+Data(repeating:0,count:12)+TronIdentity.bytes(spender).dropFirst()+TronSendCrypto.uint256("0") }
}

public struct WalletPermission: Codable, Sendable, Equatable, Identifiable {
    public enum Kind:String,Codable,Sendable { case token,collectible,collection,permit2,permit2Nonce,delegate,permanentDelegate,accountControl,delegation }
    public let network:String,owner:String,contract:String,spender:String,kind:Kind,amount:String,tokenID:String?,program:String?,tokenAccount:String?
    public var id:String { [network,owner,kind.rawValue,contract,spender,tokenID ?? "",tokenAccount ?? ""].joined(separator:"|") }
    public init(network:String,owner:String,contract:String,spender:String,kind:Kind,amount:String,tokenID:String?=nil,program:String?=nil,tokenAccount:String?=nil) {
        self.network=network;self.owner=owner;self.contract=contract;self.spender=spender;self.kind=kind;self.amount=amount;self.tokenID=tokenID;self.program=program;self.tokenAccount=tokenAccount
    }
    public var evmRemoval:EVMPermissionRemoval? {
        guard let k=EVMPermissionRemoval.Kind(rawValue:kind.rawValue) else { return nil }
        return .init(kind:k,contract:contract,spender:spender,tokenID:tokenID,expected:amount)
    }
}
public struct PermissionScan: Codable, Sendable, Equatable {
    public enum Coverage:String,Codable,Sendable { case checked,partial,unavailable,unsupported }
    public let network:String,owner:String,permissions:[WalletPermission],coverage:Coverage,checkedAt:Date
    public init(network:String,owner:String,permissions:[WalletPermission],coverage:Coverage,checkedAt:Date = .now) {
        self.network=network;self.owner=owner;self.permissions=permissions;self.coverage=coverage;self.checkedAt=checkedAt
    }
}

public enum PermissionRevocation: Codable,Sendable,Equatable {
    case evm(EVMPermissionRemoval),tron(TronPermissionRemoval),solana(SolanaPermissionRemoval)
}
