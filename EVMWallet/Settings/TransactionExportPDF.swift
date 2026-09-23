import Foundation
import CoreText
import UIKit

/// Draws selectable Unicode text directly into a file, on the export actor.
/// Paragraphs flow across pages, including long notes and unbroken identifiers.
enum TransactionExportPDF {
    static func write(snapshot: TransactionExportSnapshot, labels: TransactionExportLabels, to url: URL) throws {
        let sink = try FileSink(url: url)
        defer { sink.close() }
        var callbacks = CGDataConsumerCallbacks(putBytes: { info, bytes, count in
            guard let info else { return 0 }
            return Unmanaged<FileSink>.fromOpaque(info).takeUnretainedValue().write(bytes, count: count)
        }, releaseConsumer: nil)
        var page = CGRect(x: 0, y: 0, width: 595.28, height: 841.89)
        guard let consumer = CGDataConsumer(info: Unmanaged.passUnretained(sink).toOpaque(), cbks: &callbacks),
              let context = CGContext(consumer: consumer, mediaBox: &page, [
                kCGPDFContextTitle: labels["transaction_export.title"],
                kCGPDFContextCreator: "Oath Wallet"
              ] as CFDictionary) else { throw TransactionExportError.fileWrite }
        try render(snapshot: snapshot, labels: labels, context: context, page: page)
        try sink.finish()
    }

    // CGDataConsumer(url:) can hide disk-write errors. A checked sink makes a
    // full disk or interrupted write fail the export and remove its partial file.
    private final class FileSink {
        let handle: FileHandle
        var failure: Error?
        init(url: URL) throws { handle = try FileHandle(forWritingTo: url) }
        func write(_ bytes: UnsafeRawPointer, count: Int) -> Int {
            guard failure == nil else { return 0 }
            do {
                try Task.checkCancellation()
                try handle.write(contentsOf: Data(bytes: bytes, count: count))
                return count
            } catch {
                failure = error
                return 0
            }
        }
        func finish() throws {
            if let failure { throw failure }
            try handle.synchronize()
        }
        func close() { try? handle.close() }
    }

    private static func render(snapshot: TransactionExportSnapshot, labels: TransactionExportLabels, context: CGContext, page: CGRect) throws {
        // A fixed light asset makes a printed report independent of app appearance.
        guard let logo = UIImage(named: AppBrandArtwork.onboardingMarkAssetName,
                                 in: .main, compatibleWith: UITraitCollection(userInterfaceStyle: .light))?.cgImage else {
            throw TransactionExportError.fileWrite
        }
        defer { context.closePDF() }
        let report = ReportLayout(bounds: page, labels: labels, snapshot: snapshot, logo: logo)
        let pages = try report.makePages()
        for (index, commands) in pages.enumerated() {
            try Task.checkCancellation()
            context.beginPDFPage(nil)
            context.setFillColor(Palette.paper)
            context.fill(page)
            for command in commands + report.footer(page: index + 1, total: pages.count) {
                try Task.checkCancellation()
                command.draw(in: context, pageHeight: page.height)
            }
            context.endPDFPage()
        }
    }

    /// Print colors deliberately do not follow the device's dark/light appearance.
    private enum Palette {
        static let paper = rgb(0xFFFFFF)
        static let ink = rgb(0x172337)
        static let muted = rgb(0x647184)
        static let blue = rgb(0x0879ED)
        static let surface = rgb(0xF2F6FB)
        static let rule = rgb(0xDFE6EF)
        static let green = rgb(0x18744C)
        static let amber = rgb(0x936000)
        static let red = rgb(0xAE4047)
        static func rgb(_ hex: UInt32) -> CGColor {
            CGColor(red: CGFloat((hex >> 16) & 255) / 255,
                    green: CGFloat((hex >> 8) & 255) / 255,
                    blue: CGFloat(hex & 255) / 255, alpha: 1)
        }
        static func status(_ value: String) -> CGColor {
            switch value {
            case "confirmed": green
            case "pending": amber
            case "failed": red
            default: muted
            }
        }
    }

    /// All layout uses top-left coordinates; only this drawing boundary flips to PDF space.
    private enum Command {
        case text(NSAttributedString, CGRect)
        case fill(CGRect, radius: CGFloat, CGColor)
        case outline(CGRect, radius: CGFloat)
        case image(CGImage, CGRect)

        func draw(in context: CGContext, pageHeight: CGFloat) {
            func flipped(_ rect: CGRect) -> CGRect {
                CGRect(x: rect.minX, y: pageHeight - rect.maxY, width: rect.width, height: rect.height)
            }
            context.saveGState()
            defer { context.restoreGState() }
            switch self {
            case let .text(value, rect):
                let frame = CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(value),
                    CFRange(location: 0, length: 0), CGPath(rect: flipped(rect), transform: nil), nil)
                CTFrameDraw(frame, context)
            case let .fill(rect, radius, color):
                context.setFillColor(color)
                context.addPath(CGPath(roundedRect: flipped(rect), cornerWidth: radius, cornerHeight: radius, transform: nil))
                context.fillPath()
            case let .outline(rect, radius):
                context.setStrokeColor(Palette.rule)
                context.setLineWidth(0.65)
                context.addPath(CGPath(roundedRect: flipped(rect), cornerWidth: radius, cornerHeight: radius, transform: nil))
                context.strokePath()
            case let .image(image, rect):
                context.addPath(CGPath(roundedRect: flipped(rect), cornerWidth: rect.width * 0.23,
                                      cornerHeight: rect.width * 0.23, transform: nil))
                context.clip()
                context.interpolationQuality = .high
                context.draw(image, in: flipped(rect))
            }
        }
    }

    private struct Field {
        var text: String
        var label: String? = nil
        var size: CGFloat = 9
        var bold = false
        var color = Palette.ink
        var identifier = false
        var badge = false
    }

    private struct Block {
        var fields: [Field]
        var spacing: CGFloat = 4
        var rule = false
        static var divider: Self { .init(fields: [], spacing: 6, rule: true) }
        static func value(_ label: String, _ text: String) -> Self {
            .init(fields: [.init(text: text, label: label, size: 8, identifier: true)])
        }
    }

    private final class ReportLayout {
        let bounds: CGRect
        let labels: TransactionExportLabels
        let snapshot: TransactionExportSnapshot
        let logo: CGImage
        let margin: CGFloat = 36
        let padding: CGFloat = 12
        let gap: CGFloat = 14
        let footerHeight: CGFloat
        let footerText: NSAttributedString
        let dateFormatter: DateFormatter
        let rangeFormatter: DateFormatter
        var pages: [[Command]] = []
        var top: CGFloat = 0
        var width: CGFloat { bounds.width - margin * 2 }
        var innerWidth: CGFloat { width - padding * 2 }
        var bodyBottom: CGFloat { bounds.height - 58 - footerHeight }
        var fullCardHeight: CGFloat { bodyBottom - 90 }

        init(bounds: CGRect, labels: TransactionExportLabels, snapshot: TransactionExportSnapshot, logo: CGImage) {
            self.bounds = bounds
            self.labels = labels
            self.snapshot = snapshot
            self.logo = logo
            // ICU's keyword syntax works for every supported language. The BCP-47
            // "en-u-nu-latn" form returns a nil date pattern on iOS 27.
            let locale = WalletAppLanguage.locale(for: labels.languageIdentifier)
            dateFormatter = DateFormatter()
            dateFormatter.locale = locale
            dateFormatter.calendar = Calendar(identifier: .gregorian)
            dateFormatter.timeZone = TimeZone(secondsFromGMT: 0)
            dateFormatter.setLocalizedDateFormatFromTemplate("d MMM yyyy HH:mm")
            rangeFormatter = DateFormatter()
            rangeFormatter.locale = locale
            rangeFormatter.calendar = Calendar(identifier: .gregorian)
            rangeFormatter.timeZone = .current
            rangeFormatter.setLocalizedDateFormatFromTemplate("d MMM yyyy")
            footerText = Self.attributed(labels["transaction_export.report_note"] + " " + labels["transaction_export.date_note"],
                                        size: 7.5, color: Palette.muted, rtl: labels.isRightToLeft)
            footerHeight = Self.height(footerText, width: bounds.width - 72)
        }

        func makePages() throws -> [[Command]] {
            newPage(first: true)
            for (index, record) in snapshot.records.enumerated() {
                try Task.checkCancellation()
                try addRecord(record, number: index + 1)
            }
            return pages
        }

        func newPage(first: Bool = false) {
            var commands: [Command] = []
            let logoSize: CGFloat = first ? 40 : 30
            let logoRect = logicalRect(x: 0, y: 30, width: logoSize, height: logoSize)
            commands.append(.image(logo, logoRect))
            let brand = attributed("Oath Wallet", size: first ? 17 : 13, bold: true)
            commands.append(.text(brand, logicalRect(x: logoSize + 11, y: first ? 31 : 29, width: width - logoSize - 11, height: 24)))
            let date = attributed(dateFormatter.string(from: snapshot.generatedAt) + " UTC", size: 8, color: Palette.muted)
            commands.append(.text(date, logicalRect(x: logoSize + 11, y: first ? 55 : 49, width: width - logoSize - 11, height: 14)))
            if first {
                top = 82
                let title = attributed(labels["transaction_export.title"], size: 28, bold: true)
                let titleHeight = Self.height(title, width: width)
                commands.append(.text(title, rect(y: top, height: titleHeight)))
                top += titleHeight + 4
                let subtitle = attributed(labels["transaction_export.subtitle"], size: 10, color: Palette.muted)
                let subtitleHeight = Self.height(subtitle, width: width)
                commands.append(.text(subtitle, rect(y: top, height: subtitleHeight)))
                top += subtitleHeight + 12
                let metrics = [
                    (String(snapshot.records.count), labels["transaction_export.entries"]),
                    (String(Set(snapshot.records.map(\.walletID)).count), labels["settings.section.wallets"]),
                    (String(Set(snapshot.records.map(\.networkID)).count), labels["network_fees.networks"])
                ]
                let cellWidth = (width - 32) / 3
                let labelHeight = metrics.map { Self.height(attributed($0.1, size: 9, color: Palette.muted), width: cellWidth - 14) }.max() ?? 14
                let summaryHeight = 42 + labelHeight
                commands.append(.fill(rect(y: top, height: summaryHeight), radius: 12, Palette.surface))
                for (index, metric) in metrics.enumerated() {
                    let x = 16 + CGFloat(index) * cellWidth
                    commands.append(.text(attributed(metric.0, size: 23, bold: true, color: index == 0 ? Palette.blue : Palette.ink),
                                          logicalRect(x: x, y: top + 9, width: cellWidth - 14, height: 30)))
                    commands.append(.text(attributed(metric.1, size: 9, color: Palette.muted),
                                          logicalRect(x: x, y: top + 35, width: cellWidth - 14, height: labelHeight)))
                }
                top += summaryHeight + 6
                let period = snapshot.filter.usesDateRange
                    ? rangeFormatter.string(from: snapshot.filter.startDate) + " - " + rangeFormatter.string(from: snapshot.filter.endDate)
                    : labels["transaction_export.all_time"]
                let scope = attributed(labels["transaction_export.date_range"] + ": " + period, size: 8.5, color: Palette.muted)
                let scopeHeight = Self.height(scope, width: width)
                commands.append(.text(scope, rect(y: top, height: scopeHeight)))
                top += scopeHeight + 10
            } else {
                // Compact continuation masthead leaves the page for transaction details.
                let title = attributed(labels["transaction_export.title"], size: 11, bold: true)
                let titleWidth = min(260, width * 0.52)
                commands.append(.text(title, logicalRect(x: width - titleWidth, y: 30, width: titleWidth, height: 32)))
                commands.append(.fill(rect(y: 76, height: 0.65), radius: 0, Palette.rule))
                top = 90
            }
            pages.append(commands)
        }

        func footer(page: Int, total: Int) -> [Command] {
            let y = bounds.height - 46 - footerHeight
            var commands: [Command] = [
                .fill(rect(y: y - 9, height: 0.65), radius: 0, Palette.rule),
                .text(footerText, rect(y: y, height: footerHeight))
            ]
            commands.append(.text(attributed("Oath Wallet", size: 8, bold: true, color: Palette.muted),
                                  logicalRect(x: 0, y: bounds.height - 29, width: width - 75, height: 14)))
            let pageText = Self.attributed(String(format: "%02d / %02d", page, total), size: 8,
                                           color: Palette.muted, rtl: !labels.isRightToLeft, identifier: true)
            commands.append(.text(pageText, logicalRect(x: width - 75, y: bounds.height - 29, width: 75, height: 14)))
            return commands
        }

        func blocks(for record: TransactionExportRecord) throws -> [Block] {
            guard let amount = ExactDecimalText.canonicalMagnitude(record.assetAmount) else { throw TransactionExportError.invalidRecord }
            let mutedAmount = ["failed", "canceled", "replaced", "notFound"].contains(record.status)
            var result: [Block] = [
                .init(fields: [.init(text: record.walletName, size: 10, color: Palette.muted)], spacing: 5),
                .init(fields: [
                    .init(text: amount + " " + record.assetSymbol, size: 23, bold: true,
                          color: mutedAmount ? Palette.muted : Palette.ink),
                    .init(text: labels[record.statusKey], label: labels[record.kindKey], size: 9,
                          bold: true, color: Palette.status(record.status), badge: true)
                ], spacing: 7),
                .divider,
                .value(labels["settings.wallets.details.address"], record.accountAddress),
                .value(labels["wallet.transaction.details.hash"], record.transactionHash)
            ]
            if let contract = record.contractAddress, !contract.isEmpty {
                result.append(.value(labels["wallet.transaction.details.contract"], contract))
            }
            var parties: [Field] = []
            if let from = record.fromAddress, !from.isEmpty {
                parties.append(.init(text: from, label: labels["wallet.transaction.details.from"], size: 8, identifier: true))
            }
            if let to = record.toAddress, !to.isEmpty {
                parties.append(.init(text: to, label: labels["wallet.transaction.details.to"], size: 8, identifier: true))
            }
            if !parties.isEmpty { result.append(.init(fields: parties, spacing: 6)) }
            if let replacement = record.replacementTransactionHash, !replacement.isEmpty {
                result.append(.value(labels["transaction_export.replacement"], replacement))
            }
            if let fee = record.networkFee {
                guard let exact = ExactDecimalText.canonicalMagnitude(fee) else { throw TransactionExportError.invalidRecord }
                result.append(.init(fields: [.init(text: exact + " " + (record.networkFeeSymbol ?? ""),
                    label: labels["transaction_export.recorded_fee"], size: 9)], spacing: 2))
            }
            if let note = record.note, !note.isEmpty {
                result.append(.divider)
                result.append(.init(fields: [.init(text: note, label: labels["wallet.transaction.details.notes.section"], size: 9)], spacing: 0))
            }
            return result
        }

        func addRecord(_ record: TransactionExportRecord, number: Int) throws {
            var remaining = try blocks(for: record)
            let headerHeight = recordHeader(record, number: number, y: 0).height
            let totalHeight = padding * 2 + headerHeight + remaining.reduce(0) { $0 + blockHeight($1) }
            // Ordinary cards stay intact. An oversized note/identifier flows into
            // framed continuations, each repeating the entry number/network/date.
            if totalHeight <= fullCardHeight, top + totalHeight > bodyBottom { newPage() }
            while !remaining.isEmpty {
                try Task.checkCancellation()
                let minimumBody = min(remaining.reduce(0) { $0 + blockHeight($1) }, 100)
                if bodyBottom - top < padding * 2 + headerHeight + minimumBody { newPage() }
                let start = top
                let header = recordHeader(record, number: number, y: start + padding)
                var content = header.commands
                var cursor = start + padding + header.height
                let bottom = bodyBottom - padding
                var placed = false
                while let block = remaining.first {
                    let height = blockHeight(block)
                    if cursor + height <= bottom {
                        content += draw(block, at: cursor)
                        cursor += height
                        remaining.removeFirst()
                        placed = true
                    } else if placed {
                        break
                    } else if block.fields.count > 1 {
                        remaining.removeFirst()
                        remaining.insert(contentsOf: block.fields.map { Block(fields: [$0], spacing: block.spacing) }, at: 0)
                    } else {
                        let (head, tail) = try split(block, available: bottom - cursor)
                        content += draw(head, at: cursor)
                        cursor += blockHeight(head)
                        remaining.removeFirst()
                        if let tail { remaining.insert(tail, at: 0) }
                        placed = true
                        break
                    }
                }
                guard placed else { throw TransactionExportError.fileWrite }
                let card = rect(y: start, height: cursor + padding - start)
                pages[pages.count - 1] += [.fill(card, radius: 12, Palette.paper), .outline(card, radius: 12)] + content
                top = card.maxY + 12
                if !remaining.isEmpty { newPage() }
            }
        }

        func recordHeader(_ record: TransactionExportRecord, number: Int, y: CGFloat) -> (commands: [Command], height: CGFloat) {
            let indexWidth: CGFloat = 44 // Fits the four-digit PDF limit without wrapping.
            let dateWidth: CGFloat = 180
            let nameWidth = innerWidth - indexWidth - dateWidth - gap
            let network = attributed(labels[record.networkNameKey], size: 11, bold: true)
            var dateText = dateFormatter.string(from: record.date) + " UTC"
            if record.timestamp == nil { dateText += " · " + labels["transaction_export.first_seen"] }
            let date = attributed(dateText, size: 8, color: Palette.muted)
            let height = max(22, max(Self.height(network, width: nameWidth), Self.height(date, width: dateWidth)))
            let indexRect = logicalRect(x: padding, y: y - 2, width: indexWidth - 7, height: 20)
            return ([
                .fill(indexRect, radius: 5, Palette.surface),
                .text(attributed("\(number).", size: 9, bold: true, color: Palette.blue),
                      logicalRect(x: padding + 4, y: y + 1, width: indexWidth - 15, height: 15)),
                .text(network, logicalRect(x: padding + indexWidth, y: y, width: nameWidth, height: height)),
                .text(date, logicalRect(x: width - padding - dateWidth, y: y, width: dateWidth, height: height))
            ], height + 4)
        }

        func fieldWidths(_ block: Block) -> [CGFloat] {
            if block.fields.count == 2, block.fields[1].badge {
                return [(innerWidth - gap) * 0.7, (innerWidth - gap) * 0.3]
            }
            return Array(repeating: (innerWidth - CGFloat(max(0, block.fields.count - 1)) * gap) / CGFloat(max(1, block.fields.count)), count: block.fields.count)
        }

        func fieldText(_ field: Field) -> NSAttributedString {
            attributed(field.text, size: field.size, bold: field.bold, color: field.color, identifier: field.identifier)
        }

        func labelHeight(_ field: Field, width: CGFloat) -> CGFloat {
            guard let label = field.label else { return 0 }
            return Self.height(attributed(label, size: 7.5, color: Palette.muted), width: width) + 1
        }

        func blockHeight(_ block: Block) -> CGFloat {
            if block.rule { return 0.65 + block.spacing }
            let heights = zip(block.fields, fieldWidths(block)).map { field, width in
                let inset: CGFloat = field.badge ? 7 : 0
                return inset * 2 + labelHeight(field, width: width - inset * 2)
                    + Self.height(fieldText(field), width: width - inset * 2)
            }
            return (heights.max() ?? 0) + block.spacing
        }

        func draw(_ block: Block, at y: CGFloat) -> [Command] {
            if block.rule {
                return [.fill(logicalRect(x: padding, y: y, width: innerWidth, height: 0.65), radius: 0, Palette.rule)]
            }
            var commands: [Command] = []
            var x = padding
            for (field, width) in zip(block.fields, fieldWidths(block)) {
                let inset: CGFloat = field.badge ? 7 : 0
                let textWidth = width - inset * 2
                let labelHeight = labelHeight(field, width: textWidth)
                let text = fieldText(field)
                let height = Self.height(text, width: textWidth)
                if field.badge {
                    commands.append(.fill(logicalRect(x: x, y: y, width: width, height: labelHeight + height + inset * 2), radius: 7, Palette.surface))
                }
                if let label = field.label {
                    commands.append(.text(attributed(label, size: 7.5, color: Palette.muted),
                                          logicalRect(x: x + inset, y: y + inset, width: textWidth, height: labelHeight)))
                }
                commands.append(.text(text, logicalRect(x: x + inset, y: y + inset + labelHeight, width: textWidth, height: height)))
                x += width + gap
            }
            return commands
        }

        func split(_ block: Block, available: CGFloat) throws -> (Block, Block?) {
            guard var field = block.fields.first, !block.rule else { throw TransactionExportError.fileWrite }
            // Badges and multi-column layouts have already become full-width fields.
            field.badge = false
            let valueHeight = available - labelHeight(field, width: innerWidth) - block.spacing - 4
            guard valueHeight > field.size * 1.5 else { throw TransactionExportError.fileWrite }
            let string = fieldText(field)
            let frame = CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(string),
                CFRange(location: 0, length: 0), CGPath(rect: CGRect(x: 0, y: 0, width: innerWidth, height: valueHeight), transform: nil), nil)
            let consumed = CTFrameGetVisibleStringRange(frame).length
            guard consumed > 0 else { throw TransactionExportError.fileWrite }
            var head = field
            head.text = (field.text as NSString).substring(to: consumed)
            let first = Block(fields: [head], spacing: block.spacing)
            guard consumed < string.length else { return (first, nil) }
            field.text = (field.text as NSString).substring(from: consumed)
            return (first, Block(fields: [field], spacing: block.spacing))
        }

        func rect(y: CGFloat, height: CGFloat) -> CGRect {
            CGRect(x: margin, y: y, width: width, height: height)
        }
        func logicalRect(x: CGFloat, y: CGFloat, width cellWidth: CGFloat, height: CGFloat) -> CGRect {
            CGRect(x: margin + (labels.isRightToLeft ? width - x - cellWidth : x), y: y, width: cellWidth, height: height)
        }
        func attributed(_ text: String, size: CGFloat, bold: Bool = false, color: CGColor = Palette.ink,
                        identifier: Bool = false) -> NSAttributedString {
            Self.attributed(text, size: size, bold: bold, color: color, rtl: labels.isRightToLeft, identifier: identifier)
        }
        static func height(_ text: NSAttributedString, width: CGFloat) -> CGFloat {
            guard text.length > 0 else { return 0 }
            let size = CTFramesetterSuggestFrameSizeWithConstraints(CTFramesetterCreateWithAttributedString(text),
                CFRange(location: 0, length: text.length), nil,
                CGSize(width: width, height: .greatestFiniteMagnitude), nil)
            return ceil(size.height) + 3
        }
        static func attributed(_ text: String, size: CGFloat, bold: Bool = false, color: CGColor,
                               rtl: Bool, identifier: Bool = false) -> NSAttributedString {
            let style = NSMutableParagraphStyle()
            style.lineBreakMode = identifier ? .byCharWrapping : .byWordWrapping
            style.baseWritingDirection = identifier ? .leftToRight : .natural
            style.alignment = rtl ? .right : .left
            style.lineSpacing = size >= 18 ? 1 : 1.5
            return NSAttributedString(string: text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName(
                    (identifier ? "Menlo-Regular" : (bold ? "HelveticaNeue-Bold" : "HelveticaNeue")) as CFString, size, nil),
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
                .paragraphStyle: style
            ])
        }
    }
}
