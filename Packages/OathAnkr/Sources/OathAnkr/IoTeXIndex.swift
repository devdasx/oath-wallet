import Foundation
import OathDiagnostics

/// IoTeXScan's address index has no stable log/trace IDs. It supplies transaction
/// candidates; RPC receipts and committed native logs supply the ledger movements.
enum IoTeXIndex {
    static let pageSize = 50
    static let permits = AnkrPermits(count: 1)

    static func rows(_ json: SolanaJSON) throws -> [SolanaJSON] {
        guard json["status"].text == "1", let rows = json["result"].array, rows.count <= pageSize else {
            if json["status"].text == "0", json["message"].string?.lowercased() == "no transactions found", json["result"].array?.isEmpty == true { return [] }
            throw OathDiagnostics.failure(AnkrError.invalidResponse, reason: "iotex_native_validation")
        }
        return rows
    }
    static func parameters(_ cursor: [String: SolanaJSON], history: Bool) throws -> (page: Int, end: Int64?) {
        guard Set(cursor.keys).isSubset(of: history ? ["page", "endblock"] : ["page", "type"]),
              let page = cursor["page"]?.text.flatMap(Int.init) ?? (cursor["page"] == nil ? 1 : nil), (1...20_000).contains(page) else { throw OathDiagnostics.failure(AnkrError.invalidResponse, reason: "iotex_native_validation") }
        let end = try cursor["endblock"].map { try IndexedEVMIdentity.height($0) }
        guard !history || cursor.isEmpty || end != nil else { throw OathDiagnostics.failure(AnkrError.invalidResponse, reason: "iotex_native_validation") }
        return (page, end)
    }
    static func inventory(_ json: SolanaJSON, page: Int) throws -> SolanaJSON {
        let rows = try rows(json)
        let items = try rows.map { row -> SolanaJSON in
            guard let address = row["TokenAddress"].string else { throw OathDiagnostics.failure(AnkrError.invalidResponse, reason: "iotex_native_validation") }
            // Decimals are read from the contract, not inferred from explorer labels.
            return .object(["token": .object(["type": .string("ERC-20"), "address_hash": .string(try IoTeXIdentity.ethereum(address)),
                "name": row["TokenName"], "symbol": row["TokenSymbol"]])])
        }
        return .object(["items": .array(items), "next_page_params": rows.count == pageSize ? .object(["page": .number(String(page + 1))]) : .null])
    }
    static func succeeded(_ receipt: SolanaJSON) throws -> Bool {
        // IoTeX exposes native receipt codes (101 out-of-gas, 106 reverted,
        // 200+ staking errors), not just Ethereum's binary status.
        guard let status = UInt64(try IndexedEVMIdentity.amount(receipt["status"])) else { throw AnkrError.invalidResponse }
        return status == 1
    }
    static func hash(_ row: SolanaJSON, stream: IndexedEVMHistoryStream) throws -> String {
        guard let text = row[stream == .internalTransactions ? "actionHash" : "hash"].string else { throw OathDiagnostics.failure(AnkrError.invalidResponse, reason: "iotex_native_validation") }
        let hash = text.hasPrefix("0x") ? text : "0x" + text
        guard AnkrQuantity.hash(hash) else { throw OathDiagnostics.failure(AnkrError.invalidResponse, reason: "iotex_native_validation") }; return hash.lowercased()
    }
    static func height(_ row: SolanaJSON, stream: IndexedEVMHistoryStream) throws -> Int64 {
        try IndexedEVMIdentity.height(row[stream == .internalTransactions ? "blockHeight" : "blockNumber"])
    }
    static func base(_ hash: String, receipt: SolanaJSON, block: SolanaJSON) throws -> [String: SolanaJSON] {
        let height = try IndexedEVMIdentity.height(receipt["blockNumber"])
        guard receipt["transactionHash"].string?.lowercased() == hash,
              receipt["blockHash"].string?.lowercased() == block["hash"].string?.lowercased(),
              height == (try IndexedEVMIdentity.height(block["number"])) else { throw OathDiagnostics.failure(AnkrError.invalidResponse, reason: "iotex_native_validation") }
        let seconds = try IndexedEVMIdentity.height(block["timestamp"])
        guard seconds < 1_000_000_000_000 else { throw OathDiagnostics.failure(AnkrError.invalidResponse, reason: "iotex_native_validation") }
        return ["transaction_hash": .string(hash), "block_number": .number(String(height)),
                "timestamp": .string(ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: Double(seconds))))]
    }
    static func transfers(hash: String, receipt: SolanaJSON, block: SolanaJSON, owner: String) throws -> [SolanaJSON] {
        let base = try base(hash, receipt: receipt, block: block)
        guard let logs = receipt["logs"].array, logs.count <= 10_000 else { throw OathDiagnostics.failure(AnkrError.invalidResponse, reason: "iotex_native_validation") }
        if try !succeeded(receipt) { return [] }
        return try logs.enumerated().compactMap { offset, log in
            guard let topics = log["topics"].array else { throw OathDiagnostics.failure(AnkrError.invalidResponse, reason: "iotex_native_validation") }
            // Three topics and a single uint256 distinguish ERC-20 from ERC-721.
            guard topics.count == 3, topics[0].string == "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef",
                  let data = log["data"].string, data.count == 66 else { return nil }
            func account(_ word: SolanaJSON) throws -> String {
                guard let text = word.string, text.count == 66, text.hasPrefix("0x" + String(repeating: "0", count: 24)) else { throw OathDiagnostics.failure(AnkrError.invalidResponse, reason: "iotex_native_validation") }
                return try IndexedEVMIdentity.address("0x" + text.suffix(40))
            }
            let from = try account(topics[1]), to = try account(topics[2])
            guard from == owner || to == owner else { return nil }
            guard log["removed"] != .bool(true), log["transactionHash"].string?.lowercased() == hash,
                  log["blockHash"].string?.lowercased() == receipt["blockHash"].string?.lowercased(),
                  try IndexedEVMIdentity.height(log["blockNumber"]) == IndexedEVMIdentity.height(receipt["blockNumber"]),
                  let contract = log["address"].string else { throw OathDiagnostics.failure(AnkrError.invalidResponse, reason: "iotex_native_validation") }
            // Older IoTeX receipts repeat logIndex = 0. Receipt order is stable
            // and identifies every event, even when an index page splits a receipt.
            let index = String(offset)
            var value = base
            value["from"] = .object(["hash": .string(from)]); value["to"] = .object(["hash": .string(to)])
            value["log_index"] = .string(index)
            value["token"] = .object(["type": .string("ERC-20"), "address_hash": .string(try IndexedEVMIdentity.address(contract))])
            value["total"] = .object(["value": .string(try IndexedEVMIdentity.amount(log["data"]))])
            return .object(value)
        }
    }
}
