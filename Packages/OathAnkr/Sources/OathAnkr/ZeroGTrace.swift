import Foundation

/// The ChainScan trace proxy retains CIP-37 address encoding and paired call
/// results. These addresses are provider data, never a wallet receive format.
enum ZeroGTrace {
    static func address(_ text: String) throws -> String {
        guard text == text.lowercased() || text == text.uppercased() else { throw AnkrError.invalidResponse }
        let parts = text.lowercased().split(separator: ":")
        guard parts.count == 2, parts[0] == "net16661", parts[1].count == 42 else { throw AnkrError.invalidResponse }
        let alphabet = Array("abcdefghjkmnprstuvwxyz0123456789".utf8)
        let words = try parts[1].utf8.map { char -> UInt8 in
            guard let index = alphabet.firstIndex(of: char) else { throw AnkrError.invalidResponse }
            return UInt8(index)
        }
        var check: UInt64 = 1
        let generators: [UInt64] = [0x98f2bc8e61,0x79b76d99e2,0xf33e5fb3c4,0xae2eabe2a8,0x1e4f43e470]
        for value in Array(parts[0].utf8.map { $0 & 31 }) + [0] + words {
            let top = check >> 35; check = ((check & 0x07ffffffff) << 5) ^ UInt64(value)
            for bit in 0..<5 where top & (1 << bit) != 0 { check ^= generators[bit] }
        }
        guard check == 1 else { throw AnkrError.invalidResponse }
        var bytes: [UInt8] = [], buffer = 0, bits = 0
        for value in words.prefix(34) {
            buffer = ((buffer << 5) | Int(value)) & 0xffff; bits += 5
            if bits >= 8 { bits -= 8; bytes.append(UInt8((buffer >> bits) & 255)) }
        }
        guard bytes.count == 21, bytes[0] == 0, bits == 2, buffer & 3 == 0 else { throw AnkrError.invalidResponse }
        return "0x" + bytes.dropFirst().map { String(format: "%02x", $0) }.joined()
    }
    static func corroborate(_ row: SolanaJSON, traces: SolanaJSON, receipt: SolanaJSON) throws -> Bool {
        guard let records = traces.array, !records.isEmpty, records.count <= 10_000,
              let index = row["index"].text.flatMap(Int.init), records.indices.contains(index), index > 0 else { throw AnkrError.invalidResponse }
        var stack: [Int] = [], parents: [Int: Int] = [:], success: [Int: Bool] = [:], results: [Int: SolanaJSON] = [:]
        for (i, record) in records.enumerated() {
            guard record["transactionHash"].string?.lowercased() == row["transaction_hash"].string?.lowercased(),
                  record["blockHash"].string?.lowercased() == receipt["blockHash"].string?.lowercased(),
                  try IndexedEVMIdentity.height(record["epochNumber"]) == IndexedEVMIdentity.height(receipt["blockNumber"]),
                  case .bool(let valid) = record["valid"] else { throw AnkrError.invalidResponse }
            switch record["type"].string {
            case "call", "create":
                if let parent = stack.last { parents[i] = parent } else if i != 0 { throw AnkrError.invalidResponse }
                stack.append(i); success[i] = valid
            case "call_result", "create_result":
                guard let call = stack.popLast(), record["type"].string == records[call]["type"].string! + "_result",
                      let outcome = record["action"]["outcome"].string, ["success", "fail", "revert"].contains(outcome) else { throw AnkrError.invalidResponse }
                success[call] = success[call] == true && valid && outcome == "success"
                results[call] = record["action"]
            default: throw AnkrError.invalidResponse
            }
        }
        guard stack.isEmpty, let ownSuccess = success[index] else { throw AnkrError.invalidResponse }
        let trace = records[index], action = trace["action"]
        guard action["space"].string == "evm", let from = action["from"].string,
              try address(from) == row["from"]["hash"].string?.lowercased(),
              try IndexedEVMIdentity.amount(action["value"]) == IndexedEVMIdentity.amount(row["value"]) else { throw AnkrError.invalidResponse }
        let destination: String?
        if trace["type"].string == "call" {
            guard action["callType"].string == "call" else { throw AnkrError.invalidResponse }
            destination = action["to"].string
        } else { destination = results[index]?["addr"].string }
        guard let destination, try address(destination) == row["to"]["hash"].string?.lowercased() else { throw AnkrError.invalidResponse }
        var valid = ownSuccess, current = index
        while let parent = parents[current] { valid = valid && success[parent] == true; current = parent }
        return valid
    }
}
