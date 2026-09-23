/*
Copyright (c) 2009-2024 The Bitcoin Core developers

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
*/

import Foundation

/// Read-only Bitcoin Core BDB backup decoder. No database connection or disk writes.
/// Layout/validation based on Bitcoin Core src/wallet/migrate.cpp,
/// Copyright (c) 2024-present Bitcoin Core developers, MIT license.
struct BitcoinBerkeleyBackupReader {
    private let bytes: BitcoinBackupBytes
    private let pageSize: Int
    private let lastPage: Int
    private let bigEndian: Bool

    init(data: Data) throws {
        guard data.count <= 64 * 1024 * 1024, data.count >= 512 else {
            throw BitcoinImportError.invalidFile
        }
        bytes = BitcoinBackupBytes(data)
        let magic = try bytes.integer(at: 12, count: 4)
        guard magic == 0x00053162 || magic == 0x62310500 else {
            throw BitcoinImportError.unsupportedDatabase
        }
        bigEndian = magic == 0x62310500
        pageSize = Int(try bytes.integer(at: 20, count: 4, bigEndian: bigEndian))
        guard (512...65536).contains(pageSize), pageSize.nonzeroBitCount == 1 else {
            throw BitcoinImportError.invalidFile
        }
        lastPage = Int(try bytes.integer(at: 32, count: 4, bigEndian: bigEndian))
        guard data.count.isMultiple(of: pageSize), lastPage == data.count / pageSize - 1 else { throw BitcoinImportError.incompleteBackup }
        for index in 0...lastPage {
            let base = index * pageSize
            guard try number(base, 4) == 0, try number(base + 4, 4) == 1 else {
                throw BitcoinImportError.incompleteBackup
            }
        }
        _ = try metadata(0)
    }

    func records() throws -> [BitcoinBackupRecord] {
        let outer = try metadata(0)
        let root = try page(outer)
        guard root.type == 5, root.entries == 2 else { throw BitcoinImportError.invalidFile }
        let outerRecords = try leaf(root)
        guard outerRecords.count == 2, outerRecords[0] == Data("main".utf8),
              let pointer = outerRecords[1], pointer.count == 4 else { throw BitcoinImportError.invalidFile }
        let main = Int(try BitcoinBackupBytes(pointer).integer(at: 0, count: 4, bigEndian: true))
        let inner = try metadata(main)
        let innerPage = try page(inner)
        var pending = [(inner, innerPage.level)]
        var visited = Set<Int>()
        var records: [BitcoinBackupRecord] = []
        var keys = Set<Data>()
        while let (index, level) = pending.popLast() {
            try Task.checkCancellation()
            guard visited.insert(index).inserted else { throw BitcoinImportError.invalidFile }
            let current = try page(index)
            guard current.level == level else { throw BitcoinImportError.invalidFile }
            switch current.type {
            case 3:
                guard level > 1 else { throw BitcoinImportError.invalidFile }
                for offset in try indexes(current) {
                    let kind = try number(offset + 2, 1)
                    guard kind & 0x7f == 1 else { throw BitcoinImportError.invalidFile }
                    if kind & 0x80 != 0 { continue }
                    let length = Int(try number(offset, 2))
                    guard offset + 12 + length <= current.end else { throw BitcoinImportError.invalidFile }
                    pending.append((Int(try number(offset + 4, 4)), level - 1))
                }
            case 5:
                guard level == 1, current.entries.isMultiple(of: 2) else {
                    throw BitcoinImportError.invalidFile
                }
                let values = try leaf(current)
                for index in stride(from: 0, to: values.count, by: 2) {
                    guard let key = values[index], let value = values[index + 1] else {
                        guard values[index] == nil, values[index + 1] == nil else {
                            throw BitcoinImportError.invalidFile
                        }
                        continue
                    }
                    guard keys.insert(key).inserted, records.count < 500_000 else {
                        throw BitcoinImportError.invalidFile
                    }
                    records.append(.init(key: key, value: value))
                }
            default: throw BitcoinImportError.invalidFile
            }
        }
        return records
    }

    private struct Page {
        let start: Int
        let end: Int
        let entries: Int
        let level: Int
        let type: Int
    }

    private func number(_ offset: Int, _ count: Int) throws -> UInt64 {
        try bytes.integer(at: offset, count: count, bigEndian: bigEndian)
    }

    private func start(_ index: Int) throws -> Int {
        guard (0...lastPage).contains(index) else { throw BitcoinImportError.invalidFile }
        return index * pageSize
    }

    private func metadata(_ index: Int) throws -> Int {
        let base = try start(index)
        guard try number(base + 8, 4) == index,
              try number(base + 12, 4) == 0x00053162,
              try number(base + 16, 4) == 9,
              try number(base + 20, 4) == pageSize,
              try number(base + 25, 1) == 9,
              try number(base + 48, 4) == 0x20 else { throw BitcoinImportError.invalidFile }
        guard try number(base + 24, 1) == 0 else { throw BitcoinImportError.unsupportedEncryption }
        return Int(try number(base + 88, 4))
    }

    private func page(_ index: Int) throws -> Page {
        let base = try start(index)
        guard try number(base + 8, 4) == index else { throw BitcoinImportError.invalidFile }
        let result = Page(start: base, end: base + pageSize,
                          entries: Int(try number(base + 20, 2)),
                          level: Int(try number(base + 24, 1)), type: Int(try number(base + 25, 1)))
        guard result.type == 7 ? result.level == 0 : result.level >= 1 else {
            throw BitcoinImportError.invalidFile
        }
        return result
    }

    private func indexes(_ page: Page) throws -> [Int] {
        let end = page.start + 26 + page.entries * 2
        guard end <= page.end else { throw BitcoinImportError.invalidFile }
        return try (0..<page.entries).map {
            let offset = page.start + Int(try number(page.start + 26 + $0 * 2, 2))
            guard offset >= end, offset + 3 <= page.end else { throw BitcoinImportError.invalidFile }
            return offset
        }
    }

    private func leaf(_ page: Page) throws -> [Data?] {
        try indexes(page).map { offset in
            let kind = try number(offset + 2, 1)
            if kind & 0x80 != 0 { return nil }
            switch kind & 0x7f {
            case 1:
                let length = Int(try number(offset, 2))
                guard offset + 3 + length <= page.end else { throw BitcoinImportError.invalidFile }
                return try bytes.slice(at: offset + 3, count: length)
            case 3:
                guard offset + 12 <= page.end else { throw BitcoinImportError.invalidFile }
                return try overflow(Int(number(offset + 4, 4)), length: Int(number(offset + 8, 4)))
            default: throw BitcoinImportError.invalidFile
            }
        }
    }

    private func overflow(_ first: Int, length: Int) throws -> Data {
        guard length <= bytes.data.count else { throw BitcoinImportError.invalidFile }
        var index = first
        var visited = Set<Int>()
        var result = Data()
        while index != 0 {
            guard visited.insert(index).inserted else { throw BitcoinImportError.invalidFile }
            let current = try page(index)
            guard current.type == 7 else { throw BitcoinImportError.invalidFile }
            let count = Int(try number(current.start + 22, 2))
            guard count <= pageSize - 26, count <= length - result.count else {
                throw BitcoinImportError.invalidFile
            }
            result.append(try bytes.slice(at: current.start + 26, count: count))
            index = Int(try number(current.start + 16, 4))
        }
        guard result.count == length else { throw BitcoinImportError.incompleteBackup }
        return result
    }
}
