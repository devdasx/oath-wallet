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

/// BIP380 checksum. Algorithm specified by Bitcoin Core (MIT, Pieter Wuille).
enum BitcoinDescriptorChecksum {
    private static let input = Array("0123456789()[],'/*abcdefgh@:$%{}IJKLMNOPQRSTUVWXYZ&+-.;<=>?!^_|~ijklmnopqrstuvwxyzABCDEFGH`#\"\\ ".utf8)
    private static let output = Array("qpzry9x8gf2tvdw0s3jn54khce6mua7l".utf8)
    private static let generators: [UInt64] = [0xf5dee51989, 0xa9fdca3312, 0x1bab10e32d, 0x3706b1677a, 0x644d626ffd]

    static func checksum(_ body: String) throws -> String {
        var symbols: [UInt64] = []
        var groups: [UInt64] = []
        for byte in body.utf8 {
            guard let index = input.firstIndex(of: byte) else { throw BitcoinImportError.invalidDescriptor }
            symbols.append(UInt64(index & 31))
            groups.append(UInt64(index >> 5))
            if groups.count == 3 {
                symbols.append(groups[0] * 9 + groups[1] * 3 + groups[2])
                groups.removeAll(keepingCapacity: true)
            }
        }
        if groups.count == 1 { symbols.append(groups[0]) }
        if groups.count == 2 { symbols.append(groups[0] * 3 + groups[1]) }
        symbols.append(contentsOf: repeatElement(0, count: 8))
        var check: UInt64 = 1
        for symbol in symbols {
            let top = check >> 35
            check = ((check & 0x7ffffffff) << 5) ^ symbol
            for bit in 0..<5 where top & (1 << bit) != 0 { check ^= generators[bit] }
        }
        check ^= 1
        return String(decoding: (0..<8).map { output[Int((check >> (5 * (7 - $0))) & 31)] }, as: UTF8.self)
    }

    static func validatedBody(_ text: String) throws -> String {
        guard text.utf8.count <= 16_384 else { throw BitcoinImportError.invalidDescriptor }
        let parts = text.split(separator: "#", omittingEmptySubsequences: false)
        guard parts.count == 1 || parts.count == 2 else { throw BitcoinImportError.invalidDescriptor }
        let body = String(parts[0])
        let expected = try checksum(body)
        if parts.count == 2, String(parts[1]) != expected { throw BitcoinImportError.checksumMismatch }
        return body
    }
}
