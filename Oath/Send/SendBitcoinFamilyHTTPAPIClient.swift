import Foundation

protocol SendBitcoinFamilyTransactionBroadcasting: Sendable {
    func broadcast(
        chain: BitcoinFamilyChain,
        rawTransactionHex: String,
        expectedTransactionID: String
    ) async throws -> SendBitcoinFamilyBroadcastResult
}

struct SendBitcoinFamilyBroadcastResult: Equatable, Sendable {
    let transactionID: String
    let wasAlreadyKnown: Bool
}

enum SendBitcoinFamilyHTTPBroadcastError: Error, Equatable, Sendable {
    case notAttempted(provider: String, code: String)
    case rejected(provider: String, code: String, message: String)
    case outcomeUnknown(provider: String, code: String)

    var diagnosticCode: String {
        switch self {
        case let .notAttempted(provider, code):
            "not_attempted_\(provider)_\(code)"
        case let .rejected(provider, code, _):
            "rejected_\(provider)_\(code)"
        case let .outcomeUnknown(provider, code):
            "unknown_\(provider)_\(code)"
        }
    }
}

/// Keyless HTTPS fee and transaction-broadcast client for Bitcoin-family
/// mainnets. Electrum remains the wallet's address, history, and UTXO source;
/// fee discovery and signed-transaction submission intentionally do not use
/// the Electrum transport.
struct SendBitcoinFamilyHTTPAPIClient:
    Sendable,
    SendBitcoinFamilyTransactionBroadcasting {
    static let shared = SendBitcoinFamilyHTTPAPIClient()

    private static let maximumFeeResponseBytes = 1_048_576
    private static let maximumBroadcastResponseBytes = 1_048_576
    private static let posix = Locale(identifier: "en_US_POSIX")

    private let requestExecutor:
        @Sendable (URLRequest) async throws -> (Data, URLResponse)

    init(session: URLSession? = nil) {
        let resolvedSession: URLSession
        if let session {
            resolvedSession = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.urlCache = nil
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            configuration.timeoutIntervalForRequest = 10
            configuration.timeoutIntervalForResource = 14
            resolvedSession = URLSession(configuration: configuration)
        }
        requestExecutor = { request in
            try await resolvedSession.data(for: request)
        }
    }

    init(
        requestExecutor: @escaping @Sendable (URLRequest) async throws
            -> (Data, URLResponse)
    ) {
        self.requestExecutor = requestExecutor
    }

    static func quote(
        for chain: BitcoinFamilyChain,
        client: SendBitcoinFamilyHTTPAPIClient = .shared,
        now: Date = Date()
    ) async throws -> SendNetworkFeeQuote {
        try await client.quote(for: chain, now: now)
    }

    func quote(
        for chain: BitcoinFamilyChain,
        now: Date = Date()
    ) async throws -> SendNetworkFeeQuote {
        do {
            return try await primaryQuote(for: chain, now: now)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return try await secondaryQuote(for: chain, now: now)
        }
    }

    func broadcast(
        chain: BitcoinFamilyChain,
        rawTransactionHex: String,
        expectedTransactionID: String
    ) async throws -> SendBitcoinFamilyBroadcastResult {
        let normalizedID = expectedTransactionID
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard Self.isTransactionID(normalizedID) else {
            throw SendBitcoinFamilyHTTPBroadcastError.notAttempted(
                provider: "local",
                code: "invalid_transaction_id"
            )
        }
        guard !rawTransactionHex.isEmpty,
              rawTransactionHex.utf8.allSatisfy(Self.isASCIIHexByte),
              rawTransactionHex.utf8.count.isMultiple(of: 2) else {
            throw SendBitcoinFamilyHTTPBroadcastError.notAttempted(
                provider: "local",
                code: "invalid_transaction_hex"
            )
        }

        var attempted = false
        var lastProvider = "none"
        var lastCode = "no_provider"
        for provider in Self.broadcastProviders(for: chain) {
            if Task.isCancelled {
                if attempted {
                    throw SendBitcoinFamilyHTTPBroadcastError.outcomeUnknown(
                        provider: lastProvider,
                        code: "cancelled_after_attempt"
                    )
                }
                throw CancellationError()
            }
            attempted = true
            lastProvider = provider.name
            let outcome = await broadcastAttempt(
                provider: provider,
                rawTransactionHex: rawTransactionHex,
                expectedTransactionID: normalizedID
            )
            switch outcome {
            case let .success(transactionID, wasAlreadyKnown):
                return SendBitcoinFamilyBroadcastResult(
                    transactionID: transactionID,
                    wasAlreadyKnown: wasAlreadyKnown
                )
            case let .rejected(code, message):
                throw SendBitcoinFamilyHTTPBroadcastError.rejected(
                    provider: provider.name,
                    code: code,
                    message: message
                )
            case let .ambiguous(code):
                lastCode = code
            }
        }
        guard attempted else {
            throw SendBitcoinFamilyHTTPBroadcastError.notAttempted(
                provider: lastProvider,
                code: lastCode
            )
        }
        throw SendBitcoinFamilyHTTPBroadcastError.outcomeUnknown(
            provider: lastProvider,
            code: lastCode
        )
    }

    static func atomicPerVByte(
        coinPerKilobyte: Decimal
    ) throws -> UInt64 {
        guard coinPerKilobyte > 0 else {
            throw SendNetworkFeeAPIError.invalidResponse(
                "http_fee_non_positive"
            )
        }
        // Each supported family coin has 1e8 atomic units. Provider values
        // expressed in coin/kB therefore become atomic/vB by multiplying by
        // 100,000. Rounding up avoids silently underpaying relay policy.
        var atomicPerByte = coinPerKilobyte * 100_000
        var rounded = Decimal()
        NSDecimalRound(&rounded, &atomicPerByte, 0, .up)
        let text = NSDecimalNumber(decimal: rounded).stringValue
        guard let value = UInt64(text), value > 0 else {
            throw SendNetworkFeeAPIError.invalidResponse(
                "http_fee_out_of_range"
            )
        }
        return value
    }

    static func isAlreadyKnownMessage(_ message: String) -> Bool {
        let normalized = message.lowercased()
        return normalized.contains("txn-already-known")
            || normalized.contains("already known")
            || normalized.contains("already in block chain")
            || normalized.contains("already in the block chain")
            || normalized.contains("already in blockchain")
            || normalized.contains("already in the blockchain")
            || normalized.contains("already in mempool")
            || normalized.contains("txn-already-in-mempool")
    }

    static func isDefinitiveRejectionMessage(_ message: String) -> Bool {
        let normalized = message.lowercased()
        if normalized.contains("missing inputs")
            || normalized.contains("inputs missing or spent")
            || normalized.contains("inputs-missingorspent") {
            // A previous provider may have accepted the exact transaction
            // before its response was lost, making this result ambiguous.
            return false
        }
        return [
            "mandatory-script-verify-flag-failed",
            "non-mandatory-script-verify-flag",
            "script verification failed",
            "transaction decode failed",
            "decode failed",
            "nonstandard transaction",
            "non-standard transaction",
            "min relay fee not met",
            "mempool min fee not met",
            "dust",
            "absurdly-high-fee",
            "too-long-mempool-chain",
            "bad-txns-vout-negative",
            "bad-txns-vout-toolarge",
            "bad-txns-txouttotal-toolarge"
        ].contains { normalized.contains($0) }
    }

    private func primaryQuote(
        for chain: BitcoinFamilyChain,
        now: Date
    ) async throws -> SendNetworkFeeQuote {
        switch chain {
        case .bitcoin:
            return try await recommendedFeeQuote(
                chain: chain,
                provider: "mempool_space",
                endpoint: "https://mempool.space/api/v1/fees/recommended",
                now: now
            )
        case .litecoin:
            return try await recommendedFeeQuote(
                chain: chain,
                provider: "litecoinspace",
                endpoint: "https://litecoinspace.org/api/v1/fees/recommended",
                now: now
            )
        case .bitcoinCash:
            return try await bitcoreBitcoinCashQuote(now: now)
        case .dogecoin:
            return try await blockbookQuote(
                chain: chain,
                provider: "atomic_dogecoin_blockbook",
                baseURL: "https://dogecoin.atomicwallet.io/api/v2",
                targetBlocks: (fastest: 2, standard: 6, economy: 12),
                now: now
            )
        }
    }

    private func secondaryQuote(
        for chain: BitcoinFamilyChain,
        now: Date
    ) async throws -> SendNetworkFeeQuote {
        switch chain {
        case .bitcoin:
            return try await blockstreamBitcoinQuote(now: now)
        case .litecoin:
            return try await blockbookQuote(
                chain: chain,
                provider: "atomic_litecoin_blockbook",
                baseURL: "https://litecoin.atomicwallet.io/api/v2",
                targetBlocks: (fastest: 1, standard: 3, economy: 6),
                now: now
            )
        case .bitcoinCash:
            return try await blockchairQuote(
                chain: chain,
                provider: "blockchair_bitcoin_cash",
                endpoint: "https://api.blockchair.com/bitcoin-cash/stats",
                now: now
            )
        case .dogecoin:
            return try await blockchairQuote(
                chain: chain,
                provider: "blockchair_dogecoin",
                endpoint: "https://api.blockchair.com/dogecoin/stats",
                now: now
            )
        }
    }

    private func recommendedFeeQuote(
        chain: BitcoinFamilyChain,
        provider: String,
        endpoint: String,
        now: Date
    ) async throws -> SendNetworkFeeQuote {
        let data = try await get(endpoint)
        let response: RecommendedFeeResponse
        do {
            response = try JSONDecoder().decode(
                RecommendedFeeResponse.self,
                from: data
            )
        } catch {
            throw SendNetworkFeeAPIError.invalidResponse(
                "\(provider)_shape"
            )
        }
        return try Self.makeQuote(
            chain: chain,
            provider: provider,
            fastest: response.fastestFee,
            standard: response.halfHourFee,
            economy: response.hourFee,
            now: now
        )
    }

    private func blockstreamBitcoinQuote(
        now: Date
    ) async throws -> SendNetworkFeeQuote {
        let data = try await get(
            "https://blockstream.info/api/fee-estimates"
        )
        let response: [String: Decimal]
        do {
            response = try JSONDecoder().decode(
                [String: Decimal].self,
                from: data
            )
        } catch {
            throw SendNetworkFeeAPIError.invalidResponse(
                "blockstream_fee_shape"
            )
        }
        return try Self.makeQuote(
            chain: .bitcoin,
            provider: "blockstream_esplora",
            fastest: try Self.atomicRate(response, target: 1),
            standard: try Self.atomicRate(response, target: 3),
            economy: try Self.atomicRate(response, target: 6),
            now: now
        )
    }

    private func bitcoreBitcoinCashQuote(
        now: Date
    ) async throws -> SendNetworkFeeQuote {
        async let fastest = bitcoreBitcoinCashRate(targetBlocks: 1)
        async let standard = bitcoreBitcoinCashRate(targetBlocks: 3)
        async let economy = bitcoreBitcoinCashRate(targetBlocks: 6)
        let rates = try await (fastest, standard, economy)
        return try Self.makeQuote(
            chain: .bitcoinCash,
            provider: "bitcore_bitcoin_cash",
            fastest: rates.0,
            standard: rates.1,
            economy: rates.2,
            now: now
        )
    }

    private func bitcoreBitcoinCashRate(
        targetBlocks: Int
    ) async throws -> UInt64 {
        let data = try await get(
            "https://api.bitcore.io/api/BCH/mainnet/fee/\(targetBlocks)"
        )
        let response: BitcoreFeeResponse
        do {
            response = try JSONDecoder().decode(
                BitcoreFeeResponse.self,
                from: data
            )
        } catch {
            throw SendNetworkFeeAPIError.invalidResponse(
                "bitcore_fee_shape"
            )
        }
        return try Self.atomicPerVByte(
            coinPerKilobyte: response.feerate
        )
    }

    private func blockbookQuote(
        chain: BitcoinFamilyChain,
        provider: String,
        baseURL: String,
        targetBlocks: (fastest: Int, standard: Int, economy: Int),
        now: Date
    ) async throws -> SendNetworkFeeQuote {
        async let fastest = blockbookRate(
            baseURL: baseURL,
            targetBlocks: targetBlocks.fastest,
            provider: provider
        )
        async let standard = blockbookRate(
            baseURL: baseURL,
            targetBlocks: targetBlocks.standard,
            provider: provider
        )
        async let economy = blockbookRate(
            baseURL: baseURL,
            targetBlocks: targetBlocks.economy,
            provider: provider
        )
        let rates = try await (fastest, standard, economy)
        return try Self.makeQuote(
            chain: chain,
            provider: provider,
            fastest: rates.0,
            standard: rates.1,
            economy: rates.2,
            now: now
        )
    }

    private func blockbookRate(
        baseURL: String,
        targetBlocks: Int,
        provider: String
    ) async throws -> UInt64 {
        let data = try await get(
            "\(baseURL)/estimatefee/\(targetBlocks)"
        )
        let response: BlockbookFeeResponse
        do {
            response = try JSONDecoder().decode(
                BlockbookFeeResponse.self,
                from: data
            )
        } catch {
            throw SendNetworkFeeAPIError.invalidResponse(
                "\(provider)_shape"
            )
        }
        guard let decimal = Decimal(
            string: response.result,
            locale: Self.posix
        ) else {
            throw SendNetworkFeeAPIError.invalidResponse(
                "\(provider)_number"
            )
        }
        return try Self.atomicPerVByte(coinPerKilobyte: decimal)
    }

    private func blockchairQuote(
        chain: BitcoinFamilyChain,
        provider: String,
        endpoint: String,
        now: Date
    ) async throws -> SendNetworkFeeQuote {
        let data = try await get(endpoint)
        let response: BlockchairStatsResponse
        do {
            response = try JSONDecoder().decode(
                BlockchairStatsResponse.self,
                from: data
            )
        } catch {
            throw SendNetworkFeeAPIError.invalidResponse(
                "\(provider)_shape"
            )
        }
        let rate = response.data.suggestedTransactionFeePerByteSat
        return try Self.makeQuote(
            chain: chain,
            provider: provider,
            fastest: rate,
            standard: rate,
            economy: rate,
            now: now
        )
    }

    private func get(_ endpoint: String) async throws -> Data {
        guard let url = URL(string: endpoint),
              url.scheme?.lowercased() == "https" else {
            throw SendNetworkFeeAPIError.invalidConfiguration
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await requestExecutor(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw SendNetworkFeeAPIError.transport(
                Self.sanitizedErrorType(error)
            )
        }
        guard let http = response as? HTTPURLResponse else {
            throw SendNetworkFeeAPIError.invalidHTTPResponse
        }
        guard data.count <= Self.maximumFeeResponseBytes else {
            throw SendNetworkFeeAPIError.invalidResponse(
                "response_too_large"
            )
        }
        guard http.statusCode == 200 else {
            throw SendNetworkFeeAPIError.server(
                status: http.statusCode,
                code: "http_\(http.statusCode)"
            )
        }
        return data
    }

    private func broadcastAttempt(
        provider: BroadcastProvider,
        rawTransactionHex: String,
        expectedTransactionID: String
    ) async -> BroadcastAttemptOutcome {
        var request = URLRequest(url: provider.url)
        request.httpMethod = "POST"
        request.setValue(
            "text/plain, application/json",
            forHTTPHeaderField: "Accept"
        )
        switch provider.body {
        case .plainText:
            request.setValue(
                "text/plain; charset=utf-8",
                forHTTPHeaderField: "Content-Type"
            )
            request.httpBody = Data(rawTransactionHex.utf8)
        case .bitcoreJSON:
            request.setValue(
                "application/json",
                forHTTPHeaderField: "Content-Type"
            )
            do {
                request.httpBody = try JSONEncoder().encode(
                    BitcoreBroadcastRequest(rawTx: rawTransactionHex)
                )
            } catch {
                return .rejected(
                    code: "request_encoding",
                    message: WalletLocalization.string(
                        "send.submit.error.provider_no_message"
                    )
                )
            }
        case .blockchairForm:
            request.setValue(
                "application/x-www-form-urlencoded; charset=utf-8",
                forHTTPHeaderField: "Content-Type"
            )
            request.httpBody = Data("data=\(rawTransactionHex)".utf8)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await requestExecutor(request)
        } catch is CancellationError {
            return .ambiguous(code: "cancelled")
        } catch let error as URLError where error.code == .cancelled {
            return .ambiguous(code: "cancelled")
        } catch {
            return .ambiguous(
                code: "transport_\(Self.sanitizedErrorType(error))"
            )
        }
        guard let http = response as? HTTPURLResponse else {
            return .ambiguous(code: "response_not_http")
        }
        guard data.count <= Self.maximumBroadcastResponseBytes else {
            return .ambiguous(code: "response_too_large")
        }

        let message = Self.providerMessage(from: data)
        if (200..<300).contains(http.statusCode) {
            guard Self.responseContainsTransactionID(
                data,
                expectedTransactionID: expectedTransactionID
            ) else {
                return .ambiguous(code: "transaction_id_mismatch")
            }
            return .success(
                transactionID: expectedTransactionID,
                wasAlreadyKnown: false
            )
        }
        if Self.isAlreadyKnownMessage(message) {
            return .success(
                transactionID: expectedTransactionID,
                wasAlreadyKnown: true
            )
        }
        let code = "http_\(http.statusCode)"
        if Self.isDefinitiveRejectionMessage(message) {
            return .rejected(code: code, message: message)
        }
        return .ambiguous(code: code)
    }

    private static func makeQuote(
        chain: BitcoinFamilyChain,
        provider: String,
        fastest: UInt64,
        standard: UInt64,
        economy: UInt64,
        now: Date
    ) throws -> SendNetworkFeeQuote {
        let minimum = minimumAtomicPerVByte(for: chain)
        let boundedEconomy = max(economy, minimum)
        let boundedStandard = max(standard, boundedEconomy)
        let boundedFastest = max(fastest, boundedStandard)
        guard boundedFastest > 0 else {
            throw SendNetworkFeeAPIError.invalidResponse(
                "\(provider)_non_positive"
            )
        }
        let values: [(SendNetworkFeePreset, UInt64)] = [
            (.fastest, boundedFastest),
            (.standard, boundedStandard),
            (.economy, boundedEconomy)
        ]
        return SendNetworkFeeQuote(
            networkID: chain.networkID,
            provider: provider,
            fetchedAt: now,
            expiresAt: now.addingTimeInterval(30),
            tiers: values.map { preset, value in
                SendNetworkFeeTier(
                    preset: preset,
                    model: .utxoPerVByte,
                    primaryValue: String(value),
                    secondaryValue: nil
                )
            }
        )
    }

    private static func atomicRate(
        _ response: [String: Decimal],
        target: Int
    ) throws -> UInt64 {
        let rates = response.compactMap { key, value -> (Int, Decimal)? in
            guard let block = Int(key), value > 0 else { return nil }
            return (block, value)
        }.sorted { $0.0 < $1.0 }
        guard let decimal = rates.first(where: { $0.0 >= target })?.1
                ?? rates.last?.1 else {
            throw SendNetworkFeeAPIError.invalidResponse(
                "blockstream_fee_missing_target"
            )
        }
        var mutable = decimal
        var rounded = Decimal()
        NSDecimalRound(&rounded, &mutable, 0, .up)
        let text = NSDecimalNumber(decimal: rounded).stringValue
        guard let value = UInt64(text), value > 0 else {
            throw SendNetworkFeeAPIError.invalidResponse(
                "blockstream_fee_out_of_range"
            )
        }
        return value
    }

    private static func broadcastProviders(
        for chain: BitcoinFamilyChain
    ) -> [BroadcastProvider] {
        switch chain {
        case .bitcoin:
            return [
                BroadcastProvider(
                    name: "mempool_space",
                    url: URL(string: "https://mempool.space/api/tx")!,
                    body: .plainText
                ),
                BroadcastProvider(
                    name: "blockstream_esplora",
                    url: URL(string: "https://blockstream.info/api/tx")!,
                    body: .plainText
                )
            ]
        case .litecoin:
            return [
                BroadcastProvider(
                    name: "litecoinspace",
                    url: URL(string: "https://litecoinspace.org/api/tx")!,
                    body: .plainText
                ),
                BroadcastProvider(
                    name: "atomic_litecoin_blockbook",
                    url: URL(
                        string: "https://litecoin.atomicwallet.io/api/v2/sendtx/"
                    )!,
                    body: .plainText
                )
            ]
        case .bitcoinCash:
            return [
                BroadcastProvider(
                    name: "bitcore_bitcoin_cash",
                    url: URL(
                        string: "https://api.bitcore.io/api/BCH/mainnet/tx/send"
                    )!,
                    body: .bitcoreJSON
                ),
                BroadcastProvider(
                    name: "blockchair_bitcoin_cash",
                    url: URL(
                        string: "https://api.blockchair.com/bitcoin-cash/push/transaction"
                    )!,
                    body: .blockchairForm
                )
            ]
        case .dogecoin:
            return [
                BroadcastProvider(
                    name: "atomic_dogecoin_blockbook",
                    url: URL(
                        string: "https://dogecoin.atomicwallet.io/api/v2/sendtx/"
                    )!,
                    body: .plainText
                ),
                BroadcastProvider(
                    name: "blockchair_dogecoin",
                    url: URL(
                        string: "https://api.blockchair.com/dogecoin/push/transaction"
                    )!,
                    body: .blockchairForm
                )
            ]
        }
    }

    private static func responseContainsTransactionID(
        _ data: Data,
        expectedTransactionID: String
    ) -> Bool {
        let trimmed = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            .lowercased()
        if trimmed == expectedTransactionID { return true }
        guard let object = try? JSONSerialization.jsonObject(with: data) else {
            return false
        }
        return containsTransactionID(
            object,
            expectedTransactionID: expectedTransactionID
        )
    }

    private static func containsTransactionID(
        _ value: Any,
        expectedTransactionID: String
    ) -> Bool {
        if let string = value as? String {
            return string.lowercased() == expectedTransactionID
        }
        if let array = value as? [Any] {
            return array.contains {
                containsTransactionID(
                    $0,
                    expectedTransactionID: expectedTransactionID
                )
            }
        }
        if let dictionary = value as? [String: Any] {
            if dictionary.keys.contains(where: {
                $0.lowercased() == expectedTransactionID
            }) {
                return true
            }
            return dictionary.values.contains {
                containsTransactionID(
                    $0,
                    expectedTransactionID: expectedTransactionID
                )
            }
        }
        return false
    }

    private static func providerMessage(from data: Data) -> String {
        if let object = try? JSONSerialization.jsonObject(with: data),
           let extracted = errorMessage(in: object) {
            return sanitizeProviderMessage(extracted)
        }
        return sanitizeProviderMessage(
            String(decoding: data, as: UTF8.self)
        )
    }

    private static func errorMessage(in value: Any) -> String? {
        if let string = value as? String { return string }
        if let array = value as? [Any] {
            return array.compactMap(errorMessage(in:)).first
        }
        guard let dictionary = value as? [String: Any] else { return nil }
        for key in ["error", "message", "result"] {
            if let child = dictionary[key],
               let message = errorMessage(in: child),
               !message.isEmpty {
                return message
            }
        }
        for child in dictionary.values {
            if let message = errorMessage(in: child), !message.isEmpty {
                return message
            }
        }
        return nil
    }

    private static func sanitizeProviderMessage(_ value: String) -> String {
        let sanitized = value
            .components(separatedBy: .controlCharacters)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return sanitized.isEmpty
            ? WalletLocalization.string(
                "send.submit.error.provider_no_message"
            )
            : String(sanitized.prefix(240))
    }

    private static func sanitizedErrorType(_ error: Error) -> String {
        let normalized = String(reflecting: type(of: error)).lowercased().map {
            character in
            character.isASCII && (character.isLetter || character.isNumber)
                ? character : "_"
        }
        let compact = String(normalized)
            .split(separator: "_")
            .prefix(8)
            .joined(separator: "_")
        return compact.isEmpty ? "unknown" : String(compact.prefix(96))
    }

    private static func minimumAtomicPerVByte(
        for chain: BitcoinFamilyChain
    ) -> UInt64 {
        chain == .dogecoin ? 1_000 : 1
    }

    private static func isTransactionID(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy(isASCIIHexByte)
    }

    private static func isASCIIHexByte(_ byte: UInt8) -> Bool {
        switch byte {
        case 48...57, 65...70, 97...102: true
        default: false
        }
    }
}

private extension SendBitcoinFamilyHTTPAPIClient {
    struct RecommendedFeeResponse: Decodable {
        let fastestFee: UInt64
        let halfHourFee: UInt64
        let hourFee: UInt64
    }

    struct BitcoreFeeResponse: Decodable {
        let feerate: Decimal
    }

    struct BlockbookFeeResponse: Decodable {
        let result: String
    }

    struct BlockchairStatsResponse: Decodable {
        struct Statistics: Decodable {
            let suggestedTransactionFeePerByteSat: UInt64

            enum CodingKeys: String, CodingKey {
                case suggestedTransactionFeePerByteSat =
                    "suggested_transaction_fee_per_byte_sat"
            }
        }

        let data: Statistics
    }

    struct BitcoreBroadcastRequest: Encodable {
        let rawTx: String
    }

    struct BroadcastProvider: Sendable {
        let name: String
        let url: URL
        let body: BroadcastBody
    }

    enum BroadcastBody: Sendable {
        case plainText
        case bitcoreJSON
        case blockchairForm
    }

    enum BroadcastAttemptOutcome: Sendable {
        case success(transactionID: String, wasAlreadyKnown: Bool)
        case rejected(code: String, message: String)
        case ambiguous(code: String)
    }
}
