import Foundation

struct TransactionExportDocument: Identifiable, Sendable {
    let id = UUID()
    let url: URL
    func remove() { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
}

struct TransactionExportLabels: Sendable {
    private let values: [String: String]
    let isRightToLeft: Bool
    let languageIdentifier: String
    init(languageIdentifier: String = WalletAppLanguage.selectedIdentifier, localize: (String) -> String = WalletLocalization.string) {
        self.languageIdentifier = languageIdentifier
        isRightToLeft = WalletAppLanguage.layoutDirection(for: languageIdentifier) == .rightToLeft
        let keys = [
            "transaction_export.title", "transaction_export.subtitle", "transaction_export.report_note",
            "transaction_export.date_note", "transaction_export.wallet", "transaction_export.recorded_fee",
            "transaction_export.unknown", "transaction_export.first_seen", "transaction_export.replacement",
            "transaction_export.entries", "transaction_export.date_range", "transaction_export.all_time",
            "settings.section.wallets", "network_fees.networks",
            "wallet.transaction.details.direction.sent", "wallet.transaction.details.direction.received",
            "wallet.transaction.details.direction.swapped", "wallet.activity.self_transfer.title",
            "wallet.activity.status.pending", "wallet.activity.status.confirmed", "wallet.activity.status.failed",
            "wallet.activity.status.canceled", "wallet.activity.status.replaced", "wallet.activity.status.not_found",
            "wallet.transaction.details.from", "wallet.transaction.details.to", "wallet.transaction.details.contract",
            "wallet.transaction.details.notes.section", "wallet.transaction.details.hash", "settings.wallets.details.address"
        ] + ReceiveNetworkCatalog.catalogNetworkIdentifiers.compactMap {
            ReceiveNetworkCatalog.catalogNetwork(for: $0)?.nameKey
        }
        values = Dictionary(keys.map { ($0, localize($0)) }, uniquingKeysWith: { first, _ in first })
    }
    subscript(_ key: String) -> String { values[key] ?? key }
}

enum TransactionExportCSV {
    static let headers = [
        "wallet_name", "wallet_id", "account_address", "network", "transaction_id", "activity_id",
        "date_utc", "date_basis", "first_seen_utc", "record_updated_utc", "status", "type", "direction",
        "asset", "asset_contract", "transfer_amount", "amount_atomic", "token_decimals", "log_index",
        "recorded_network_fee", "fee_asset", "sender", "recipient", "replacement_transaction_id", "flagged_spam", "note"
    ]

    /// Quote every field, preserve line breaks/quotes, and neutralize formula-like
    /// external text. Numeric fields are separately validated decimal/integer text.
    static func field(_ value: String, numeric: Bool = false) -> String {
        var text = value
        let visible = value.drop(while: { $0.isWhitespace || $0.unicodeScalars.allSatisfy { CharacterSet.controlCharacters.contains($0) || $0.value == 0xFEFF } })
        if !numeric, let first = visible.first, "=+-@＝＋－＠".contains(first) {
            text = "\t" + value
        }
        return "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    static func line(_ record: TransactionExportRecord) throws -> String {
        guard let amount = ExactDecimalText.canonicalMagnitude(record.assetAmount) else { throw TransactionExportError.invalidRecord }
        let fee = try record.networkFee.map { value in
            guard let result = ExactDecimalText.canonicalMagnitude(value) else { throw TransactionExportError.invalidRecord }
            return result
        } ?? ""
        let atomic = try record.amountAtomic.map { value in
            guard let result = ExactDecimalText.canonicalUnsignedInteger(value) else { throw TransactionExportError.invalidRecord }
            return result
        } ?? ""
        let fields = [
            record.walletName, record.walletID, record.accountAddress, record.networkID, record.transactionHash, record.id,
            timestamp(record.date), record.dateBasis, timestamp(Date(timeIntervalSince1970: record.firstSeenAt)),
            timestamp(Date(timeIntervalSince1970: record.updatedAt)), record.status, record.exportKind, record.direction,
            record.assetSymbol, record.contractAddress ?? "", amount, atomic,
            record.tokenDecimals.map(String.init) ?? "", record.logIndex.map(String.init) ?? "", fee,
            fee.isEmpty ? "" : (record.networkFeeSymbol ?? ""), record.fromAddress ?? "", record.toAddress ?? "",
            record.replacementTransactionHash ?? "", record.isSpam ? "true" : "false", record.note ?? ""
        ]
        return fields.enumerated().map { field($0.element, numeric: (15...19).contains($0.offset)) }.joined(separator: ",") + "\r\n"
    }

    static func timestamp(_ date: Date) -> String {
        date.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: true).timeZone(separator: .omitted))
    }
}

actor TransactionExportWriter {
    static let maximumPDFRecords = 5_000
    private let root: URL
    init(root: URL = FileManager.default.temporaryDirectory.appendingPathComponent("OathTransactionExports", isDirectory: true)) {
        self.root = root
    }

    func write(snapshot: TransactionExportSnapshot, format: TransactionExportFormat, labels: TransactionExportLabels) throws -> TransactionExportDocument {
        try Task.checkCancellation()
        guard !snapshot.records.isEmpty else { throw TransactionExportError.noRecords }
        guard format != .pdf || snapshot.records.count <= Self.maximumPDFRecords else { throw TransactionExportError.tooManyRecords }
        let manager = FileManager.default
        try manager.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.complete])
        removeExpiredFiles(now: Date())
        var directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.protectionKey: FileProtectionType.complete])
        let url = directory.appendingPathComponent("Oath-Transactions.\(format.rawValue)")
        do {
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try directory.setResourceValues(values)
            guard manager.createFile(atPath: url.path, contents: nil, attributes: [.protectionKey: FileProtectionType.complete]) else {
                throw TransactionExportError.fileWrite
            }
            switch format {
            case .csv:
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.write(contentsOf: Data([0xEF, 0xBB, 0xBF]))
                try handle.write(contentsOf: Data((TransactionExportCSV.headers.map { TransactionExportCSV.field($0) }.joined(separator: ",") + "\r\n").utf8))
                for record in snapshot.records {
                    try Task.checkCancellation()
                    try handle.write(contentsOf: Data(try TransactionExportCSV.line(record).utf8))
                }
                try handle.synchronize()
            case .pdf:
                try TransactionExportPDF.write(snapshot: snapshot, labels: labels, to: url)
            }
            try Task.checkCancellation()
            return TransactionExportDocument(url: url)
        } catch {
            try? manager.removeItem(at: directory)
            throw error
        }
    }

    private func removeExpiredFiles(now: Date) {
        let files = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.creationDateKey])) ?? []
        for file in files {
            guard UUID(uuidString: file.lastPathComponent) != nil,
                  let created = try? file.resourceValues(forKeys: [.creationDateKey]).creationDate,
                  now.timeIntervalSince(created) > 86_400 else { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }
}
