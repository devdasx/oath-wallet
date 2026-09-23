import Foundation

/// Bitcoin's primary Electrum servers do not implement verbose transaction
/// lookup. Esplora's bounded txid-status response avoids an address-history scan
/// and works for HD, imported and Silent Payment transactions alike.
struct SendBitcoinExactStatus: Sendable {
    typealias Executor = @Sendable (URLRequest) async throws -> (Data, URLResponse)
    private let executor: Executor
    init(executor: Executor? = nil) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 10
        let session = URLSession(configuration: configuration)
        self.executor = executor ?? { try await session.data(for: $0) }
    }

    func status(hash: String) async throws -> SendTransactionNetworkStatus {
        guard SendTransactionStatusValidation.isHexHash(hash, byteCount: 32, allowsPrefix: false) else {
            throw SendTransactionStatusProviderError.invalidTransactionHash(networkID: "bitcoin")
        }
        let executor = executor
        let attempts = ["https://blockstream.info/api", "https://mempool.space/api"].enumerated().map { index, base in
            let url = URL(string: base + "/tx/" + hash.lowercased() + "/status")!
            return AdaptiveProviderAttempt<SendTransactionNetworkStatus>(endpoint: .init(
                serviceID: "bitcoin-exact-status", endpointURL: URL(string: base)!, baselinePriority: index)) {
                let (data, response) = try await executor(URLRequest(url: url))
                guard let http = response as? HTTPURLResponse else {
                    throw SendTransactionStatusProviderError.invalidResponse(networkID: "bitcoin", code: "not_http")
                }
                if http.statusCode == 404 { return .notFound }
                guard http.statusCode == 200 else {
                    throw SendTransactionStatusProviderError.invalidResponse(networkID: "bitcoin", code: "http_\(http.statusCode)")
                }
                guard data.count <= 16_384 else {
                    throw SendTransactionStatusProviderError.invalidResponse(networkID: "bitcoin", code: "status_size")
                }
                var value = try JSONDecoder().decode(Response.self, from: data)
                if !value.confirmed {
                    // Esplora returns {confirmed:false} for UNKNOWN hashes as
                    // well as mempool entries. Only the exact /tx response can
                    // establish that an unconfirmed payment still exists.
                    let transactionURL = URL(string: base + "/tx/" + hash.lowercased())!
                    let (transactionData, transactionResponse) = try await executor(URLRequest(url: transactionURL))
                    guard let transactionHTTP = transactionResponse as? HTTPURLResponse else {
                        throw SendTransactionStatusProviderError.invalidResponse(networkID: "bitcoin", code: "transaction_http")
                    }
                    if transactionHTTP.statusCode == 404 { return .notFound }
                    guard transactionHTTP.statusCode == 200, transactionData.count <= 8_388_608 else {
                        throw SendTransactionStatusProviderError.invalidResponse(networkID: "bitcoin", code: "transaction_read")
                    }
                    let transaction = try JSONDecoder().decode(Transaction.self, from: transactionData)
                    guard transaction.txid.lowercased() == hash.lowercased() else {
                        throw SendTransactionStatusProviderError.invalidResponse(networkID: "bitcoin", code: "transaction_identity")
                    }
                    value = transaction.status
                    if !value.confirmed { return .pending }
                }
                guard let height = value.block_height, height > 0,
                      let block = value.block_hash,
                      SendTransactionStatusValidation.isHexHash(block, byteCount: 32, allowsPrefix: false) else {
                    throw SendTransactionStatusProviderError.invalidResponse(networkID: "bitcoin", code: "confirmed_block")
                }
                return .confirmed
            }
        }
        return try await SendStatusReadResolver.resolve(attempts: attempts)
    }

    private struct Response: Decodable {
        let confirmed: Bool
        let block_height: Int64?
        let block_hash: String?
    }

    private struct Transaction: Decodable {
        let txid: String
        let status: Response
    }
}
