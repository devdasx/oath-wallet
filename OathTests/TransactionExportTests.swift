import Foundation
import GRDB
import PDFKit
import SwiftUI
import Testing
@testable import Aperture

@MainActor @Suite(.serialized)
struct TransactionExportTests {
    nonisolated private static let exact = "123456789012345678901234567890.123456789012345678"
    nonisolated private static let hash = String(repeating: "a", count: 64)

    @Test
    func everyNetworkExportsWithoutHomeVisibilityOrPaginationLimits() async throws {
        let db = try WalletDatabase.temporary()
        try await db.pool.write { sql in
            try Self.wallet("wallet", in: sql)
            for id in ReceiveNetworkCatalog.catalogNetworkIdentifiers {
                try Self.account(wallet: "wallet", network: id, in: sql)
                try Self.transaction(id: id, network: id, in: sql)
            }
            for index in 0..<2100 { try Self.transaction(id: "extra-\(index)", in: sql) }
        }
        let snapshot = try await db.transactionExportSnapshot(filter: .init())
        #expect(snapshot.records.count == 2100 + ReceiveNetworkCatalog.catalogNetworkIdentifiers.count)
        #expect(Set(snapshot.records.map(\.networkID)) == Set(ReceiveNetworkCatalog.catalogNetworkIdentifiers))
        #expect(snapshot.records.allSatisfy { $0.assetAmount == Self.exact })
    }

    @Test
    func profileArchiveWalletAndNetworkFiltersAreEnforced() async throws {
        let db = try await fixture()
        try await db.pool.write { sql in
            try DBProfileRecord(id: "foreign", displayName: nil, createdAt: 1, updatedAt: 1, lastActiveAt: 1).insert(sql)
            try Self.wallet("foreign-wallet", profile: "foreign", in: sql)
            try Self.wallet("archived", archived: 2, in: sql)
            try Self.wallet("second", in: sql)
            for wallet in ["foreign-wallet", "archived", "second"] {
                try Self.account(wallet: wallet, network: "eth", in: sql)
                try Self.transaction(id: wallet, wallet: wallet, in: sql)
            }
            try Self.account(wallet: "second", network: "bitcoin", in: sql)
            try Self.transaction(id: "bitcoin", wallet: "second", network: "bitcoin", in: sql)
            // Disabling an account does not delete its accounting history.
            try sql.execute(sql: "UPDATE walletAccounts SET isEnabled = 0 WHERE walletID = 'second'")
        }
        #expect(try await db.transactionExportCount(filter: .init()) == 1)
        #expect(try await db.transactionExportSnapshot(filter: .init()).records.map(\.id) == ["first"])
        #expect(try await db.transactionExportCount(filter: .init(networkID: "bitcoin")) == 0)
        try await db.pool.write { sql in
            try sql.execute(sql: "UPDATE wallets SET isSelected = 0")
            try sql.execute(sql: "UPDATE wallets SET isSelected = 1 WHERE id = 'second'")
        }
        #expect(try await db.transactionExportCount(filter: .init()) == 2)
        let rows = try await db.transactionExportSnapshot(filter: .init(networkID: "bitcoin"))
        #expect(rows.records.map(\.id) == ["bitcoin"])
        #expect(rows.records.allSatisfy { $0.walletID == "second" })
        #expect(try await db.transactionExportCount(filter: .init(networkID: "' OR 1=1 --")) == 0)
    }

    @Test
    func missingOrUnavailableActiveWalletNeverExportsAnotherWallet() async throws {
        let db = try await fixture()
        try await db.pool.write { try $0.execute(sql: "UPDATE wallets SET isSelected = 0") }
        #expect(try await db.transactionExportCount(filter: .init()) == 0)
        await #expect(throws: TransactionExportError.noRecords) {
            try await db.transactionExportSnapshot(filter: .init())
        }
        try await db.pool.write { try $0.execute(sql: "UPDATE wallets SET isSelected = 1, archivedAt = 2") }
        #expect(try await db.transactionExportCount(filter: .init()) == 0)
        await #expect(throws: TransactionExportError.noRecords) {
            try await db.transactionExportSnapshot(filter: .init())
        }
    }

    @Test(arguments: TransactionExportFormat.allCases)
    func exportResolvesTheCurrentWalletAgainAfterThePreviewLoads(format: TransactionExportFormat) async throws {
        let db = try await fixture()
        try await db.pool.write { sql in
            try Self.wallet("second", in: sql)
            try Self.account(wallet: "second", network: "eth", in: sql)
            try Self.transaction(id: "second-one", wallet: "second", in: sql)
            try Self.transaction(id: "second-two", wallet: "second", in: sql)
            try sql.execute(sql: "UPDATE wallets SET name = CASE WHEN id = 'wallet' THEN 'PREVIOUS-WALLET' ELSE 'CURRENT-WALLET' END")
        }
        let model = TransactionExportModel()
        defer { model.discardDocument() }
        await model.load(database: db, filter: .init())
        #expect(model.count == 1)
        try await db.pool.write { sql in
            try sql.execute(sql: "UPDATE wallets SET isSelected = 0")
            try sql.execute(sql: "UPDATE wallets SET isSelected = 1 WHERE id = 'second'")
        }
        await model.prepare(database: db, filter: .init(), format: format)
        #expect(model.errorKey == nil && model.count == 2)
        let file = try #require(model.document)
        let text: String
        if format == .pdf {
            text = try #require(PDFDocument(url: file.url)?.string)
        } else {
            text = try String(contentsOf: file.url, encoding: .utf8)
        }
        #expect(text.contains("CURRENT-WALLET"))
        #expect(!text.contains("PREVIOUS-WALLET"))
    }

    @Test
    func dateRangeIncludesTheWholeLocalEndDayAndFirstSeenFallback() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/New_York"))
        let day = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 1)))
        let filter = TransactionExportFilter(usesDateRange: true, startDate: day, endDate: day)
        let interval = try #require(try filter.interval(calendar: calendar))
        #expect(interval.duration == 25 * 3600)
        let db = try await fixture()
        try await db.pool.write { sql in
            try sql.execute(sql: "DELETE FROM transactions")
            try Self.transaction(id: "start", timestamp: interval.start.timeIntervalSince1970, in: sql)
            try Self.transaction(id: "end", timestamp: interval.end.timeIntervalSince1970 - 1, in: sql)
            try Self.transaction(id: "next-day", timestamp: interval.end.timeIntervalSince1970, in: sql)
            try Self.transaction(id: "undated", timestamp: nil, firstSeen: interval.start.timeIntervalSince1970 + 1, in: sql)
        }
        let rows = try await db.transactionExportSnapshot(filter: filter, calendar: calendar).records
        #expect(Set(rows.map(\.id)) == ["start", "end", "undated"])
        #expect(rows.first(where: { $0.id == "undated" })?.dateBasis == "first_seen")
        var invalid = filter
        invalid.startDate = interval.end
        #expect(throws: TransactionExportError.invalidRange) { try invalid.interval(calendar: calendar) }
    }

    @Test
    func savedOutcomesSelfTransfersAndReplacementLinksArePreserved() async throws {
        let db = try await fixture()
        try await db.pool.write { sql in
            try sql.execute(sql: "DELETE FROM transactions")
            for status in ["pending", "confirmed", "canceled", "failed"] {
                try Self.transaction(id: status, status: status, in: sql)
            }
            try Self.transaction(id: "replaced", observedStatus: "replaced", in: sql)
            try Self.transaction(id: "missing", observedStatus: "notFound", in: sql)
            try Self.transaction(id: "self", direction: "self", in: sql)
            try sql.execute(sql: "UPDATE transactions SET replacementTransactionHash = 'replacement-hash' WHERE id = 'replaced'")
        }
        let rows = try await db.transactionExportSnapshot(filter: .init()).records
        #expect(Set(rows.map(\.status)) == ["pending", "confirmed", "canceled", "failed", "replaced", "notFound"])
        #expect(rows.first(where: { $0.id == "replaced" })?.replacementTransactionHash == "replacement-hash")
        #expect(rows.first(where: { $0.id == "self" })?.exportKind == "self_transfer")
    }

    @Test
    func primaryTransferPrecisionNotesAndRepeatedTransactionFees() async throws {
        let db = try await fixture()
        try await db.pool.write { sql in
            try Self.transaction(id: "second-asset", in: sql)
            try DBTransactionTransferRecord(id: "first|primary", transactionID: "first", logIndex: 17,
                assetID: nil, fromAddress: nil, toAddress: nil, direction: "outgoing", amount: "0.000000000000000001",
                amountAtomic: "1", fiatUSDValue: nil, tokenName: nil, tokenSymbol: "TOK", tokenDecimals: 18).insert(sql)
            try DBTransactionNoteRecord(transactionID: "first", note: "Private local note", createdAt: 1, updatedAt: 1).insert(sql)
        }
        let without = try await db.transactionExportSnapshot(filter: .init()).records
        #expect(without.allSatisfy { $0.note == nil })
        #expect(without.compactMap(\.networkFee).count == 1)
        let with = try await db.transactionExportSnapshot(filter: .init(includesNotes: true)).records
        let first = try #require(with.first { $0.id == "first" })
        #expect(first.assetAmount == "0.000000000000000001" && first.amountAtomic == "1")
        #expect(first.note == "Private local note" && first.logIndex == 17)
    }

    @Test
    func feesAreScopedToWalletAndNetworkAndPreserveCaseSensitiveHashes() async throws {
        let db = try await fixture()
        try await db.pool.write { sql in
            try Self.wallet("second", in: sql)
            try Self.account(wallet: "second", network: "eth", in: sql)
            try Self.transaction(id: "second-wallet", wallet: "second", in: sql)
            try Self.transaction(id: "same-hash-uppercase", in: sql)
            try sql.execute(sql: "UPDATE transactions SET transactionHash = ? WHERE id = ?",
                            arguments: [Self.hash.uppercased(), "same-hash-uppercase"])
            try Self.account(wallet: "wallet", network: "solana", in: sql)
            try Self.transaction(id: "solana-a", network: "solana", in: sql)
            try Self.transaction(id: "solana-A", network: "solana", in: sql)
            try sql.execute(sql: "UPDATE transactions SET transactionHash = ? WHERE id = ?",
                            arguments: [Self.hash.uppercased(), "solana-A"])
        }
        let records = try await db.transactionExportSnapshot(filter: .init()).records
        #expect(records.compactMap(\.networkFee).count == 3)
        #expect(records.filter { $0.networkID == "solana" }.compactMap(\.networkFee).count == 2)
    }

    @Test
    func writeFailureRemovesPartialCSVAndTheModelDiscardsSharedFiles() async throws {
        let db = try await fixture()
        try await db.pool.write { sql in
            try DBTransactionTransferRecord(id: "first|primary", transactionID: "first", logIndex: nil,
                assetID: nil, fromAddress: nil, toAddress: nil, direction: "outgoing", amount: "1",
                amountAtomic: "invalid", fiatUSDValue: nil, tokenName: nil, tokenSymbol: "TOK", tokenDecimals: 18).insert(sql)
        }
        let snapshot = try await db.transactionExportSnapshot(filter: .init())
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        await #expect(throws: TransactionExportError.invalidRecord) {
            try await TransactionExportWriter(root: root).write(snapshot: snapshot, format: .csv, labels: .init())
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        try await db.pool.write { try $0.execute(sql: "UPDATE transactionTransfers SET amountAtomic = '1'") }
        let model = TransactionExportModel()
        await model.load(database: db, filter: .init())
        #expect(model.count == 1)
        await model.prepare(database: db, filter: .init(), format: .csv)
        let document = try #require(model.document)
        #expect(!model.isPreparing && model.errorKey == nil)
        #expect(FileManager.default.fileExists(atPath: document.url.path))
        model.discardDocument()
        #expect(model.document == nil)
        #expect(!FileManager.default.fileExists(atPath: document.url.path))
    }

    @Test
    func csvRetainsExactValuesAndEscapesExternalText() async throws {
        let db = try await fixture()
        try await db.pool.write { sql in
            try sql.execute(sql: "UPDATE wallets SET name = ?", arguments: ["=HYPERLINK(\"https://invalid.example\")"])
            try DBTransactionNoteRecord(transactionID: "first", note: "Arabic العربية, quote \" and\nnext line",
                createdAt: 1, updatedAt: 1).insert(sql)
        }
        let snapshot = try await db.transactionExportSnapshot(filter: .init(includesNotes: true))
        let document = try await TransactionExportWriter().write(snapshot: snapshot, format: .csv, labels: .init())
        let bytes = try Data(contentsOf: document.url)
        #expect(bytes.starts(with: [0xEF, 0xBB, 0xBF]))
        let text = try #require(String(data: bytes, encoding: .utf8))
        #expect(text.contains("\"\t=HYPERLINK(\"\"https://invalid.example\"\")\""))
        #expect(text.contains(Self.exact))
        #expect(text.contains("Arabic العربية, quote \"\" and\nnext line"))
        for payload in ["=1+1", "+1+1", "-1+1", "@SUM(1)", "  =1+1", "\n=1+1", "＝1+1"] {
            #expect(TransactionExportCSV.field(payload).hasPrefix("\"\t"))
        }
        #expect(!text.contains("secretKeyReference"))
        print("Transaction export fixture CSV: \(document.url.path)")
    }

    @Test
    func invalidAmountsFailWithoutLeavingAPartialFile() async throws {
        let db = try await fixture()
        try await db.pool.write { try $0.execute(sql: "UPDATE transactions SET assetAmount = '=2+2'") }
        await #expect(throws: TransactionExportError.invalidRecord) { try await db.transactionExportSnapshot(filter: .init()) }
        try await db.pool.write { try $0.execute(sql: "UPDATE transactions SET assetAmount = '1'") }
        let snapshot = try await db.transactionExportSnapshot(filter: .init())
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = TransactionExportWriter(root: root)
        let task = Task {
            try Task.checkCancellation()
            return try await writer.write(snapshot: snapshot, format: .csv, labels: .init())
        }
        task.cancel()
        do { _ = try await task.value; Issue.record("Canceled generation unexpectedly completed") } catch is CancellationError {} catch { throw error }
        #expect(!FileManager.default.fileExists(atPath: root.path))
        let file = try await writer.write(snapshot: snapshot, format: .csv, labels: .init())
        #expect(FileManager.default.fileExists(atPath: file.url.path))
        file.remove()
        #expect(!FileManager.default.fileExists(atPath: file.url.deletingLastPathComponent().path))
    }

    @Test(arguments: ["en", "ar"])
    func pdfContainsEveryRecordAcrossPages(language: String) async throws {
        let db = try await fixture()
        try await db.pool.write { sql in
            for index in 0..<24 { try Self.transaction(id: "pdf-\(index)", in: sql) }
            try DBTransactionNoteRecord(transactionID: "first", note: String(repeating: "Report note ملاحظة التقرير. ", count: 30), createdAt: 1, updatedAt: 1).insert(sql)
        }
        let snapshot = try await db.transactionExportSnapshot(filter: .init(includesNotes: true))
        let labels = TransactionExportLabels(languageIdentifier: language) { WalletAppLanguage.localizedBundle(for: language).localizedString(forKey: $0, value: $0, table: nil) }
        let file = try await TransactionExportWriter().write(snapshot: snapshot, format: .pdf, labels: labels)
        let pdf = try #require(PDFDocument(url: file.url))
        #expect(pdf.pageCount > 1)
        let text = try #require(pdf.string)
        #expect(text.contains(Self.hash))
        #expect(text.contains("25.") || (language == "ar" && text.contains(".25")))
        #expect(!text.contains("transaction_export."))
        for index in 0..<pdf.pageCount { #expect((pdf.page(at: index)?.string?.count ?? 0) > 30) }
        print("Transaction export fixture PDF \(language): \(file.url.path)")
    }

    @Test(arguments: ["en", "ar"])
    func brandedReportPreservesDetailsAndPageNumbering(language: String) async throws {
        let labels = TransactionExportLabels(languageIdentifier: language) {
            WalletAppLanguage.localizedBundle(for: language).localizedString(forKey: $0, value: $0, table: nil)
        }
        let statuses = ["confirmed", "pending", "replaced", "failed", "canceled", "confirmed"]
        let networks = ["bitcoin", "eth", "bitcoin", "solana", "bsc", "eth"]
        let symbols = ["BTC", "ETH", "BTC", "SOL", "BNB", "USDC"]
        let amounts = ["0.00166812", "0.42", "0.00011631", "1.5", "0.08", "1250"]
        let generatedAt = Date(timeIntervalSince1970: 1_790_122_200)
        var records: [TransactionExportRecord] = []
        for index in 0..<6 {
            let walletName = language == "ar" ? (index == 5 ? "محفظة الادخار" : "المحفظة اليومية") : (index == 5 ? "Savings Wallet" : "Everyday Wallet")
            let date = generatedAt.addingTimeInterval(Double(-index * 7200 - 3600)).timeIntervalSince1970
            let receiving = index == 0 || index == 5
            let bitcoin = networks[index] == "bitcoin"
            let solana = networks[index] == "solana"
            let account = bitcoin ? "bc1qcr8te4kr609gcawutmrza0j4xv80jy8z306fyu" : (solana ? "11111111111111111111111111111111" : "0x1111111111111111111111111111111111111111")
            let other = bitcoin ? "bc1qgv52mt89gpev6p56huggl970sppqkgftxakv7f" : (solana ? "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA" : "0x2222222222222222222222222222222222222222")
            let exampleNote = language == "ar" ? "تقرير توضيحي ببيانات تجريبية فقط." : "Illustrative report with sample activity only."
            let record = TransactionExportRecord(id: "design-\(index)", walletID: index == 5 ? "savings" : "everyday",
                walletName: walletName, accountAddress: account,
                networkID: networks[index], networkNameKey: ReceiveNetworkCatalog.catalogNetwork(for: networks[index])!.nameKey,
                transactionHash: String(repeating: String(index + 1), count: 64),
                timestamp: index == 1 ? nil : date, firstSeenAt: date,
                updatedAt: generatedAt.timeIntervalSince1970, status: statuses[index],
                kind: receiving ? "received" : "sent", direction: receiving ? "incoming" : "outgoing",
                assetSymbol: symbols[index], contractAddress: index == 5 ? "0x3333333333333333333333333333333333333333" : nil,
                assetAmount: amounts[index], amountAtomic: nil, tokenDecimals: nil, logIndex: nil,
                fromAddress: receiving ? other : account, toAddress: receiving ? account : other,
                networkFee: index == 0 ? "0.00000133" : nil, networkFeeSymbol: symbols[index],
                replacementTransactionHash: index == 2 ? String(repeating: "b", count: 64) : nil,
                note: index == 0 ? exampleNote : nil,
                isSpam: false)
            records.append(record)
        }
        let snapshot = TransactionExportSnapshot(generatedAt: generatedAt, filter: .init(includesNotes: true), records: records)
        let file = try await TransactionExportWriter().write(snapshot: snapshot, format: .pdf, labels: labels)
        let pdf = try #require(PDFDocument(url: file.url))
        let text = try #require(pdf.string)
        #expect(pdf.pageCount > 1)
        let compact = text.filter { !$0.isWhitespace }
        for record in records {
            #expect(compact.contains(record.transactionHash))
            #expect(compact.contains(record.assetAmount))
        }
        #expect(compact.contains(String(repeating: "b", count: 64)))
        #expect(!text.contains("transaction_export.") && !text.contains("network_fees."))
        for index in 0..<pdf.pageCount {
            let page = try #require(pdf.page(at: index))
            let pageText = try #require(page.string)
            #expect(pageText.contains("Oath Wallet"))
            #expect(pageText.contains("2026"))
            // PDFKit reads numeric groups in the page's dominant direction even
            // for LTR glyph runs. Rendered counters stay page / total in both locales.
            let pageNumber = language == "ar"
                ? String(format: "%02d / %02d", pdf.pageCount, index + 1)
                : String(format: "%02d / %02d", index + 1, pdf.pageCount)
            let footerRect = CGRect(x: language == "ar" ? 36 : page.bounds(for: .mediaBox).width - 111,
                                    y: 10, width: 75, height: 25)
            let counter = try #require(page.selection(for: footerRect)?.string)
            #expect(counter.trimmingCharacters(in: .whitespacesAndNewlines) == pageNumber)
            // The real app logo must be embedded, not just the company name.
            let reference = try #require(page.pageRef)
            let dictionary = try #require(reference.dictionary)
            var resources: CGPDFDictionaryRef?
            var objects: CGPDFDictionaryRef?
            #expect(CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources))
            #expect(CGPDFDictionaryGetDictionary(try #require(resources), "XObject", &objects))
            #expect(CGPDFDictionaryGetCount(try #require(objects)) > 0)
        }
        print("Transaction export branded PDF \(language): \(file.url.path)")
    }

    @Test
    func oversizedPDFNotesAndIdentifiersContinueWithoutLoss() async throws {
        let note = String(repeating: "Long note العربية retains every word. ", count: 450) + "END-OF-REPORT-NOTE"
        let identifier = "0x" + String(repeating: "abcdef0123456789", count: 100) + "fedcba"
        // Exercise the renderer directly beyond the database's 1,000-character
        // note limit, so paragraph continuation is genuinely tested.
        let record = TransactionExportRecord(id: "long", walletID: "wallet", walletName: "Long Report",
            accountAddress: "0x1111111111111111111111111111111111111111", networkID: "eth", networkNameKey: "network.ethereum",
            transactionHash: identifier, timestamp: 1_790_000_000, firstSeenAt: 1_790_000_000, updatedAt: 1_790_000_000,
            status: "confirmed", kind: "sent", direction: "outgoing", assetSymbol: "ETH", contractAddress: nil,
            assetAmount: Self.exact, amountAtomic: nil, tokenDecimals: nil, logIndex: nil, fromAddress: nil, toAddress: nil,
            networkFee: nil, networkFeeSymbol: nil, replacementTransactionHash: nil, note: note, isSpam: false)
        let snapshot = TransactionExportSnapshot(generatedAt: Date(), filter: .init(includesNotes: true), records: [record])
        let file = try await TransactionExportWriter().write(snapshot: snapshot, format: .pdf, labels: .init())
        let pdf = try #require(PDFDocument(url: file.url))
        let text = try #require(pdf.string)
        #expect(pdf.pageCount >= 3)
        #expect(text.filter { !$0.isWhitespace }.contains(identifier))
        #expect(text.contains("END-OF-REPORT-NOTE"))
        // A sentence may span pages with repeated mastheads/footers in between;
        // each distinct word must survive exactly once per original repetition.
        for word in ["retains", "every", "word."] {
            #expect(text.components(separatedBy: word).count - 1 == 450)
        }
        for index in 0..<pdf.pageCount {
            let pageText = try #require(pdf.page(at: index)?.string)
            #expect(pageText.contains("1.")) // Continuations retain their transaction identity.
        }
        print("Transaction export long PDF: \(file.url.path)")
    }

    @Test
    func reportDatesAndLabelsWorkInEverySupportedLanguage() async throws {
        let db = try await fixture()
        let filter = TransactionExportFilter(usesDateRange: true,
            startDate: Date(timeIntervalSince1970: 1_789_900_000), endDate: Date(timeIntervalSince1970: 1_790_100_000))
        let snapshot = try await db.transactionExportSnapshot(filter: filter)
        for language in WalletAppLanguage.supportedIdentifiers {
            let labels = TransactionExportLabels(languageIdentifier: language) {
                WalletAppLanguage.localizedBundle(for: language).localizedString(forKey: $0, value: $0, table: nil)
            }
            let file = try await TransactionExportWriter().write(snapshot: snapshot, format: .pdf, labels: labels)
            defer { file.remove() }
            let pdf = try #require(PDFDocument(url: file.url))
            let text = try #require(pdf.string)
            #expect(text.contains(Self.hash), "Missing identifier in \(language)")
            #expect(text.components(separatedBy: "2026").count >= 4, "Missing report, range or transaction dates in \(language)")
            #expect(!text.contains("transaction_export.") && !text.contains("network_fees."), "Untranslated report key in \(language)")
        }
    }

    @Test(arguments: NativeListTestLayout.allCases)
    func nativeExportScreenFitsAndLoadsItsStoredHistory(layout: NativeListTestLayout) async throws {
        let db = try await fixture()
        let host = try NativeListTestHost(layout: layout) {
            NavigationStack { TransactionExportView(database: db) }
        }
        defer { host.close() }
        let list = try await host.list { $0.numberOfSections == 3 && $0.numberOfItems(inSection: 1) == 2 }
        let cell = try await host.cell(at: IndexPath(item: 0, section: 1), in: list)
        #expect(cell.bounds.height >= 44 && cell.bounds.width <= host.rootView.bounds.width)
        let toggle = try await host.cell(at: IndexPath(item: 1, section: 2), in: list)
        #expect(!SendEntryUIProbe.views(UISwitch.self, in: toggle).isEmpty)
        list.setContentOffset(CGPoint(x: 0, y: -list.adjustedContentInset.top), animated: false)
        host.rootView.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(500))
        let image = UIGraphicsImageRenderer(bounds: host.rootView.bounds).pngData { _ in
            host.rootView.drawHierarchy(in: host.rootView.bounds, afterScreenUpdates: true)
        }
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("oath-transaction-export-\(layout).png")
        try image.write(to: path)
        print("Transaction export layout: \(path.path)")
    }

    private func fixture() async throws -> WalletDatabase {
        let db = try WalletDatabase.temporary()
        try await db.pool.write { sql in
            try Self.wallet("wallet", in: sql)
            try Self.account(wallet: "wallet", network: "eth", in: sql)
            try Self.transaction(id: "first", in: sql)
        }
        return db
    }

    nonisolated private static func wallet(_ id: String, profile: String = WalletDatabase.defaultProfileID,
                                           archived: Double? = nil, in db: Database) throws {
        try DBWalletRecord(id: id, profileID: profile, name: "Research Wallet محفظة", kind: "watchOnly",
            secretKeyReference: nil, isSelected: id == "wallet", sortOrder: 0, createdAt: 1, updatedAt: 1,
            lastOpenedAt: nil, archivedAt: archived).insert(db)
    }
    nonisolated private static func account(wallet: String, network: String, in db: Database) throws {
        let address = "0x1111111111111111111111111111111111111111"
        try DBWalletAccountRecord(id: "\(wallet)-\(network)", walletID: wallet, networkID: network,
            address: address, normalizedAddress: address, label: nil, derivationPath: nil,
            accountIndex: nil, publicKey: nil, isWatchOnly: true, isEnabled: true, createdAt: 1,
            updatedAt: 1, lastSyncedAt: nil).insert(db)
    }
    nonisolated private static func transaction(id: String, wallet: String = "wallet", network: String = "eth",
        status: String = "pending", observedStatus: String? = nil, direction: String = "outgoing",
        timestamp: Double? = 1_790_000_000, firstSeen: Double = 1_790_000_000, in db: Database) throws {
        try DBTransactionRecord(id: id, accountID: "\(wallet)-\(network)", networkID: network,
            transactionHash: hash, normalizedTransactionHash: hash, kind: "sent", status: status,
            direction: direction, fromAddress: "0x1111111111111111111111111111111111111111",
            toAddress: "0x2222222222222222222222222222222222222222", counterpartyAddress: nil,
            blockNumber: nil, blockHash: nil, transactionIndex: nil, nonce: nil, transactionType: nil,
            timestamp: timestamp, assetID: nil, assetSymbol: "TOK", secondaryAssetSymbol: nil,
            assetAmount: exact, fiatUSDValue: nil, networkFee: "0.000000000000000001", networkFeeFiatUSDValue: nil,
            networkFeeSymbol: "ETH", gasPriceGwei: nil, gasLimit: nil, gasUsed: nil, inputData: nil,
            methodName: nil, displayDetail: "", displayTime: "", firstSeenAt: firstSeen, updatedAt: firstSeen,
            observedStatus: observedStatus).insert(db)
    }
}
