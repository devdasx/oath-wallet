import Foundation

enum BlockscoutHistoryError: Error, Equatable, Sendable {
    case configurationUnavailable
    case unsupportedNetwork(String)
    case invalidWalletAddress
    case invalidResponse(String)
    case requestRejected(Int)
}

/// Recent EVM activity from a Blockscout explorer, for mainnets the ANKR
/// Advanced API does not index. Requests go through the notification-service
/// proxy — the explorer's edge rejects non-browser clients — and are mapped to
/// the ANKR history models so synchronization, persistence and the
/// asset-details screen stay unchanged.
struct BlockscoutEVMHistoryClient: Sendable {
    static let networkIDs: Set<String> = [ArcNetworkConstants.networkID]
    static let pageSize = 50

    let networkID: String
    let endpoint: URL
    private let session: URLSession

    init(networkID: String, endpoint: URL, session: URLSession? = nil) {
        self.networkID = networkID
        self.endpoint = endpoint
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 20
            configuration.timeoutIntervalForResource = 60
            configuration.waitsForConnectivity = false
            self.session = URLSession(configuration: configuration)
        }
    }

    static func arc(
        session: URLSession? = nil,
        bundle: Bundle = .main,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> Self {
        let raw = environment["BLOCKSCOUT_ARC_PROXY_URL"]
            ?? bundle.object(forInfoDictionaryKey: "BlockscoutArcProxyURL")
                as? String
        guard let raw,
              let endpoint = Self.configuredURL(raw)
        else {
            throw BlockscoutHistoryError.configurationUnavailable
        }
        return Self(
            networkID: ArcNetworkConstants.networkID,
            endpoint: endpoint,
            session: session
        )
    }

    static func configuredURL(_ raw: String) -> URL? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              !value.contains("$("),
              let url = URL(string: value),
              let host = url.host, !host.isEmpty
        else {
            return nil
        }
        // A plain-HTTP proxy is only ever a local `wrangler dev` instance.
        let isLocal = host == "localhost" || host == "127.0.0.1"
        guard url.scheme == "https" || (url.scheme == "http" && isLocal) else {
            return nil
        }
        return url
    }

    func tokenTransfers(
        address: String,
        fromTimestamp: Int64?
    ) async throws -> AnkrTokenTransferResult {
        let wallet = try Self.normalizedAddress(address)
        let result: HistoryPaginationResult<AnkrTokenTransfer> =
            try await HistoryPaginator.collect(
                service: "BLOCKSCOUT",
                stream: "token_transfers",
                maximumPages: AnkrAPIClient.maximumHistoryPages,
                maximumItems: AnkrAPIClient.maximumRecentHistoryItems
            ) { cursor in
                let page: BlockscoutPage<BlockscoutTokenTransfer> =
                    try await self.page(
                        path: "addresses/\(wallet)/token-transfers",
                        queryItems: [URLQueryItem(name: "type", value: "ERC-20")],
                        cursor: cursor
                    )
                let mapped = page.items.compactMap {
                    Self.transfer($0, wallet: wallet, networkID: self.networkID)
                }
                return Self.historyPage(
                    mapped,
                    timestamps: mapped.compactMap(\.timestamp),
                    next: page.nextPageParams,
                    fromTimestamp: fromTimestamp
                )
            }
        return AnkrTokenTransferResult(
            transfers: result.items,
            nextPageToken: nil
        )
    }

    func nativeTransactions(
        address: String,
        fromTimestamp: Int64?
    ) async throws -> AnkrRawTransactionResult {
        let wallet = try Self.normalizedAddress(address)
        let result: HistoryPaginationResult<AnkrRawTransaction> =
            try await HistoryPaginator.collect(
                service: "BLOCKSCOUT",
                stream: "native_transactions",
                maximumPages: AnkrAPIClient.maximumHistoryPages,
                maximumItems: AnkrAPIClient.maximumRecentHistoryItems
            ) { cursor in
                let page: BlockscoutPage<BlockscoutTransaction> =
                    try await self.page(
                        path: "addresses/\(wallet)/transactions",
                        queryItems: [],
                        cursor: cursor
                    )
                let mapped = page.items.compactMap {
                    Self.transaction($0, networkID: self.networkID)
                }
                return Self.historyPage(
                    mapped,
                    timestamps: mapped.compactMap {
                        AnkrAPIClient.hexadecimalInt64($0.timestamp)
                    },
                    next: page.nextPageParams,
                    fromTimestamp: fromTimestamp
                )
            }
        return AnkrRawTransactionResult(
            transactions: result.items,
            nextPageToken: nil
        )
    }

    // MARK: - Transport

    private func page<Item: Decodable>(
        path: String,
        queryItems: [URLQueryItem],
        cursor: String?
    ) async throws -> BlockscoutPage<Item> {
        var components = URLComponents()
        components.path = path
        var items = queryItems
        if let cursor, !cursor.isEmpty {
            var cursorComponents = URLComponents()
            cursorComponents.percentEncodedQuery = cursor
            items.append(contentsOf: cursorComponents.queryItems ?? [])
        }
        components.queryItems = items.isEmpty ? nil : items
        guard let relative = components.url,
              let url = URL(string: relative.absoluteString, relativeTo: endpoint.appending(path: ""))?.absoluteURL
        else {
            throw BlockscoutHistoryError.invalidResponse("url")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw BlockscoutHistoryError.invalidResponse("response")
        }
        guard http.statusCode == 200 else {
            throw BlockscoutHistoryError.requestRejected(http.statusCode)
        }
        do {
            return try JSONDecoder().decode(BlockscoutPage<Item>.self, from: data)
        } catch {
            throw BlockscoutHistoryError.invalidResponse("decode")
        }
    }

    private static func historyPage<Item: Sendable>(
        _ items: [Item],
        timestamps: [Int64],
        next: [String: BlockscoutScalar]?,
        fromTimestamp: Int64?
    ) -> HistoryPage<Item, String> {
        var nextCursor = next.flatMap(Self.cursor)
        if let fromTimestamp,
           let oldest = timestamps.min(),
           oldest < fromTimestamp {
            // Blockscout pages newest-first: once a page reaches the cursor,
            // older pages hold nothing the refresh needs.
            nextCursor = nil
        }
        return HistoryPage(
            items: items,
            nextCursor: nextCursor,
            reportedItemCount: items.count
        )
    }

    static func cursor(_ params: [String: BlockscoutScalar]) -> String? {
        guard !params.isEmpty else { return nil }
        var components = URLComponents()
        components.queryItems = params.keys.sorted().map {
            URLQueryItem(name: $0, value: params[$0]?.queryValue)
        }
        return components.percentEncodedQuery
    }

    // MARK: - Mapping

    static func transaction(
        _ item: BlockscoutTransaction,
        networkID: String
    ) -> AnkrRawTransaction? {
        guard let timestamp = Self.unixTimestamp(item.timestamp),
              let value = Self.hexQuantity(decimal: item.value),
              let blockNumber = item.blockNumber
        else {
            return nil
        }
        let status: String
        switch item.status?.lowercased() {
        case "ok": status = "0x1"
        case "error": status = "0x0"
        default: return nil
        }
        return AnkrRawTransaction(
            blockHash: item.blockHash,
            blockNumber: Self.hexQuantity(blockNumber),
            from: item.from.hash,
            gas: item.gasLimit.flatMap(Self.hexQuantity(decimal:)),
            gasPrice: item.gasPrice.flatMap(Self.hexQuantity(decimal:)),
            gasUsed: item.gasUsed.flatMap(Self.hexQuantity(decimal:)),
            to: item.to?.hash,
            value: value,
            hash: item.hash,
            input: item.rawInput,
            nonce: item.nonce.map(Self.hexQuantity),
            status: status,
            blockchain: networkID,
            timestamp: Self.hexQuantity(timestamp),
            transactionIndex: item.position.map { Self.hexQuantity(Int64($0)) },
            type: item.type.map { Self.hexQuantity(Int64($0)) }
        )
    }

    static func transfer(
        _ item: BlockscoutTokenTransfer,
        wallet: String,
        networkID: String
    ) -> AnkrTokenTransfer? {
        guard let timestamp = Self.unixTimestamp(item.timestamp),
              let contract = (item.token.addressHash ?? item.token.address)?
                  .lowercased(),
              AnkrAPIClient.isValidAddress(contract),
              let rawValue = item.total?.value,
              rawValue.allSatisfy(\.isNumber),
              let decimals = item.token.decimals.flatMap({ Int($0) })
                  ?? item.total?.decimals.flatMap({ Int($0) })
        else {
            return nil
        }
        let to = item.to?.hash
        let direction = to?.lowercased() == wallet.lowercased() ? "in" : "out"
        return AnkrTokenTransfer(
            blockHeight: item.blockNumber,
            fromAddress: item.from.hash,
            toAddress: to,
            contractAddress: contract,
            value: nil,
            valueRawInteger: rawValue,
            blockchain: networkID,
            tokenName: item.token.name,
            tokenSymbol: item.token.symbol,
            tokenDecimals: decimals,
            thumbnail: item.token.iconURL,
            transactionHash: item.transactionHash,
            logIndex: item.logIndex,
            timestamp: timestamp,
            direction: direction
        )
    }

    static func normalizedAddress(_ address: String) throws -> String {
        let value = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard AnkrAPIClient.isValidAddress(value) else {
            throw BlockscoutHistoryError.invalidWalletAddress
        }
        return value.lowercased()
    }

    // ISO8601DateFormatter is documented thread-safe; the two instances are
    // shared read-only parsers.
    nonisolated(unsafe) private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    nonisolated(unsafe) private static let plainTimestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func unixTimestamp(_ value: String?) -> Int64? {
        guard let value else { return nil }
        let date = timestampFormatter.date(from: value)
            ?? plainTimestampFormatter.date(from: value)
        return date.map { Int64($0.timeIntervalSince1970.rounded(.down)) }
    }

    static func hexQuantity(_ value: Int64) -> String {
        "0x" + String(value, radix: 16)
    }

    /// Base-10 digit string to `0x` quantity without a bounded integer type;
    /// wallet values exceed `UInt64` (10¹⁸ USDC units × thousands).
    static func hexQuantity(decimal: String) -> String? {
        let digits = decimal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !digits.isEmpty, digits.allSatisfy(\.isNumber),
              digits.allSatisfy(\.isASCII)
        else {
            return nil
        }
        var number = digits.compactMap { $0.wholeNumberValue }
        var hex: [Character] = []
        while !(number.count == 1 && number[0] == 0) {
            var remainder = 0
            var quotient: [Int] = []
            for digit in number {
                let current = remainder * 10 + digit
                let q = current / 16
                remainder = current % 16
                if !quotient.isEmpty || q != 0 { quotient.append(q) }
            }
            hex.append(Character(String(remainder, radix: 16)))
            number = quotient.isEmpty ? [0] : quotient
        }
        return "0x" + (hex.isEmpty ? "0" : String(hex.reversed()))
    }

    /// `name()` / `symbol()` results: an ABI-encoded dynamic string, or the
    /// legacy `bytes32` form some older tokens still return.
    static func decodeABIString(_ hex: String) -> String? {
        let body = hex.hasPrefix("0x") ? String(hex.dropFirst(2)) : hex
        guard body.count % 2 == 0, !body.isEmpty else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(body.count / 2)
        var index = body.startIndex
        while index < body.endIndex {
            let next = body.index(index, offsetBy: 2)
            guard let byte = UInt8(body[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        func word(_ offset: Int) -> Int? {
            guard offset + 32 <= bytes.count else { return nil }
            var value = 0
            for byte in bytes[offset..<(offset + 32)] {
                guard value <= (Int.max >> 8) else { return nil }
                value = value << 8 | Int(byte)
            }
            return value
        }
        if bytes.count >= 64, let offset = word(0), offset == 32,
           let length = word(32), length <= bytes.count - 64 {
            return String(decoding: bytes[64..<(64 + length)], as: UTF8.self)
        }
        if bytes.count == 32 {
            return String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
        return nil
    }
}

// MARK: - Explorer models

struct BlockscoutPage<Item: Decodable>: Decodable {
    let items: [Item]
    let nextPageParams: [String: BlockscoutScalar]?

    private enum CodingKeys: String, CodingKey {
        case items
        case nextPageParams = "next_page_params"
    }
}

enum BlockscoutScalar: Decodable, Hashable, Sendable {
    case string(String)
    case integer(Int64)
    case boolean(Bool)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Bool.self) {
            self = .boolean(value)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    var queryValue: String {
        switch self {
        case let .string(value): value
        case let .integer(value): String(value)
        case let .boolean(value): value ? "true" : "false"
        }
    }
}

struct BlockscoutAddress: Decodable {
    let hash: String
}

struct BlockscoutTransaction: Decodable {
    let hash: String
    let from: BlockscoutAddress
    let to: BlockscoutAddress?
    let value: String
    let status: String?
    let timestamp: String?
    let blockNumber: Int64?
    let blockHash: String?
    let gasPrice: String?
    let gasUsed: String?
    let gasLimit: String?
    let nonce: Int64?
    let type: Int?
    let position: Int?
    let rawInput: String?

    private enum CodingKeys: String, CodingKey {
        case hash, from, to, value, status, timestamp, nonce, type, position
        case blockNumber = "block_number"
        case blockHash = "block_hash"
        case gasPrice = "gas_price"
        case gasUsed = "gas_used"
        case gasLimit = "gas_limit"
        case rawInput = "raw_input"
    }
}

struct BlockscoutToken: Decodable {
    let addressHash: String?
    let address: String?
    let name: String?
    let symbol: String?
    let decimals: String?
    let iconURL: String?
    let type: String?

    private enum CodingKeys: String, CodingKey {
        case address, name, symbol, decimals, type
        case addressHash = "address_hash"
        case iconURL = "icon_url"
    }
}

struct BlockscoutTotal: Decodable {
    let value: String?
    let decimals: String?
}

struct BlockscoutTokenTransfer: Decodable {
    let transactionHash: String
    let from: BlockscoutAddress
    let to: BlockscoutAddress?
    let token: BlockscoutToken
    let total: BlockscoutTotal?
    let logIndex: Int?
    let blockNumber: Int64?
    let timestamp: String?

    private enum CodingKeys: String, CodingKey {
        case from, to, token, total, timestamp
        case transactionHash = "transaction_hash"
        case logIndex = "log_index"
        case blockNumber = "block_number"
    }
}
