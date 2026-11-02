import Foundation
import GRDB

/// OR within a category, AND between categories. Empty selections mean all.
/// The screen's wallet/account/asset scope is always applied independently.
public struct HistoryFilter: Hashable, Sendable {
    public enum Direction: String, CaseIterable, Sendable { case incoming, outgoing, `self`, swap }
    public enum Status: String, CaseIterable, Sendable { case confirmed, pending, failed, canceled, replaced, reorged }
    public var networkIDs: Set<String> = []
    public var assetIDs: Set<String> = []
    public var directions: Set<Direction> = []
    public var statuses: Set<Status> = []
    public var startDate: Date?
    /// Exclusive upper bound; the UI supplies the start of the following day.
    public var endDate: Date?
    /// Nonnegative decimal quantities in asset units, compared without Double.
    public var minimumAmount: String?
    public var maximumAmount: String?

    public init() {}

    public var isValid: Bool {
        if let startDate, !startDate.timeIntervalSince1970.isFinite { return false }
        if let endDate, !endDate.timeIntervalSince1970.isFinite { return false }
        if let startDate, let endDate, startDate >= endDate { return false }
        if let minimumAmount, Self.canonicalAmount(minimumAmount) == nil { return false }
        if let maximumAmount, Self.canonicalAmount(maximumAmount) == nil { return false }
        if let minimumAmount, let maximumAmount,
           Self.compareAmounts(minimumAmount, maximumAmount) == .orderedDescending { return false }
        return true
    }

    public static func canonicalAmount(_ text: String, locale: Locale = Locale(identifier: "en_US_POSIX")) -> String? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 512 else { return nil }
        var ascii = ""
        for character in text {
            if let digit = character.wholeNumberValue, character.isNumber, (0...9).contains(digit) {
                ascii += String(digit)
            } else if String(character) == locale.decimalSeparator || character == "." || character == "٫" {
                ascii += "."
            } else { return nil }
        }
        let parts = ascii.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count <= 2, ascii.contains(where: \.isNumber) else { return nil }
        let integer = String(parts[0].drop(while: { $0 == "0" }))
        let fraction = parts.count == 2 ? String(parts[1].reversed().drop(while: { $0 == "0" }).reversed()) : ""
        return (integer.isEmpty ? "0" : integer) + (fraction.isEmpty ? "" : "." + fraction)
    }

    static func compareAmounts(_ lhs: String, _ rhs: String) -> ComparisonResult? {
        guard let lhs = canonicalAmount(lhs), let rhs = canonicalAmount(rhs) else { return nil }
        let a = lhs.split(separator: "."), b = rhs.split(separator: ".")
        if a[0].count != b[0].count { return a[0].count < b[0].count ? .orderedAscending : .orderedDescending }
        if a[0] != b[0] { return a[0] < b[0] ? .orderedAscending : .orderedDescending }
        let af = a.count > 1 ? String(a[1]) : "", bf = b.count > 1 ? String(b[1]) : ""
        let length = max(af.count, bf.count)
        let ap = af.padding(toLength: length, withPad: "0", startingAt: 0)
        let bp = bf.padding(toLength: length, withPad: "0", startingAt: 0)
        return ap == bp ? .orderedSame : ap < bp ? .orderedAscending : .orderedDescending
    }

    static let amountFunction = DatabaseFunction("oath_history_amount_in_range", argumentCount: 4, pure: true) { values in
        guard let atomic = String.fromDatabaseValue(values[0]), let decimals = Int.fromDatabaseValue(values[1]),
              let units = try? AtomicAmount(atomic).units(decimals: decimals) else { return false }
        if let minimum = String.fromDatabaseValue(values[2]) {
            guard let order = compareAmounts(units, minimum), order != .orderedAscending else { return false }
        }
        if let maximum = String.fromDatabaseValue(values[3]) {
            guard let order = compareAmounts(units, maximum), order != .orderedDescending else { return false }
        }
        return true
    }
}

/// Options come from all historical assets, including assets no longer held.
public struct HistoryFilterAsset: Decodable, FetchableRecord, Hashable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let symbol: String
    public let reference: String
    public let decimals: Int
    public let networkID: String
    public let networkName: String
    public let logo: String?
}

extension OathDatabase {
    public func historyFilterAssets(walletID: String, networkID: String? = nil,
                                    accountID: String? = nil, assetID: String? = nil) async throws -> [HistoryFilterAsset] {
        try await pool.read { db in
            var sql = """
                SELECT DISTINCT s.id,s.name,s.symbol,s.reference,s.decimals,s.networkID,n.name AS networkName,s.logo
                FROM visibleActivity a JOIN walletAccounts owner ON owner.id=a.accountID
                JOIN assets s ON s.id=a.assetID JOIN networks n ON n.id=s.networkID
                WHERE a.walletID=? AND owner.walletID=?
                AND (a.networkID<>'solana' OR EXISTS (SELECT 1 FROM solanaActivity sa WHERE sa.activityID=a.id
                    AND sa.owner=COALESCE((SELECT address FROM solanaReceiveAddresses WHERE accountID=a.accountID AND isSelected=1),owner.address)))
                """
            var arguments: StatementArguments = [walletID, walletID]
            if let networkID { sql += " AND a.networkID=?"; arguments += [networkID] }
            if let accountID { sql += " AND a.accountID=?"; arguments += [accountID] }
            if let assetID { sql += " AND a.assetID=?"; arguments += [assetID] }
            sql += " ORDER BY s.name COLLATE NOCASE,s.symbol COLLATE NOCASE,s.networkID,s.id"
            return try HistoryFilterAsset.fetchAll(db, sql: sql, arguments: arguments)
        }
    }
}
