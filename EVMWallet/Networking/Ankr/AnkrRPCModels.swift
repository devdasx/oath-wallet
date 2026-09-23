import Foundation

struct AnkrRPCRequest<Parameters: Encodable & Sendable>: Encodable, Sendable {
    let id: String
    let jsonrpc: String
    let method: String
    let params: Parameters
}

struct AnkrRPCResponse<Result: Decodable & Sendable>: Decodable, Sendable {
    let result: Result?
    let error: AnkrRPCErrorResponse?
}

struct AnkrRPCErrorResponse: Decodable, Sendable {
    let code: Int
    let message: String
}

struct AnkrHTTPErrorResponse: Decodable, Sendable {
    struct ProviderError: Decodable, Sendable {
        let code: String?
        let message: String?

        private enum CodingKeys: String, CodingKey {
            case code
            case message
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if let stringCode = try? container.decode(
                String.self,
                forKey: .code
            ) {
                code = stringCode
            } else if let integerCode = try? container.decode(
                Int.self,
                forKey: .code
            ) {
                code = String(integerCode)
            } else {
                code = nil
            }
            message = try container.decodeIfPresent(
                String.self,
                forKey: .message
            )
        }
    }

    let error: ProviderError?
    let message: String?
}

struct AnkrBalanceParameters: Encodable, Sendable {
    let blockchain: [String]
    let walletAddress: String
    let onlyWhitelisted: Bool
    let nativeFirst: Bool
    let pageSize: Int
    let pageToken: String?
}

struct AnkrBalanceResult: Decodable, Sendable {
    let totalBalanceUsd: String
    let assets: [AnkrBalanceAsset]
    let nextPageToken: String?

    /// ANKR occasionally includes an otherwise well-formed ERC-20 holding
    /// whose identity and valuation metadata are all absent, even when
    /// `onlyWhitelisted` is enabled. Such an entry cannot be represented as a
    /// wallet asset and contributes no value to the provider total. Exclude
    /// only that narrow placeholder shape before establishing snapshot
    /// authority; every malformed or potentially valued entry remains in the
    /// result so the strict snapshot mapper rejects it.
    func removingUnpricedOpaqueTokenPlaceholders() -> AnkrBalanceResult {
        AnkrBalanceResult(
            totalBalanceUsd: totalBalanceUsd,
            assets: assets.filter { !$0.isUnpricedOpaqueTokenPlaceholder },
            nextPageToken: nextPageToken
        )
    }
}

struct AnkrBalanceAsset: Decodable, Sendable {
    let blockchain: String
    let tokenName: String
    let tokenSymbol: String
    let tokenDecimals: Int
    let tokenType: String
    let contractAddress: String
    let balance: String
    let balanceRawInteger: String?
    let balanceUsd: String?
    let tokenPrice: String?
    let thumbnail: String

    fileprivate var isUnpricedOpaqueTokenPlaceholder: Bool {
        guard tokenType.caseInsensitiveCompare("NATIVE") != .orderedSame,
              tokenName.trimmingCharacters(
                in: .whitespacesAndNewlines
              ).isEmpty,
              tokenSymbol.trimmingCharacters(
                in: .whitespacesAndNewlines
              ).isEmpty,
              balanceUsd?.trimmingCharacters(
                in: .whitespacesAndNewlines
              ).isEmpty != false,
              tokenPrice?.trimmingCharacters(
                in: .whitespacesAndNewlines
              ).isEmpty != false,
              WalletBlockchain(ankrIdentifier: blockchain) != nil,
              AnkrAPIClient.isValidAddress(contractAddress),
              (0...255).contains(tokenDecimals),
              let amount = try? AnkrTokenAmount(
                rawInteger: balanceRawInteger,
                normalizedValue: balance,
                decimals: tokenDecimals
              ),
              amount.normalizedMatchesRaw != false
        else {
            return false
        }
        return true
    }
}

struct AnkrCurrenciesParameters: Encodable, Sendable {
    let blockchain: String
}

struct AnkrCurrenciesResult: Decodable, Sendable {
    let currencies: [AnkrCurrency]
}

struct AnkrCurrency: Decodable, Sendable {
    let blockchain: String?
    let address: String?
    let name: String?
    let decimals: Int?
    let symbol: String?
    let thumbnail: String?
}

struct AnkrTokenPriceParameters: Encodable, Sendable {
    let blockchain: String
    let contractAddress: String
}

struct AnkrTokenPriceResult: Decodable, Sendable {
    let blockchain: String?
    let contractAddress: String?
    let usdPrice: String?
}

struct AnkrHistoryParameters: Encodable, Sendable {
    let blockchain: [String]
    let address: [String]
    let descOrder: Bool
    let pageSize: Int
    let pageToken: String?
    let includeLogs: Bool?
    let fromTimestamp: Int64?
}

struct AnkrTokenTransferResult: Decodable, Sendable {
    let transfers: [AnkrTokenTransfer]
    let nextPageToken: String?
}

struct AnkrTokenTransfer: Decodable, Sendable {
    let blockHeight: Int64?
    let fromAddress: String?
    let toAddress: String?
    let contractAddress: String?
    let value: String?
    let valueRawInteger: String?
    let blockchain: String?
    let tokenName: String?
    let tokenSymbol: String?
    let tokenDecimals: Int?
    let thumbnail: String?
    let transactionHash: String?
    let logIndex: Int?
    let timestamp: Int64?
    let direction: String?
}

struct AnkrRawTransactionResult: Decodable, Sendable {
    let transactions: [AnkrRawTransaction]
    let nextPageToken: String?
}

struct AnkrRawTransaction: Decodable, Sendable {
    let blockHash: String?
    let blockNumber: String?
    let from: String
    let gas: String?
    let gasPrice: String?
    let gasUsed: String?
    let to: String?
    let value: String
    let hash: String
    let input: String?
    let nonce: String?
    let status: String
    let blockchain: String
    let timestamp: String
    let transactionIndex: String?
    let type: String?
}

struct AnkrTimestampedTransaction: Sendable {
    let timestamp: Int64
    let transaction: WalletTransaction
}
