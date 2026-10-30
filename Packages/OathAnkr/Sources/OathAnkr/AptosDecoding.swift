import Foundation

public enum AptosDecoding {
    /// Only framework movement events establish custody. A third-party event
    /// named Deposit/Withdraw must not be treated as a transfer by its suffix.
    private static func direction(_ type: String) throws -> String? {
        let type = String(try AptosIdentity.reference(type).prefix(while: { $0 != "<" }))
        switch type {
        case "0x1::coin::DepositEvent", "0x1::coin::Deposit", "0x1::coin::CoinDeposit",
             "0x1::fungible_asset::Deposit": return "incoming"
        case "0x1::coin::WithdrawEvent", "0x1::coin::Withdraw", "0x1::coin::CoinWithdraw",
             "0x1::fungible_asset::Withdraw": return "outgoing"
        default: return nil
        }
    }

    /// Public receipt parties, including peers omitted by older owner-filtered
    /// index pages. Read the already cached execution; opening details is offline.
    /// FA store IDs are objects, not recipients. Resolve them to the event-time
    /// owner supplied by the indexer, or unchanged ObjectCore ownership.
    public static func parties(_ transaction: AptosTransaction) throws -> (from: [String], to: [String]) {
        let raw = try JSONDecoder().decode(AptosJSON.self, from: transaction.raw)
        let receipt = raw["receipt"]
        guard let events = receipt["events"].array else { return ([], []) } // Older/local pending receipt.
        guard receipt["hash"].string?.lowercased() == transaction.hash.lowercased(),
              try AptosIdentity.number(receipt["version"]) == transaction.version else { throw AptosError.malformed }
        guard !transaction.failed else { return ([transaction.sender], []) }
        var indexedOwners: [Int: String] = [:]
        for activity in raw["index"]["fungible_asset_activities"].array ?? [] {
            if try AptosIdentity.bool(activity["is_gas_fee"]) { continue }
            guard let type = activity["type"].string, try direction(type) != nil else { continue }
            guard let index = activity["event_index"].text.flatMap(Int.init), events.indices.contains(index),
                  let address = activity["owner_address"].string,
                  events[index]["type"].string == type,
                  try AptosIdentity.amount(activity["amount"]) == AptosIdentity.amount(events[index]["data"]["amount"]) else { throw AptosError.malformed }
            let owner = try AptosIdentity.address(address)
            guard indexedOwners[index] == nil || indexedOwners[index] == owner else { throw AptosError.malformed }
            indexedOwners[index] = owner
        }
        // A resource write contains post-transaction ownership. It cannot tell
        // us the owner of an earlier withdrawal if the object was transferred.
        var movedStores = Set<String>()
        for event in events where ["0x1::object::TransferEvent", "0x1::object::Transfer"].contains(event["type"].string ?? "") {
            if let object = event["data"]["object"].string { movedStores.insert(try AptosIdentity.address(object)) }
        }
        var stores: [String: String] = [:]
        for change in receipt["changes"].array ?? [] where change["type"].string == "write_resource" && change["data"]["type"].string == "0x1::object::ObjectCore" {
            guard let address = change["address"].string, let owner = change["data"]["data"]["owner"].string else { throw AptosError.malformed }
            let store = try AptosIdentity.address(address)
            if !movedStores.contains(store) { stores[store] = try AptosIdentity.address(owner) }
        }
        var from = Set<String>(), to = Set<String>()
        for (index, event) in events.enumerated() {
            guard let rawType = event["type"].string, let direction = try direction(rawType),
                  try AptosIdentity.amount(event["data"]["amount"]) != "0" else { continue }
            let type = try AptosIdentity.reference(rawType)
            var owner = indexedOwners[index]
            if owner == nil {
                if type.hasPrefix("0x1::fungible_asset::"), let store = event["data"]["store"].string {
                    owner = stores[try AptosIdentity.address(store)]
                } else if type.hasPrefix("0x1::coin::") {
                    let address = event["data"]["account"].string ?? event["guid"]["account_address"].string
                    if let address, try AptosIdentity.address(address) != AptosIdentity.address("0x0") { owner = try AptosIdentity.address(address) }
                }
            }
            if let owner { if direction == "outgoing" { from.insert(owner) } else { to.insert(owner) } }
        }
        return (from.sorted(), to.sorted())
    }

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
            guard let address=event["owner_address"].string,
                  try AptosIdentity.bool(event["is_transaction_success"])==success,
                  let indexText=event["event_index"].text,let index=Int(indexText),seen.insert(index).inserted,
                  let type=event["type"].string else {throw AptosError.malformed}
            let eventOwner = try AptosIdentity.address(address)
            if try AptosIdentity.bool(event["is_gas_fee"]) {if eventOwner == owner {paidGas=true};continue}
            guard success else {continue}
            guard let direction = try direction(type) else {continue} // Non-movement events remain in raw.
            guard eventOwner == owner else {continue} // Cache peers without adding their holdings/history to this wallet.
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
