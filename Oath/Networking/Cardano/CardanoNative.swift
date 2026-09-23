import Foundation
import WalletCore

/// Native ADA only. Token-bearing outputs are never selected by this implementation.
enum CardanoConstants {
    static let networkID = "cardano"
    static let databaseChainID = -1815
    static let decimals = 6
    static let nativeAssetID = "cardano:native"
    static let nativeSymbol = "ADA"
    static let derivationPath = "m/1852'/1815'/0'/0/0"
}

enum CardanoError: Error, Sendable {
    case invalidAddress, invalidResponse, incompleteSnapshot, insufficientFunds
    case tokenBearingFunds, invalidKey, invalidTransaction, minimumOutput, provider(Int)
}

enum CardanoAddress {
    static func validated(_ value: String) -> String? {
        let address = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard address.hasPrefix("addr1"), address == address.lowercased(),
              let decoded = AnyAddress(string: address, coin: .cardano),
              let header = decoded.data.first, header & 15 == 1,
              header >> 4 <= 7 else { return nil }
        return address
    }

    static func isKeyPaymentAddress(_ address: String) -> Bool {
        guard validated(address) == address,
              let header = AnyAddress(string: address, coin: .cardano)?.data.first else { return false }
        return ((header >> 4) & 1) == 0
    }

    static func material(wallet: HDWallet) throws -> WalletDerivedAccount {
        guard let key = wallet.getKey(coin: .cardano, derivationPath: CardanoConstants.derivationPath),
              key.data.count == 192 else { throw CardanoError.invalidKey }
        let address = CoinType.cardano.deriveAddress(privateKey: key)
        guard validated(address) != nil else { throw CardanoError.invalidAddress }
        return WalletDerivedAccount(networkID: CardanoConstants.networkID,
            address: address, normalizedAddress: address, label: "cardano-cip1852",
            derivationPath: CardanoConstants.derivationPath, accountIndex: 0,
            publicKey: key.getPublicKeyByType(pubkeyType: .ed25519Cardano).description)
    }
}

struct CardanoUTXO: Sendable, Equatable {
    let hash: String
    let index: UInt64
    let amount: UInt64
    let tokenCount: Int
    var id: String { "\(hash):\(index)" }
}

struct CardanoHistory: Sendable {
    let hash: String
    let delta: Int64
    let fee: UInt64
    let block: Int64
    let timestamp: Double
}

struct CardanoSnapshot: Sendable {
    let address: String
    let balance: UInt64
    let utxos: [CardanoUTXO]
    let history: [CardanoHistory]
}

struct CardanoProtocolParameters: Sendable {
    let feePerByte: UInt64
    let feeConstant: UInt64
    let coinsPerUTXOByte: UInt64
    let maxTransactionSize: Int
    let slot: UInt64
}

actor CardanoAPIClient {
    static let shared = CardanoAPIClient()
    private let session: URLSession
    init(session: URLSession = .shared) { self.session = session }

    private func get(_ url: URL) async throws -> Any {
        var request = URLRequest(url: url)
        request.timeoutInterval = 25
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw CardanoError.invalidResponse }
        guard response.statusCode == 200 else { throw CardanoError.provider(response.statusCode) }
        return try JSONSerialization.jsonObject(with: data)
    }

    private func adaStat(_ path: String, query: [URLQueryItem] = []) async throws -> [String: Any] {
        var url = URLComponents(string: "https://api.adastat.net/rest/v1/\(path).json")!
        url.queryItems = query.isEmpty ? nil : query
        guard let object = try await get(url.url!) as? [String: Any],
              object["code"] as? Int == 200 else { throw CardanoError.invalidResponse }
        return object
    }

    /// Complete, stable UTXO pages are mandatory; a partial read can never become a zero balance.
    func snapshot(address: String, includeHistory: Bool = true) async throws -> CardanoSnapshot {
        guard CardanoAddress.validated(address) == address else { throw CardanoError.invalidAddress }
        let pages = try await addressPages(address, kind: "utxos")
        let (balance, outputs) = try Self.reconcile(pages)
        var history: [CardanoHistory] = []
        if includeHistory {
            let pages = try await addressPages(address, kind: "history")
            var hashes = Set<String>()
            for page in pages {
                guard let rows = page["rows"] as? [[String: Any]] else { throw CardanoError.invalidResponse }
                for row in rows {
                    guard let hash = row["tx_hash"] as? String, Self.validHash(hash),
                          hashes.insert(hash).inserted,
                          let text = row["amount"] as? String, let delta = Int64(text),
                          let feeText = row["tx_fee"] as? String, let fee = UInt64(feeText),
                          let block = row["block_no"] as? Int64,
                          let time = row["time"] as? Double else { throw CardanoError.invalidResponse }
                    history.append(CardanoHistory(hash: hash, delta: delta, fee: fee, block: block, timestamp: time))
                }
            }
        }
        return CardanoSnapshot(address: address, balance: balance, utxos: outputs, history: history)
    }

    private func addressPages(_ address: String, kind: String) async throws -> [[String: Any]] {
        var result: [[String: Any]] = []
        var after: String?
        var cursors = Set<String>()
        for _ in 0..<100 {
            try Task.checkCancellation()
            var query = [URLQueryItem(name: "rows", value: kind), URLQueryItem(name: "limit", value: "100")]
            if let after { query.append(URLQueryItem(name: "after", value: after)) }
            let page = try await adaStat("addresses/\(address)", query: query)
            guard let summary = page["data"] as? [String: Any],
                  summary["address"] as? String == address else { throw CardanoError.invalidResponse }
            result.append(page)
            guard let cursor = page["cursor"] as? [String: Any], let next = cursor["next"] as? Bool else {
                throw CardanoError.incompleteSnapshot
            }
            if !next { return result }
            guard let value = cursor["after"] as? String, !value.isEmpty,
                  cursors.insert(value).inserted else { throw CardanoError.incompleteSnapshot }
            after = value
        }
        throw CardanoError.incompleteSnapshot
    }

    nonisolated static func validHash(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { $0.isHexDigit && $0.isASCII }
    }

    nonisolated static func reconcile(_ pages: [[String: Any]]) throws -> (UInt64, [CardanoUTXO]) {
        guard let last = pages.last, let cursor = last["cursor"] as? [String: Any],
              cursor["next"] as? Bool == false else { throw CardanoError.incompleteSnapshot }
        var expected: UInt64?
        var sum: UInt64 = 0
        var ids = Set<String>()
        var outputs: [CardanoUTXO] = []
        for page in pages {
            guard let data = page["data"] as? [String: Any],
                  let text = data["balance"] as? String, let balance = UInt64(text),
                  let rows = page["rows"] as? [[String: Any]] else { throw CardanoError.invalidResponse }
            if let expected, expected != balance { throw CardanoError.incompleteSnapshot }
            expected = balance
            for row in rows {
                guard let hash = row["tx_hash"] as? String, validHash(hash),
                      let index = row["tx_index"] as? UInt64, index <= UInt16.max,
                      let text = row["amount"] as? String, let amount = UInt64(text),
                      let tokens = row["token"] as? Int, tokens >= 0 else { throw CardanoError.invalidResponse }
                // An ADA-only send must positively establish that the output
                // has no native assets; missing token detail is not proof.
                if tokens == 0 {
                    guard let bundle = row["tokens"] as? [String: Any],
                          let assets = bundle["rows"] as? [[String: Any]], assets.isEmpty else {
                        throw CardanoError.invalidResponse
                    }
                }
                let output = CardanoUTXO(hash: hash, index: index, amount: amount, tokenCount: tokens)
                let addition = sum.addingReportingOverflow(amount)
                guard ids.insert(output.id).inserted, !addition.overflow else { throw CardanoError.incompleteSnapshot }
                sum = addition.partialValue
                outputs.append(output)
            }
        }
        guard expected == sum else { throw CardanoError.incompleteSnapshot }
        return (sum, outputs)
    }

    func parameters() async throws -> CardanoProtocolParameters {
        guard let rows = try await get(URL(string: "https://api.koios.rest/api/v1/epoch_params?order=epoch_no.desc&limit=1")!) as? [[String: Any]],
              let row = rows.first,
              let a = (row["min_fee_a"] as? NSNumber)?.uint64Value,
              let b = (row["min_fee_b"] as? NSNumber)?.uint64Value,
              let size = row["max_tx_size"] as? Int,
              let byteValue = row["coins_per_utxo_size"],
              let bytes = UInt64(String(describing: byteValue)), a > 0, b > 0, bytes > 0,
              size > 0, size <= 1_000_000 else { throw CardanoError.invalidResponse }
        let epoch = try await adaStat("epochs")
        guard let data = epoch["data"] as? [String: Any], let slot = data["slot_no"] as? UInt64 else {
            throw CardanoError.invalidResponse
        }
        return CardanoProtocolParameters(feePerByte: a, feeConstant: b, coinsPerUTXOByte: bytes,
                                         maxTransactionSize: size, slot: slot)
    }

    func submit(_ cbor: Data, expectedHash: String) async throws {
        guard Self.validHash(expectedHash), cbor.first == 0x84, cbor.count > 3 else {
            throw CardanoError.invalidTransaction
        }
        var request = URLRequest(url: URL(string: "https://api.koios.rest/api/v1/submittx")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/cbor", forHTTPHeaderField: "Content-Type")
        request.httpBody = cbor
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw CardanoError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else { throw CardanoError.provider(response.statusCode) }
        let hash = String(data: data, encoding: .utf8)?.trimmingCharacters(in: CharacterSet(charactersIn: "\" \r\n"))
        guard hash == expectedHash else { throw CardanoError.invalidResponse }
    }

    func confirmed(hash: String) async throws -> Bool {
        guard Self.validHash(hash) else { throw CardanoError.invalidTransaction }
        let response = try await adaStat("transactions/\(hash)")
        guard let data = response["data"] as? [String: Any], data["hash"] as? String == hash,
              let block = data["block_no"] as? Int else { throw CardanoError.invalidResponse }
        return block > 0
    }
}
