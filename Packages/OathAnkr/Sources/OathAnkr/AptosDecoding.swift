import Foundation

public enum AptosDecoding {
    /// Full node receipts provide hash, success and gas; the account index
    /// provides ownership for both legacy events and FA object store events.
    public static func transaction(row:AptosJSON,detail:AptosJSON,owner:String) throws -> AptosTransaction {
        let owner=try AptosIdentity.address(owner),version=try AptosIdentity.number(row["transaction_version"])
        guard let account=row["account_address"].string,try AptosIdentity.address(account)==owner,
              try AptosIdentity.number(detail["version"])==version,
              detail["type"].string=="user_transaction",let hash=detail["hash"].string,hash.count==66,
              let sender=detail["sender"].string,let activities=row["fungible_asset_activities"].array else {throw AptosError.malformed}
        _ = try AptosIdentity.address(hash)
        let success=try AptosIdentity.bool(detail["success"])
        let timestamp=Double(try AptosIdentity.amount(detail["timestamp"]))! / 1_000_000
        let gas=try AptosIdentity.amount(detail["gas_used"]),unit=try AptosIdentity.amount(detail["gas_unit_price"])
        // Both are u64. Decimal represents their product exactly for current
        // protocol bounds; string multiplication avoids any precision limit.
        var fee="0",place=""
        for digit in unit.reversed() {var n="0";for _ in 0..<Int(String(digit))! {n=AptosIdentity.add(n,gas)};fee=AptosIdentity.add(fee,n+place);place+="0"}
        fee=try AptosIdentity.amount(.string(fee))
        var events:[AptosMovement]=[],seen:Set<Int>=[],paidGas=false
        for event in activities {
            guard let address=event["owner_address"].string,try AptosIdentity.address(address)==owner,
                  try AptosIdentity.bool(event["is_transaction_success"])==success,
                  let indexText=event["event_index"].text,let index=Int(indexText),seen.insert(index).inserted,
                  let type=event["type"].string else {throw AptosError.malformed}
            if try AptosIdentity.bool(event["is_gas_fee"]) {paidGas=true;continue}
            guard success else {continue}
            let direction:String
            // Coin module events can carry <CoinType>; old event handles and
            // the FA standard use non-generic names.
            let eventType=String(type.prefix(while:{$0 != "<"}))
            if eventType.hasSuffix("::Deposit") || eventType.hasSuffix("::DepositEvent") {direction="incoming"}
            else if eventType.hasSuffix("::Withdraw") || eventType.hasSuffix("::WithdrawEvent") {direction="outgoing"}
            else {continue} // freeze events do not move money; retained in raw.
            guard let raw=event["asset_type"].string else {throw AptosError.malformed}
            let ref=try AptosIdentity.reference(raw),token=try AptosToken.decode(event["metadata"],reference:ref)
            let amount=try AptosIdentity.amount(event["amount"])
            guard let receiptEvents=detail["events"].array,index>=0,index<receiptEvents.count,
                  receiptEvents[index]["type"].string==type,
                  try AptosIdentity.amount(receiptEvents[index]["data"]["amount"])==amount else {throw AptosError.malformed}
            events.append(.init(index:index,token:token,owner:owner,direction:direction,amount:amount))
        }
        let senderAddress=try AptosIdentity.address(sender)
        if senderAddress==owner || paidGas,!events.contains(where:{$0.token.reference=="native"}) {
            events.append(.init(index:-1,token:.native,owner:owner,direction:"self",amount:"0"))
        }
        return .init(hash:hash.lowercased(),version:version,timestamp:timestamp,failed:!success,fee:fee,sender:senderAddress,events:events,raw:try JSONEncoder().encode(AptosJSON.object(["index":row,"receipt":detail])))
    }
}
