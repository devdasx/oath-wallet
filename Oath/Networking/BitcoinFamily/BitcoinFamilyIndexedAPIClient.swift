import Foundation

actor BitcoinFamilyIndexedAPIClient {
    static let shared = BitcoinFamilyIndexedAPIClient()
    private static let blockchairPageSize = 100
    private static let blockCypherPageSize = 2_000
    private static let maximumHistoryTransactions = 400

    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 6
        configuration.timeoutIntervalForResource = 8
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    private let spacedDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [
            .withInternetDateTime,
            .withSpaceBetweenDateAndTime
        ]
        return formatter
    }()

    private let internetDateFormatter = ISO8601DateFormatter()

    func snapshot(
        for material: BitcoinFamilyAccountMaterial
    ) async throws -> BitcoinFamilyChainSnapshot {
        let chainPath: String
        switch material.chain {
        case .bitcoin: chainPath = "bitcoin"
        case .bitcoinCash: chainPath = "bitcoin-cash"
        case .litecoin: chainPath = "litecoin"
        case .dogecoin: chainPath = "dogecoin"
        }
        let result: HistoryPaginationResult<
            BitcoinFamilyBlockchairDashboard
        > = try await HistoryPaginator.collect(
            service: "Bitcoin API",
            stream: "\(material.chain.symbol.lowercased())_blockchair",
            initialCursor: 0,
            maximumReportedItems: Self.maximumHistoryTransactions
        ) { offset in
            guard let offset else {
                throw BitcoinFamilyAPIError.invalidPagination
            }
            let dashboard = try await self.blockchairPage(
                material: material,
                chainPath: chainPath,
                offset: offset
            )
            return HistoryPage(
                items: [dashboard],
                nextCursor: Self.nextBlockchairOffset(
                    transactionCount: dashboard.transactions.count,
                    currentOffset: offset,
                    pageSize: Self.blockchairPageSize
                ),
                reportedItemCount: dashboard.transactions.count
            )
        }
        guard let firstDashboard = result.items.first else {
            throw BitcoinFamilyAPIError.invalidResponse
        }
        guard !firstDashboard.address.balance.isNegative else {
            throw BitcoinFamilyAPIError.invalidResponse
        }
        let transactions = result.items
            .flatMap(\.transactions)
            .prefix(Self.maximumHistoryTransactions)
        let history: [BitcoinFamilyHistoryEntry] =
            transactions.compactMap { transaction
                -> BitcoinFamilyHistoryEntry? in
            let change = transaction.balanceChange
            guard !change.isZero else { return nil }
            return BitcoinFamilyHistoryEntry(
                transactionHash: transaction.hash,
                height: transaction.blockID?.value ?? 0,
                amountAtomic: change.magnitude,
                feeAtomic: nil,
                direction: change.isPositive ? "incoming" : "outgoing",
                timestamp: timestamp(transaction.time)
            )
        }
        return BitcoinFamilyChainSnapshot(
            material: material,
            balanceAtomic: firstDashboard.address.balance,
            history: history
        )
    }

    func fallbackSnapshot(
        for material: BitcoinFamilyAccountMaterial
    ) async throws -> BitcoinFamilyChainSnapshot {
        let coinPath: String
        switch material.chain {
        case .bitcoin: coinPath = "btc"
        case .litecoin: coinPath = "ltc"
        case .dogecoin: coinPath = "doge"
        case .bitcoinCash:
            throw BitcoinFamilyAPIError.invalidResponse
        }
        let result: HistoryPaginationResult<
            BitcoinFamilyBlockCypherResponse
        > = try await HistoryPaginator.collect(
            service: "Bitcoin API",
            stream: "\(material.chain.symbol.lowercased())_blockcypher",
            maximumReportedItems: Self.maximumHistoryTransactions
        ) { before in
            let payload = try await self.blockCypherPage(
                material: material,
                coinPath: coinPath,
                before: before
            )
            return HistoryPage(
                items: [payload],
                nextCursor: try Self.nextBlockCypherCursor(
                    payload: payload
                ),
                reportedItemCount: payload.txrefs?.count ?? 0
            )
        }
        guard let firstPage = result.items.first else {
            throw BitcoinFamilyAPIError.invalidResponse
        }
        guard !firstPage.finalBalance.isNegative else {
            throw BitcoinFamilyAPIError.invalidResponse
        }
        let references = Self.boundedBlockCypherReferences(
            unconfirmed: firstPage.unconfirmedTxrefs ?? [],
            confirmed: result.items.flatMap { $0.txrefs ?? [] },
            maximumTransactions: Self.maximumHistoryTransactions
        )
        var grouped: [
            String: (
                change: BitcoinFamilyAtomicInteger,
                height: Int64,
                confirmed: String?
            )
        ] = [:]
        for reference in references {
            guard !reference.value.isNegative,
                  reference.inputIndex.value >= -1 else {
                throw BitcoinFamilyAPIError.invalidResponse
            }
            let signedValue = reference.inputIndex.value == -1
                ? reference.value
                : reference.value.negated
            var aggregate = grouped[reference.hash]
                ?? (
                    .zero,
                    reference.height.value,
                    reference.confirmed
                )
            aggregate.change = aggregate.change.adding(
                signedValue
            )
            if aggregate.height <= 0, reference.height.value > 0 {
                aggregate.height = reference.height.value
            }
            if aggregate.confirmed == nil {
                aggregate.confirmed = reference.confirmed
            }
            grouped[reference.hash] = aggregate
        }
        let history: [BitcoinFamilyHistoryEntry] = grouped.compactMap {
            element -> BitcoinFamilyHistoryEntry? in
            let (hash, aggregate) = element
            guard !aggregate.change.isZero else { return nil }
            return BitcoinFamilyHistoryEntry(
                transactionHash: hash,
                height: aggregate.height,
                amountAtomic: aggregate.change.magnitude,
                feeAtomic: nil,
                direction: aggregate.change.isPositive
                    ? "incoming"
                    : "outgoing",
                timestamp: timestamp(aggregate.confirmed)
            )
        }
        return BitcoinFamilyChainSnapshot(
            material: material,
            balanceAtomic: firstPage.finalBalance,
            history: history
        )
    }

    func transactionIdentity(
        chain: BitcoinFamilyChain,
        transactionHash: String,
        walletAddress: String,
        direction: String
    ) async throws -> BitcoinFamilyTransactionIdentity {
        let hash = transactionHash.lowercased()
        guard Self.isValidTransactionHash(hash),
              chain.coin.validate(address: walletAddress) else {
            throw BitcoinFamilyTransactionIdentityError.invalidRequest
        }
        let blockchairFailure: String
        do {
            let payload = try await blockchairTransactionDetails(
                chain: chain,
                transactionHash: hash
            )
            return try Self.transactionIdentity(
                blockchair: payload,
                chain: chain,
                transactionHash: hash,
                walletAddress: walletAddress,
                direction: direction
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            blockchairFailure =
                BitcoinFamilyErrorDiagnostics.description(for: error)
        }

        guard chain != .bitcoinCash else {
            throw BitcoinFamilyTransactionIdentityError.providersFailed(
                blockchair: blockchairFailure,
                blockCypher: "unsupported_chain"
            )
        }
        do {
            let payload = try await blockCypherTransactionDetails(
                chain: chain,
                transactionHash: hash
            )
            return try Self.transactionIdentity(
                blockCypher: payload,
                chain: chain,
                transactionHash: hash,
                walletAddress: walletAddress,
                direction: direction
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw BitcoinFamilyTransactionIdentityError.providersFailed(
                blockchair: blockchairFailure,
                blockCypher:
                    BitcoinFamilyErrorDiagnostics.description(for: error)
            )
        }
    }

    nonisolated static func transactionIdentity(
        blockchair payload:
            BitcoinFamilyBlockchairTransactionIdentityResponse,
        chain: BitcoinFamilyChain,
        transactionHash: String,
        walletAddress: String,
        direction: String
    ) throws -> BitcoinFamilyTransactionIdentity {
        guard let details = payload.data[transactionHash],
              details.transaction.hash.caseInsensitiveCompare(
                  transactionHash
              ) == .orderedSame else {
            throw BitcoinFamilyTransactionIdentityError.invalidResponse
        }
        return BitcoinFamilyTransactionIdentityMapper.identity(
            chain: chain,
            walletAddress: walletAddress,
            direction: direction,
            inputAddresses: details.inputs.compactMap(\.recipient),
            outputAddresses: details.outputs.compactMap(\.recipient)
        )
    }

    nonisolated static func transactionIdentity(
        blockCypher payload: BitcoinFamilyBlockCypherTransactionDetails,
        chain: BitcoinFamilyChain,
        transactionHash: String,
        walletAddress: String,
        direction: String
    ) throws -> BitcoinFamilyTransactionIdentity {
        guard payload.hash.caseInsensitiveCompare(transactionHash)
                == .orderedSame else {
            throw BitcoinFamilyTransactionIdentityError.invalidResponse
        }
        return BitcoinFamilyTransactionIdentityMapper.identity(
            chain: chain,
            walletAddress: walletAddress,
            direction: direction,
            inputAddresses: payload.inputs.flatMap { $0.addresses ?? [] },
            outputAddresses: payload.outputs.flatMap { $0.addresses ?? [] }
        )
    }

    nonisolated static func isValidTransactionHash(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }

    nonisolated static func nextBlockchairOffset(
        transactionCount: Int,
        currentOffset: Int,
        pageSize: Int
    ) -> Int? {
        guard transactionCount >= pageSize else { return nil }
        return currentOffset + transactionCount
    }

    nonisolated static func blockchairPaginationQueryItems(
        offset: Int
    ) -> [URLQueryItem] {
        [
            URLQueryItem(
                name: "limit",
                value: "\(blockchairPageSize),0"
            ),
            URLQueryItem(
                name: "offset",
                value: "\(offset),0"
            )
        ]
    }

    nonisolated static func nextBlockCypherCursor(
        payload: BitcoinFamilyBlockCypherResponse
    ) throws -> Int64? {
        // BlockCypher omits `hasMore` on a complete response, including the
        // valid zero-transaction response. Only an explicit true value means
        // another page is available.
        guard payload.hasMore == true else { return nil }
        guard let before = (payload.txrefs ?? [])
            .map(\.height.value)
            .filter({ $0 >= 0 })
            .min()
        else {
            throw BitcoinFamilyAPIError.invalidPagination
        }
        return before
    }

    nonisolated static func boundedBlockCypherReferences(
        unconfirmed: [BitcoinFamilyBlockCypherReference],
        confirmed: [BitcoinFamilyBlockCypherReference],
        maximumTransactions: Int
    ) -> [BitcoinFamilyBlockCypherReference] {
        guard maximumTransactions > 0 else { return [] }

        var selectedHashes = Set<String>()
        var orderedHashes: [String] = []
        orderedHashes.reserveCapacity(maximumTransactions)
        for reference in unconfirmed + confirmed {
            guard selectedHashes.insert(reference.hash).inserted else {
                continue
            }
            orderedHashes.append(reference.hash)
            if orderedHashes.count == maximumTransactions {
                break
            }
        }
        let retainedHashes = Set(orderedHashes)
        // Preserve every input/output reference for a selected transaction so
        // its net wallet change remains exact.
        return (unconfirmed + confirmed).filter {
            retainedHashes.contains($0.hash)
        }
    }

    nonisolated static func exactBlockchairDashboard(
        in payload: BitcoinFamilyBlockchairResponse,
        requestedAddress: String
    ) throws -> BitcoinFamilyBlockchairDashboard {
        guard !payload.data.isEmpty else {
            throw BitcoinFamilyAPIError.invalidResponse
        }
        guard let dashboard = payload.data[requestedAddress] else {
            throw BitcoinFamilyAPIError.blockchairAddressMismatch
        }
        return dashboard
    }

    private func blockchairPage(
        material: BitcoinFamilyAccountMaterial,
        chainPath: String,
        offset: Int
    ) async throws -> BitcoinFamilyBlockchairDashboard {
        guard var components = URLComponents(
            string:
                "https://api.blockchair.com/\(chainPath)/dashboards/address/\(material.address)"
        ) else {
            throw BitcoinFamilyAPIError.invalidResponse
        }
        components.queryItems = [
            URLQueryItem(name: "transaction_details", value: "true")
        ] + Self.blockchairPaginationQueryItems(offset: offset)
        let payload: BitcoinFamilyBlockchairResponse = try await request(
            components: components
        )
        do {
            let dashboard = try Self.exactBlockchairDashboard(
                in: payload,
                requestedAddress: material.address
            )
            return dashboard
        } catch {
            throw error
        }
    }

    private func blockchairTransactionDetails(
        chain: BitcoinFamilyChain,
        transactionHash: String
    ) async throws -> BitcoinFamilyBlockchairTransactionIdentityResponse {
        let chainPath: String = switch chain {
        case .bitcoin: "bitcoin"
        case .bitcoinCash: "bitcoin-cash"
        case .litecoin: "litecoin"
        case .dogecoin: "dogecoin"
        }
        guard let components = URLComponents(
            string:
                "https://api.blockchair.com/\(chainPath)/dashboards/transaction/\(transactionHash)"
        ) else {
            throw BitcoinFamilyTransactionIdentityError.invalidRequest
        }
        return try await request(components: components)
    }

    private func blockCypherTransactionDetails(
        chain: BitcoinFamilyChain,
        transactionHash: String
    ) async throws -> BitcoinFamilyBlockCypherTransactionDetails {
        let coinPath: String = switch chain {
        case .bitcoin: "btc"
        case .litecoin: "ltc"
        case .dogecoin: "doge"
        case .bitcoinCash:
            throw BitcoinFamilyTransactionIdentityError.invalidRequest
        }
        guard var components = URLComponents(
            string:
                "https://api.blockcypher.com/v1/\(coinPath)/main/txs/\(transactionHash)"
        ) else {
            throw BitcoinFamilyTransactionIdentityError.invalidRequest
        }
        components.queryItems = [
            URLQueryItem(name: "includeHex", value: "false")
        ]
        return try await request(components: components)
    }

    private func blockCypherPage(
        material: BitcoinFamilyAccountMaterial,
        coinPath: String,
        before: Int64?
    ) async throws -> BitcoinFamilyBlockCypherResponse {
        guard var components = URLComponents(
            string:
                "https://api.blockcypher.com/v1/\(coinPath)/main/addrs/\(material.address)"
        ) else {
            throw BitcoinFamilyAPIError.invalidResponse
        }
        var queryItems = [
            URLQueryItem(
                name: "limit",
                value: String(Self.blockCypherPageSize)
            ),
            URLQueryItem(name: "unspentOnly", value: "false"),
            URLQueryItem(name: "includeScript", value: "false")
        ]
        if let before {
            queryItems.append(
                URLQueryItem(name: "before", value: String(before))
            )
        }
        components.queryItems = queryItems
        return try await request(components: components)
    }

    private func request<Result>(
        components: URLComponents
    ) async throws -> Result where Result: Decodable & Sendable {
        guard let url = components.url else {
            throw BitcoinFamilyAPIError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 6
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw BitcoinFamilyAPIError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            throw BitcoinFamilyAPIError.httpFailure(http.statusCode)
        }
        let preservedData =
            BitcoinFamilyLosslessJSON.preservingNumberLexemes(in: data)
        return try JSONDecoder().decode(Result.self, from: preservedData)
    }

    private func timestamp(_ value: String?) -> Double? {
        guard let value else { return nil }
        if let date = spacedDateFormatter.date(from: value) {
            return date.timeIntervalSince1970
        }
        return internetDateFormatter.date(from: value)?.timeIntervalSince1970
    }
}
