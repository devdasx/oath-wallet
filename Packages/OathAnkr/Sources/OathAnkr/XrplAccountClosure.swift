import Foundation

/// Conservative reserve-only closure. Existing objects must be removed through
/// their own explicit flows; Max never silently deletes orders or permissions.
enum XrplAccountClosure {
    static func validate(root: XrplJSON, ledger: UInt32, reserve: UInt64, fee: UInt64) throws {
        guard root["Balance"].text == "1000000", reserve == 1_000_000,
              fee > 0, fee <= 500_000 else { throw XrplSendError.closureUnavailable }
        func counter(_ field: String, optional: Bool = true) throws -> UInt64 {
            if optional && root[field].isNull { return 0 }
            guard let value = root[field].integer, value <= UInt64(UInt32.max) else { throw XrplSendError.malformed }
            return value
        }
        let sequence = try counter("Sequence",optional:false)
        guard sequence > 0, sequence+256 < UInt64(ledger),
              try counter("FirstNFTokenSequence") + counter("MintedNFTokens") + 256 < UInt64(ledger)
        else { throw XrplSendError.closureTooSoon }
        guard try counter("OwnerCount",optional:false) == 0,
              try counter("MintedNFTokens") == counter("BurnedNFTokens"),
              root["Sponsor"].isNull, root["SponsoringOwnerCount"].isNull,
              root["SponsoringAccountCount"].isNull else { throw XrplSendError.closureObligations }
        guard try counter("Flags",optional:false) & 0x100000 == 0 else { throw XrplSendError.unsupportedAccount }
    }

    /// Prove both deletion and the destination's exact credit. AccountDelete has
    /// no Amount field: incoming XRP before execution is included in this credit.
    static func delivered(_ meta: XrplJSON, plan: XrplSendPlan) throws -> String {
        guard meta["TransactionResult"].string == "tesSUCCESS",
              let nodes = meta["AffectedNodes"].array else { throw XrplSendError.changed }
        let sources = nodes.map { $0["DeletedNode"] }.filter {
            $0["LedgerEntryType"].string == "AccountRoot" && $0["FinalFields"]["Account"].string == plan.sender
        }
        let destinations = nodes.map { $0["ModifiedNode"] }.filter {
            $0["LedgerEntryType"].string == "AccountRoot" && $0["FinalFields"]["Account"].string == plan.recipient
        }
        guard sources.count == 1, destinations.count == 1,
              sources[0]["FinalFields"]["Balance"].text == "0",
              let before = sources[0]["PreviousFields"]["Balance"].text.flatMap(UInt64.init),
              before > plan.fee, before <= 100_000_000_000_000_000,
              let old = destinations[0]["PreviousFields"]["Balance"].text.flatMap(UInt64.init),
              let new = destinations[0]["FinalFields"]["Balance"].text.flatMap(UInt64.init),
              new > old, new-old == before-plan.fee else { throw XrplSendError.changed }
        return String(new-old)
    }
}
