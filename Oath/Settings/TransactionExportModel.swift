import Foundation
import GRDB
import Observation

struct TransactionExportFilter: Hashable, Sendable {
    var networkID: String?
    var usesDateRange = false
    var startDate = Date()
    var endDate = Date()
    var includesNotes = false

    func interval(calendar: Calendar = .current) throws -> DateInterval? {
        guard usesDateRange else { return nil }
        let start = calendar.startOfDay(for: startDate)
        guard let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: endDate)),
              start < end else { throw TransactionExportError.invalidRange }
        return DateInterval(start: start, end: end)
    }
}

enum TransactionExportFormat: String, CaseIterable, Identifiable, Sendable {
    case csv, pdf
    var id: String { rawValue }
    var title: String { rawValue.uppercased() }
    var symbol: String { self == .csv ? "tablecells" : "doc.richtext" }
}

enum TransactionExportError: Error, Equatable {
    case invalidRange, tooManyRecords, noRecords, invalidRecord, fileWrite
    var messageKey: String {
        switch self {
        case .invalidRange: "transaction_export.invalid_range"
        case .tooManyRecords: "transaction_export.too_many"
        case .noRecords: "wallet.activity.filter.empty.title"
        case .invalidRecord, .fileWrite: "transaction_export.error"
        }
    }
}

struct TransactionExportRecord: Decodable, FetchableRecord, Sendable {
    let id: String
    let walletID: String
    let walletName: String
    let accountAddress: String
    let networkID: String
    let networkNameKey: String
    let transactionHash: String
    let timestamp: Double?
    let firstSeenAt: Double
    let updatedAt: Double
    let status: String
    let kind: String
    let direction: String
    let assetSymbol: String
    let contractAddress: String?
    let assetAmount: String
    let amountAtomic: String?
    let tokenDecimals: Int?
    let logIndex: Int?
    let fromAddress: String?
    let toAddress: String?
    var networkFee: String?
    let networkFeeSymbol: String?
    let replacementTransactionHash: String?
    let note: String?
    let isSpam: Bool

    var date: Date { Date(timeIntervalSince1970: timestamp ?? firstSeenAt) }
    var dateBasis: String { timestamp == nil ? "first_seen" : "blockchain" }
    var statusKey: String {
        WalletDatabase.walletTransactionStatus(status)?.localizedKey ?? "transaction_export.unknown"
    }
    var exportKind: String {
        guard kind != "swapped" else { return kind }
        if direction == "self" { return "self_transfer" }
        if BitcoinFamilyChain(rawValue: networkID) == nil,
           let fromAddress, let toAddress,
           let sender = SendRecipientAddressIdentity(address: fromAddress, networkID: networkID),
           let recipient = SendRecipientAddressIdentity(address: toAddress, networkID: networkID), sender == recipient {
            return "self_transfer"
        }
        return kind
    }
    var kindKey: String {
        switch exportKind {
        case "sent": "wallet.transaction.details.direction.sent"
        case "received": "wallet.transaction.details.direction.received"
        case "self_transfer": "wallet.activity.self_transfer.title"
        case "swapped": "wallet.transaction.details.direction.swapped"
        default: "transaction_export.unknown"
        }
    }
}

struct TransactionExportSnapshot: Sendable {
    let generatedAt: Date
    let filter: TransactionExportFilter
    let records: [TransactionExportRecord]
}

extension WalletDatabase {
    // Export stored history directly. The home projection deliberately limits rows
    // and hides low-value tokens, neither of which is appropriate for a report.
    private static func exportWhere(_ filter: TransactionExportFilter, calendar: Calendar) throws -> (String, StatementArguments) {
        // Resolve selection in the same database read as the history. No selection
        // means no exportable rows; never fall back to another or every wallet.
        var conditions = ["w.profileID = ?", "w.archivedAt IS NULL", "w.isSelected = 1", "n.isMainnet = 1"]
        var arguments: StatementArguments = [defaultProfileID]
        if let networkID = filter.networkID {
            conditions.append("t.networkID = ?")
            arguments += [networkID]
        }
        if let range = try filter.interval(calendar: calendar) {
            conditions.append("COALESCE(t.timestamp, t.firstSeenAt) >= ? AND COALESCE(t.timestamp, t.firstSeenAt) < ?")
            arguments += [range.start.timeIntervalSince1970, range.end.timeIntervalSince1970]
        }
        return (conditions.joined(separator: " AND "), arguments)
    }

    private static let exportJoins = """
        FROM transactions t
        JOIN walletAccounts a ON a.id = t.accountID
        JOIN wallets w ON w.id = a.walletID
        JOIN networks n ON n.id = t.networkID
        """

    func transactionExportCount(filter: TransactionExportFilter, calendar: Calendar = .current) async throws -> Int {
        let (predicate, arguments) = try Self.exportWhere(filter, calendar: calendar)
        return try await pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) \(Self.exportJoins) WHERE \(predicate)", arguments: arguments) ?? 0
        }
    }

    func transactionExportSnapshot(filter: TransactionExportFilter, calendar: Calendar = .current) async throws -> TransactionExportSnapshot {
        let (predicate, arguments) = try Self.exportWhere(filter, calendar: calendar)
        return try await pool.read { db in
            // Bound memory and PDF generation without silently truncating a report.
            var records = try TransactionExportRecord.fetchAll(db, sql: """
                SELECT t.id, w.id AS walletID, w.name AS walletName, a.address AS accountAddress,
                    t.networkID, n.nameKey AS networkNameKey, t.transactionHash,
                    t.timestamp, t.firstSeenAt, t.updatedAt,
                    CASE WHEN t.observedStatus = 'notFound' AND t.status = 'pending' THEN 'notFound'
                         WHEN t.observedStatus = 'replaced' AND t.status IN ('pending', 'canceled') THEN 'replaced'
                         ELSE t.status END AS status,
                    t.kind, t.direction, t.assetSymbol, s.contractAddress,
                    COALESCE(p.amount, t.assetAmount) AS assetAmount,
                    p.amountAtomic, COALESCE(p.tokenDecimals, s.decimals) AS tokenDecimals, p.logIndex,
                    COALESCE(t.fromAddress, p.fromAddress) AS fromAddress,
                    COALESCE(t.toAddress, p.toAddress) AS toAddress,
                    t.networkFee, COALESCE(t.networkFeeSymbol, n.nativeSymbol) AS networkFeeSymbol,
                    t.replacementTransactionHash,
                    \(filter.includesNotes ? "notes.note" : "NULL") AS note,
                    COALESCE(s.isSpam, 0) AS isSpam
                \(Self.exportJoins)
                LEFT JOIN assets s ON s.id = t.assetID
                LEFT JOIN transactionTransfers p ON p.id = t.id || '|primary'
                LEFT JOIN transactionNotes notes ON notes.transactionID = t.id
                WHERE \(predicate)
                ORDER BY COALESCE(t.timestamp, t.firstSeenAt) DESC, t.id
                LIMIT 50001
                """, arguments: arguments)
            guard records.count <= 50_000 else { throw TransactionExportError.tooManyRecords }
            guard !records.isEmpty else { throw TransactionExportError.noRecords }
            var fees = Set<String>()
            for index in records.indices {
                try Task.checkCancellation()
                let row = records[index]
                guard ExactDecimalText.canonicalMagnitude(row.assetAmount) != nil,
                      !row.transactionHash.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      row.date.timeIntervalSince1970.isFinite, row.firstSeenAt.isFinite,
                      row.updatedAt.isFinite else { throw TransactionExportError.invalidRecord }
                if let fee = row.networkFee {
                    guard ExactDecimalText.canonicalMagnitude(fee) != nil else { throw TransactionExportError.invalidRecord }
                    // Keep case-sensitive hashes (e.g. Solana) intact. Hex identifiers
                    // alone have a canonical case-insensitive representation.
                    let caseInsensitive = BitcoinFamilyChain(rawValue: row.networkID) != nil
                        || ReceiveNetworkCatalog.catalogNetwork(for: row.networkID)?.blockchain.isEVM == true
                    let hash = caseInsensitive
                        ? row.transactionHash.lowercased() : row.transactionHash
                    let identity = [row.walletID, row.networkID, hash].joined(separator: "|")
                    if !fees.insert(identity).inserted { records[index].networkFee = nil }
                }
            }
            return TransactionExportSnapshot(generatedAt: Date(), filter: filter, records: records)
        }
    }
}

@MainActor @Observable
final class TransactionExportModel {
    var count: Int?
    var isPreparing = false
    var errorKey: String?
    var document: TransactionExportDocument?
    private var generation = UUID()
    private let writer = TransactionExportWriter()

    func load(database: WalletDatabase, filter: TransactionExportFilter) async {
        let request = UUID()
        generation = request
        count = nil
        errorKey = nil
        do {
            let count = try await database.transactionExportCount(filter: filter)
            guard generation == request, !Task.isCancelled else { return }
            self.count = count
        } catch is CancellationError {} catch {
            guard generation == request, !Task.isCancelled else { return }
            errorKey = (error as? TransactionExportError)?.messageKey ?? "transaction_export.error"
        }
    }

    func prepare(database: WalletDatabase, filter: TransactionExportFilter, format: TransactionExportFormat) async {
        guard !isPreparing else { return }
        isPreparing = true
        errorKey = nil
        defer { isPreparing = false }
        do {
            let snapshot = try await database.transactionExportSnapshot(filter: filter)
            let labels = TransactionExportLabels()
            let result = try await writer.write(snapshot: snapshot, format: format, labels: labels)
            if Task.isCancelled { result.remove(); return }
            document = result
            count = snapshot.records.count
        } catch is CancellationError {} catch {
            errorKey = (error as? TransactionExportError)?.messageKey ?? "transaction_export.error"
        }
    }

    func discardDocument() {
        document?.remove()
        document = nil
    }
}
